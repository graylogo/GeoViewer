import AppKit
import MapKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Toast 上附带的操作按钮。
enum ToastAction: Equatable {
    case none
    case undo
    case openSettings
}

struct ToastMessage: Identifiable, Equatable {
    enum Kind {
        case info
        case success
        case warning
        case error

        var systemImage: String {
            switch self {
            case .info: return "info.circle"
            case .success: return "checkmark.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    let id = UUID()
    var message: String
    var kind: Kind = .info
    var action: ToastAction = .none
}

@MainActor
@Observable
final class AppModel {
    static weak var shared: AppModel?

    // MARK: - 照片数据

    private(set) var photos: [PhotoItem] = []
    var selection: Set<PhotoItem.ID> = []
    var primaryID: PhotoItem.ID?
    var searchText = ""

    // MARK: - 界面状态

    var showSidebar = true
    var showInspector = true
    var locationMode = false
    var isDropTargeted = false
    var isLoading = false
    var loadingMessage: String?
    var isSaving = false
    var saveProgress: (completed: Int, total: Int)?
    var toast: ToastMessage?
    var errorMessage: String?
    var showsCoordinatePrompt = false
    var coordinateInput = ""

    // MARK: - 地图状态

    var cameraPosition: MapCameraPosition = .region(MapDefaults.region)
    var mapRegion: MKCoordinateRegion = MapDefaults.region

    // MARK: - 撤销栈

    private var undoStack: [PhotoLocationEdit] = []
    private var redoStack: [PhotoLocationEdit] = []

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var didAutoFit = false
    @ObservationIgnored private var pendingURLs: [URL] = []

    /// 位置数据版本：任何暂存坐标变化都会自增，用于让聚合缓存失效。
    @ObservationIgnored private var locationVersion = 0
    @ObservationIgnored private var clustersCache: ClustersCache?

    private struct ClustersCache {
        let zoomLevel: Int
        let locationVersion: Int
        let locatedCount: Int
        let clusters: [PhotoCluster]
    }
    @ObservationIgnored private let settings = AppSettings.shared

    init() {
        AppModel.shared = self
    }

    // MARK: - 派生状态

    var filteredPhotos: [PhotoItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = query.isEmpty ? photos : photos.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.directoryPath.localizedCaseInsensitiveContains(query)
        }
        return base.sorted { settings.sortOrder.precedes($0, $1) }
    }

    /// 按文件夹分组后的照片列表，供左侧列表分节渲染。
    ///
    /// 分组键用**完整路径**，避免不同父目录下的同名文件夹被错误合并；
    /// 界面只展示最后一级目录名，完整路径放在悬浮提示里。
    /// 关闭分组时返回单个 `folder == nil` 的分组。
    var groupedPhotos: [(folder: String?, photos: [PhotoItem])] {
        let visible = filteredPhotos
        guard settings.groupByFolder else { return [(nil, visible)] }

        var buckets: [String: [PhotoItem]] = [:]
        for photo in visible {
            buckets[photo.directoryPath, default: []].append(photo)
        }
        return buckets.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, buckets[$0] ?? []) }
    }

    var selectedPhotos: [PhotoItem] {
        photos.filter { selection.contains($0.id) }
    }

    var primaryPhoto: PhotoItem? {
        if let primaryID, let photo = photos.first(where: { $0.id == primaryID }) {
            return photo
        }
        return selectedPhotos.first
    }

    var locatedCount: Int { photos.filter { $0.stagedCoordinate != nil }.count }
    var dirtyCount: Int { photos.filter(\.isDirty).count }
    var hasUnsavedChanges: Bool { photos.contains(where: \.isDirty) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var locationHint: String {
        if selection.isEmpty {
            return locationMode ? "先在左侧选择照片，再点击地图定位" : "开启定位模式后，点击地图即可修改位置"
        }
        if !locationMode {
            return "开启定位模式后，点击地图即可修改位置"
        }
        return "点击地图，为所选 \(selection.count) 张照片设置位置"
    }

    // MARK: - 打开文件

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择照片"
        panel.prompt = "打开"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.openPanelContentTypes

        if panel.runModal() == .OK {
            open(urls: panel.urls)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择照片文件夹"
        panel.prompt = "打开"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            open(urls: panel.urls)
        }
    }

    func open(urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingURLs.append(contentsOf: urls)
        guard !isLoading else { return }
        Task { await drainPendingURLs() }
    }

    /// 连续拖入 / 多次「打开」时排队处理，避免后一批被丢弃。
    private func drainPendingURLs() async {
        while !pendingURLs.isEmpty {
            let batch = pendingURLs
            pendingURLs.removeAll()
            await load(urls: batch)
        }
    }

    private func load(urls: [URL]) async {
        isLoading = true
        loadingMessage = "正在扫描文件…"
        defer {
            isLoading = false
            loadingMessage = nil
        }

        let existingPaths = Set(photos.map { $0.url.standardizedFileURL.path })
        let candidates = await Task.detached(priority: .userInitiated) {
            PhotoScanner.collectImageURLs(from: urls)
        }.value.filter { !existingPaths.contains($0.standardizedFileURL.path) }

        guard !candidates.isEmpty else {
            showToast(photos.isEmpty ? "没有找到可读取的照片" : "没有新的照片可添加", kind: .warning)
            return
        }

        loadingMessage = "正在读取 \(candidates.count) 个文件的元数据…"
        let loaded = await Task.detached(priority: .userInitiated) { () -> [(URL, PhotoDetails)] in
            var results: [(URL, PhotoDetails)] = []
            results.reserveCapacity(candidates.count)
            for url in candidates {
                if let details = MetadataReader.read(url: url) {
                    results.append((url, details))
                }
            }
            return results
        }.value

        let items = loaded.map { PhotoItem(url: $0.0, details: $0.1) }
        photos.append(contentsOf: items)
        photos.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        locationVersion += 1
        clustersCache = nil

        // 提前生成列表与地图标记要用的缩略图，避免滚动 / 缩放时出现空白一帧。
        prefetchThumbnails(for: items)

        if selection.isEmpty, let first = photos.first {
            selection = [first.id]
            primaryID = first.id
        }

        if !didAutoFit, locatedCount > 0 {
            didAutoFit = true
            fitAll(animated: false)
        }

        let skipped = candidates.count - items.count
        if items.isEmpty {
            showToast("所选文件没有可读取的元数据", kind: .warning)
        } else if skipped > 0 {
            showToast("已添加 \(items.count) 张照片，\(skipped) 个文件无法读取", kind: .warning)
        } else {
            showToast("已添加 \(items.count) 张照片", kind: .success)
        }
    }

    func clearList() {
        photos.removeAll()
        selection.removeAll()
        primaryID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        didAutoFit = false
        locationVersion += 1
        clustersCache = nil
        Task { await ThumbnailProvider.shared.clearCache() }
    }

    func removeFromList(ids: Set<PhotoItem.ID>) {
        photos.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let primaryID, !photos.contains(where: { $0.id == primaryID }) {
            self.primaryID = nil
        }
        locationVersion += 1
        clustersCache = nil
    }

    // MARK: - 缩略图

    /// 界面用到的缩略图尺寸（列表 / 地图标记 / 检查器）。
    private enum ThumbnailSizes {
        static let all = [120, 220, 900]
    }

    func loadThumbnail(for photo: PhotoItem, maxPixel: Int) async {
        guard photo.thumbnails[maxPixel] == nil, !photo.pendingThumbnailSizes.contains(maxPixel) else { return }
        photo.pendingThumbnailSizes.insert(maxPixel)
        defer { photo.pendingThumbnailSizes.remove(maxPixel) }

        if let box = await ThumbnailProvider.shared.thumbnail(for: photo.url, maxPixel: maxPixel) {
            photo.thumbnails[maxPixel] = box.image
        }
    }

    /// 后台预取列表与地图标记尺寸的缩略图，避免滚动 / 缩放时出现空白一帧。
    private func prefetchThumbnails(for items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        let batch = items
        Task { [weak self] in
            for item in batch {
                await self?.loadThumbnail(for: item, maxPixel: 120)
                await self?.loadThumbnail(for: item, maxPixel: 220)
            }
        }
    }

    // MARK: - 位置编辑

    func setLocationForSelection(_ coordinate: GeoCoordinate?) {
        let selected = selectedPhotos
        guard !selected.isEmpty else {
            showToast("请先选择照片", kind: .warning)
            locationMode = true
            return
        }

        let targets = selected.filter(\.isWritable)
        let skipped = selected.count - targets.count
        guard !targets.isEmpty else {
            showToast("所选照片为只读格式，暂不支持写入位置", kind: .warning)
            return
        }

        var changes: [PhotoLocationChange] = []
        changes.reserveCapacity(targets.count)
        for photo in targets {
            changes.append(PhotoLocationChange(photo: photo, oldCoordinate: photo.stagedCoordinate, newCoordinate: coordinate))
            photo.stagedCoordinate = coordinate
        }
        locationVersion += 1
        push(PhotoLocationEdit(changes: changes))

        let result: String
        if let coordinate {
            result = "已将 \(targets.count) 张照片定位到 \(coordinate.shortDescription)"
        } else {
            result = "已清除 \(targets.count) 张照片的位置"
        }
        let suffix = skipped > 0 ? "（\(skipped) 张只读照片已跳过）" : ""
        showToast(result + suffix, kind: .success, action: targets.isEmpty ? .none : .undo)

        if settings.autoSaveAfterEdit {
            saveChanges()
        }
    }

    func clearLocationForSelection() {
        setLocationForSelection(nil)
    }

    func undo() {
        guard let edit = undoStack.popLast() else { return }
        for change in edit.changes {
            change.photo.stagedCoordinate = change.oldCoordinate
        }
        locationVersion += 1
        redoStack.append(edit)
        showToast("已撤销位置修改", kind: .info)
    }

    func redo() {
        guard let edit = redoStack.popLast() else { return }
        for change in edit.changes {
            change.photo.stagedCoordinate = change.newCoordinate
        }
        locationVersion += 1
        undoStack.append(edit)
        showToast("已重做位置修改", kind: .info)
    }

    func discardChanges() {
        guard hasUnsavedChanges else { return }
        let count = dirtyCount
        for photo in photos where photo.isDirty {
            photo.revertToSaved()
        }
        locationVersion += 1
        clustersCache = nil
        undoStack.removeAll()
        redoStack.removeAll()
        showToast("已放弃 \(count) 张照片的未保存修改")
    }

    private func push(_ edit: PhotoLocationEdit) {
        undoStack.append(edit)
        redoStack.removeAll()
    }

    // MARK: - 保存

    func saveChanges() {
        guard !isSaving else { return }
        let dirty = photos.filter(\.isDirty)
        guard !dirty.isEmpty else {
            showToast("没有需要保存的修改")
            return
        }

        if settings.backupEnabled, settings.backupFolderURL == nil {
            showToast("请先在设置中选择备份文件夹，或关闭「写入前备份」", kind: .error)
            return
        }

        Task { await performSave(dirty) }
    }

    private func performSave(_ items: [PhotoItem]) async {
        isSaving = true
        defer {
            isSaving = false
            saveProgress = nil
        }

        let total = items.count
        var failures: [String] = []
        let backupFolder = settings.backupEnabled ? settings.backupFolderURL : nil

        for (index, photo) in items.enumerated() {
            saveProgress = (index + 1, total)
            let url = photo.url
            let coordinate = photo.stagedCoordinate

            do {
                if let backupFolder {
                    try await Task.detached(priority: .userInitiated) {
                        _ = try BackupService.backup(url: url, to: backupFolder)
                    }.value
                }

                try await Task.detached(priority: .userInitiated) {
                    try MetadataWriter.setLocation(coordinate, for: url)
                }.value

                // 回读磁盘：既刷新界面，也校验位置是否真的写入成功。
                if let refreshed = await Task.detached(
                    priority: .userInitiated,
                    operation: { MetadataReader.read(url: url) }
                ).value {
                    photo.details = refreshed
                    photo.stagedCoordinate = refreshed.gps?.coordinate
                    locationVersion += 1

                    if let coordinate {
                        if let actual = refreshed.gps?.coordinate, !actual.isClose(to: coordinate) {
                            failures.append("\(url.lastPathComponent)：写入后校验失败，位置未生效")
                        }
                    } else if refreshed.gps != nil {
                        failures.append("\(url.lastPathComponent)：清除位置后仍能读到 GPS 信息")
                    }
                } else {
                    photo.commitSavedCoordinate(coordinate)
                    locationVersion += 1
                    clustersCache = nil
                    failures.append("\(url.lastPathComponent)：写入后无法读取文件")
                }

                // 文件已被替换：主动重新加载预览，避免界面停在空白占位。
                photo.invalidateThumbnails()
                for size in ThumbnailSizes.all {
                    await loadThumbnail(for: photo, maxPixel: size)
                }
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        // 磁盘内容已变化，撤销记录不再可靠。
        undoStack.removeAll()
        redoStack.removeAll()

        if failures.isEmpty {
            let notice = settings.backupEnabled ? "" : "（未备份原片）"
            showToast("已保存 \(total) 张照片的位置" + notice, kind: .success)
        } else {
            errorMessage = "以下文件保存失败：\n" + failures.prefix(8).joined(separator: "\n")
            showToast("\(failures.count) 个文件保存失败", kind: .error)
        }
    }

    // MARK: - 坐标输入 / 剪贴板

    func beginManualInput() {
        if let coordinate = primaryPhoto?.stagedCoordinate {
            coordinateInput = coordinate.formatted
        } else {
            coordinateInput = ""
        }
        showsCoordinatePrompt = true
    }

    func applyManualInput() {
        guard let coordinate = GeoCoordinate.parse(coordinateInput) else {
            showToast("坐标格式不正确，请输入「纬度, 经度」，例如 30.2741, 120.1551", kind: .warning)
            return
        }
        setLocationForSelection(coordinate)
    }

    /// 剪贴板里当前是否有能解析的坐标，用于控制「粘贴坐标」的启用状态。
    var canPasteCoordinate: Bool {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return false }
        return GeoCoordinate.parse(raw) != nil
    }

    func copySelectedCoordinate() {
        guard let coordinate = primaryPhoto?.stagedCoordinate else {
            showToast("所选照片没有位置信息", kind: .warning)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(coordinate.formatted, forType: .string)
        showToast("已拷贝坐标 \(coordinate.formatted)", kind: .success)
    }

    /// 把剪贴板里的坐标粘贴到当前选中的全部照片上。
    ///
    /// 目标照片已有位置时会被覆盖；只读格式自动跳过；整次粘贴作为一条记录进入撤销栈，可 ⌘Z 撤销。
    func pasteCoordinateToSelection() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              let coordinate = GeoCoordinate.parse(raw)
        else {
            showToast("剪贴板中没有有效的坐标，请先拷贝一张照片的坐标", kind: .warning)
            return
        }
        setLocationForSelection(coordinate)
    }

    // MARK: - 地图

    /// 网格聚合：随地图缩放自动合并 / 拆分，形成相册式的缩略图堆叠。
    ///
    /// 缩放级别被量化成整数档位，并缓存聚合结果，避免滚轮缩放时每帧重算导致标记闪烁。
    var clusters: [PhotoCluster] {
        let located = photos.filter { $0.stagedCoordinate != nil }
        guard !located.isEmpty else {
            clustersCache = nil
            return []
        }

        let level = zoomLevel
        if let cache = clustersCache,
           cache.zoomLevel == level,
           cache.locationVersion == locationVersion,
           cache.locatedCount == located.count {
            return cache.clusters
        }

        let cell = cellSize(for: level)
        let latitudeCell = cell
        let longitudeCell = cell

        var buckets: [String: [PhotoItem]] = [:]
        for photo in located {
            guard let coordinate = photo.stagedCoordinate else { continue }
            let latitudeIndex = Int((coordinate.latitude / latitudeCell).rounded(.down))
            let longitudeIndex = Int((coordinate.longitude / longitudeCell).rounded(.down))
            buckets["\(latitudeIndex):\(longitudeIndex)", default: []].append(photo)
        }

        let result = buckets.map { key, items in
            let latitudes = items.compactMap { $0.stagedCoordinate?.latitude }
            let longitudes = items.compactMap { $0.stagedCoordinate?.longitude }
            let center = GeoCoordinate(
                latitude: latitudes.reduce(0, +) / Double(latitudes.count),
                longitude: longitudes.reduce(0, +) / Double(longitudes.count)
            )
            let sorted = items.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            return PhotoCluster(id: key, coordinate: center, photos: sorted)
        }
        .sorted { $0.count > $1.count }

        clustersCache = ClustersCache(
            zoomLevel: level,
            locationVersion: locationVersion,
            locatedCount: located.count,
            clusters: result
        )
        return result
    }

    /// 把连续缩放量化成整数档位（每档对应约两倍的视野变化）。
    private var zoomLevel: Int {
        let span = max(mapRegion.span.longitudeDelta, 0.00005)
        return Int(round(log2(360.0 / span)))
    }

    private func cellSize(for level: Int) -> Double {
        max(360.0 / pow(2.0, Double(level)) / 14.0, 0.00003)
    }

    func handleMapTap(on cluster: PhotoCluster) {
        if cluster.isMultiple {
            if let region = cluster.boundingRegion, region.span.latitudeDelta > 0.002 {
                withAnimation(.easeInOut(duration: 0.35)) {
                    mapRegion = region
                    cameraPosition = .region(region)
                }
            } else {
                select(cluster.photos)
                showToast("\(cluster.count) 张照片位于同一位置", kind: .info)
            }
        } else {
            select(cluster.photos)
        }
    }

    func select(_ items: [PhotoItem]) {
        selection = Set(items.map(\.id))
        primaryID = items.first?.id
    }

    func focus(on photo: PhotoItem) {
        guard let coordinate = photo.stagedCoordinate else {
            showToast("这张照片还没有位置信息", kind: .warning)
            return
        }
        selection = [photo.id]
        primaryID = photo.id

        let region = MKCoordinateRegion(
            center: coordinate.location,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        mapRegion = region
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(region)
        }
    }

    func focusOnPrimary() {
        guard let photo = primaryPhoto else { return }
        focus(on: photo)
    }

    func fitAll(animated: Bool = true) {
        let coordinates = photos.compactMap(\.stagedCoordinate)
        guard !coordinates.isEmpty else {
            showToast("还没有带位置的照片", kind: .warning)
            return
        }
        let region = Self.boundingRegion(for: coordinates, padding: 1.5)
        mapRegion = region
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                cameraPosition = .region(region)
            }
        } else {
            cameraPosition = .region(region)
        }
    }

    func zoom(by factor: Double) {
        var region = mapRegion
        let minimumSpan = 0.0004
        region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, minimumSpan), 160)
        region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, minimumSpan), 350)
        mapRegion = region
        withAnimation(.easeInOut(duration: 0.2)) {
            cameraPosition = .region(region)
        }
    }

    /// 直接把地图设到指定 region，不带动画。
    ///
    /// 供触摸板捏合手势实时缩放使用：手势期间每帧都会调用，带动画会和手势打架、
    /// 叠加出一堆动画导致视野抖动。
    func applyRegion(_ region: MKCoordinateRegion) {
        mapRegion = region
        cameraPosition = .region(region)
    }

    /// 把当前视野按倍率缩放后应用到地图，供手势实时调用。
    ///
    /// 以**手势开始时的 region**为基准换算，而不是反复读 `mapRegion`——后者只在
    /// `onMapCameraChange(.onEnd)` 时才更新，手势期间读到的始终是旧值，会让视野来回跳。
    func zoomFromGestureStart(by factor: Double) {
        guard let start = gestureStartRegion else { return }
        var region = start
        let minimumSpan = 0.0004
        region.span.latitudeDelta = min(max(start.span.latitudeDelta * factor, minimumSpan), 160)
        region.span.longitudeDelta = min(max(start.span.longitudeDelta * factor, minimumSpan), 350)
        applyRegion(region)
    }

    // MARK: - 视野跟随

    /// 捏合手势开始时的视野；整个手势期间以它为基准换算，避免读到滞后更新的 `mapRegion`。
    var gestureStartRegion: MKCoordinateRegion?

    /// 街道级视野跨度：约 450 米，能看清路网与临街建筑。
    static let streetLevelSpan = 0.0040

    /// 视野内缩比例：落在外圈这么多范围里都当作不可见。
    private static let revealInsetRatio = 0.15

    /// 把地图移到某张照片上方并放大到街道级，用于确认拍摄点位周边的路况。
    func zoomToStreetLevel(for photo: PhotoItem) {
        guard let coordinate = photo.stagedCoordinate else {
            showToast("这张照片还没有位置信息", kind: .warning)
            return
        }
        let span = MKCoordinateSpan(latitudeDelta: Self.streetLevelSpan, longitudeDelta: Self.streetLevelSpan)
        let region = MKCoordinateRegion(center: coordinate.location, span: span)
        mapRegion = region
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(region)
        }
    }

    func zoomToStreetLevelForPrimary() {
        guard let photo = primaryPhoto else { return }
        zoomToStreetLevel(for: photo)
    }

    /// 主选照片有位置、且落在当前视野之外时，才需要移动地图。
    ///
    /// 只在单选时成立，多选不触发，避免框选一批照片后视图被拖得到处跳。
    func revealSelectedIfNeeded() {
        guard selection.count == 1,
              let coordinate = primaryPhoto?.stagedCoordinate,
              !isCoordinateVisible(coordinate)
        else { return }

        var region = mapRegion
        region.center = coordinate.location
        mapRegion = region
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(region)
        }
    }

    /// 判断坐标是否落在当前视野内。
    ///
    /// 视野按 `revealInsetRatio` 向内收缩后再判定：贴着边缘、只露半截的照片
    /// 也算「看不见」，否则点完列表，标记仍可能卡在可视区外面。
    private func isCoordinateVisible(_ coordinate: GeoCoordinate) -> Bool {
        let span = mapRegion.span
        let center = mapRegion.center
        let latitudeInset = span.latitudeDelta * 0.5 * Self.revealInsetRatio
        let longitudeInset = span.longitudeDelta * 0.5 * Self.revealInsetRatio

        let latitudeRange = (center.latitude - span.latitudeDelta / 2 + latitudeInset)
            ... (center.latitude + span.latitudeDelta / 2 - latitudeInset)
        let longitudeRange = (center.longitude - span.longitudeDelta / 2 + longitudeInset)
            ... (center.longitude + span.longitudeDelta / 2 - longitudeInset)

        return latitudeRange.contains(coordinate.latitude)
            && longitudeRange.contains(coordinate.longitude)
    }

    /// 打开系统「设置…」窗口（SwiftUI Settings 场景）。
    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    static func boundingRegion(for coordinates: [GeoCoordinate], padding: Double = 1.4) -> MKCoordinateRegion {
        var minimumLatitude = coordinates[0].latitude
        var maximumLatitude = coordinates[0].latitude
        var minimumLongitude = coordinates[0].longitude
        var maximumLongitude = coordinates[0].longitude

        for coordinate in coordinates {
            minimumLatitude = min(minimumLatitude, coordinate.latitude)
            maximumLatitude = max(maximumLatitude, coordinate.latitude)
            minimumLongitude = min(minimumLongitude, coordinate.longitude)
            maximumLongitude = max(maximumLongitude, coordinate.longitude)
        }

        let latitudeDelta = max((maximumLatitude - minimumLatitude) * padding, 0.0015)
        let longitudeDelta = max((maximumLongitude - minimumLongitude) * padding, 0.0015)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minimumLatitude + maximumLatitude) / 2,
                longitude: (minimumLongitude + maximumLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: min(latitudeDelta, 160),
                longitudeDelta: min(longitudeDelta, 350)
            )
        )
    }

    // MARK: - 其他

    func revealInFinder(_ photo: PhotoItem) {
        NSWorkspace.shared.activateFileViewerSelecting([photo.url])
    }

    func showToast(
        _ message: String,
        kind: ToastMessage.Kind = .info,
        action: ToastAction = .none,
        duration: Duration = .seconds(4)
    ) {
        toastTask?.cancel()
        let newToast = ToastMessage(message: message, kind: kind, action: action)
        withAnimation(.snappy(duration: 0.2)) {
            toast = newToast
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.2)) {
                self?.toast = nil
            }
        }
    }

    private static let openPanelContentTypes: [UTType] = {
        let types = PhotoFormats.readableExtensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.image] : types
    }()
}

// MARK: - 撤销记录

@MainActor
struct PhotoLocationChange {
    let photo: PhotoItem
    let oldCoordinate: GeoCoordinate?
    let newCoordinate: GeoCoordinate?
}

@MainActor
struct PhotoLocationEdit {
    let changes: [PhotoLocationChange]
}
