import AppKit
import MapKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

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
    var undoable: Bool = false
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
    @ObservationIgnored private let settings = AppSettings.shared

    init() {
        AppModel.shared = self
    }

    // MARK: - 派生状态

    var filteredPhotos: [PhotoItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return photos }
        return photos.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.directoryPath.localizedCaseInsensitiveContains(query)
        }
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
        Task { await ThumbnailProvider.shared.clearCache() }
    }

    func removeFromList(ids: Set<PhotoItem.ID>) {
        photos.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let primaryID, !photos.contains(where: { $0.id == primaryID }) {
            self.primaryID = nil
        }
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
        push(PhotoLocationEdit(changes: changes))

        let result: String
        if let coordinate {
            result = "已将 \(targets.count) 张照片定位到 \(coordinate.shortDescription)"
        } else {
            result = "已清除 \(targets.count) 张照片的位置"
        }
        let suffix = skipped > 0 ? "（\(skipped) 张只读照片已跳过）" : ""
        showToast(result + suffix, kind: .success, undoable: coordinate != nil || !targets.isEmpty)

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
        redoStack.append(edit)
        showToast("已撤销位置修改", kind: .info)
    }

    func redo() {
        guard let edit = redoStack.popLast() else { return }
        for change in edit.changes {
            change.photo.stagedCoordinate = change.newCoordinate
        }
        undoStack.append(edit)
        showToast("已重做位置修改", kind: .info)
    }

    func discardChanges() {
        guard hasUnsavedChanges else { return }
        let count = dirtyCount
        for photo in photos where photo.isDirty {
            photo.revertToSaved()
        }
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

                    if let coordinate {
                        if let actual = refreshed.gps?.coordinate, !actual.isClose(to: coordinate) {
                            failures.append("\(url.lastPathComponent)：写入后校验失败，位置未生效")
                        }
                    } else if refreshed.gps != nil {
                        failures.append("\(url.lastPathComponent)：清除位置后仍能读到 GPS 信息")
                    }
                } else {
                    photo.commitSavedCoordinate(coordinate)
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
            showToast("已保存 \(total) 张照片的位置", kind: .success)
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

    func pasteCoordinateToSelection() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              let coordinate = GeoCoordinate.parse(raw)
        else {
            showToast("剪贴板中没有有效的坐标", kind: .warning)
            return
        }
        setLocationForSelection(coordinate)
    }

    // MARK: - 地图

    /// 网格聚合：随地图缩放自动合并 / 拆分，形成相册式的缩略图堆叠。
    var clusters: [PhotoCluster] {
        let located = photos.filter { $0.stagedCoordinate != nil }
        guard !located.isEmpty else { return [] }

        let latitudeCell = max(mapRegion.span.latitudeDelta / 8, 0.00003)
        let longitudeCell = max(mapRegion.span.longitudeDelta / 8, 0.00003)

        var buckets: [String: [PhotoItem]] = [:]
        for photo in located {
            guard let coordinate = photo.stagedCoordinate else { continue }
            let latitudeIndex = Int((coordinate.latitude / latitudeCell).rounded(.down))
            let longitudeIndex = Int((coordinate.longitude / longitudeCell).rounded(.down))
            buckets["\(latitudeIndex):\(longitudeIndex)", default: []].append(photo)
        }

        return buckets.map { key, items in
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

    func showToast(_ message: String, kind: ToastMessage.Kind = .info, undoable: Bool = false) {
        toastTask?.cancel()
        let newToast = ToastMessage(message: message, kind: kind, undoable: undoable)
        withAnimation(.snappy(duration: 0.2)) {
            toast = newToast
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
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
