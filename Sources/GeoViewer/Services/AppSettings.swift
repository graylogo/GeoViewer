import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let autoSave = "settings.autoSaveAfterEdit"
        static let backupEnabled = "settings.backupEnabled"
        static let backupFolder = "settings.backupFolderPath"
        static let backupNoticeDismissed = "settings.backupNoticeDismissed"
        static let sortOrder = "settings.sortOrder"
        static let groupByFolder = "settings.groupByFolder"
        static let mapStyle = "settings.mapStyle"
        static let pinSize = "settings.pinSize"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// 修改位置后立即写入文件（默认关闭，先暂存再按 ⌘S 保存更安全）。
    var autoSaveAfterEdit: Bool {
        didSet { defaults.set(autoSaveAfterEdit, forKey: Key.autoSave) }
    }

    /// 写入前备份原文件（默认关闭，需要时可在设置中开启）。
    var backupEnabled: Bool {
        didSet { defaults.set(backupEnabled, forKey: Key.backupEnabled) }
    }

    /// 用户是否已在启动提示里选择「暂不开启」，选过之后不再重复提示。
    var backupNoticeDismissed: Bool {
        didSet { defaults.set(backupNoticeDismissed, forKey: Key.backupNoticeDismissed) }
    }

    /// 照片列表排序方式。
    var sortOrder: PhotoSortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: Key.sortOrder) }
    }

    /// 照片列表是否按文件夹分组。
    var groupByFolder: Bool {
        didSet { defaults.set(groupByFolder, forKey: Key.groupByFolder) }
    }

    /// 备份根目录，默认放在 ~/Pictures/GeoViewer 备份。
    var backupFolderPath: String {
        didSet { defaults.set(backupFolderPath, forKey: Key.backupFolder) }
    }

    var mapStyle: MapStyleKind {
        didSet { defaults.set(mapStyle.rawValue, forKey: Key.mapStyle) }
    }

    /// 地图缩略图标记边长。
    var pinSize: Double {
        didSet { defaults.set(pinSize, forKey: Key.pinSize) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        autoSaveAfterEdit = defaults.bool(forKey: Key.autoSave)
        // 默认关闭备份；已经显式改过的用户保留其选择。
        backupEnabled = defaults.object(forKey: Key.backupEnabled) as? Bool ?? false
        backupNoticeDismissed = defaults.bool(forKey: Key.backupNoticeDismissed)
        backupFolderPath = defaults.string(forKey: Key.backupFolder) ?? Self.defaultBackupFolder().path
        sortOrder = PhotoSortOrder(rawValue: defaults.string(forKey: Key.sortOrder) ?? "") ?? .captureDateAscending
        groupByFolder = defaults.object(forKey: Key.groupByFolder) as? Bool ?? true
        mapStyle = MapStyleKind(rawValue: defaults.string(forKey: Key.mapStyle) ?? "") ?? .standard

        let storedPinSize = defaults.double(forKey: Key.pinSize)
        pinSize = storedPinSize > 0 ? storedPinSize : 54
    }

    var backupFolderURL: URL? {
        let path = backupFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func defaultBackupFolder() -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("GeoViewer 备份", isDirectory: true)
    }
}
