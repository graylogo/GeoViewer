import AppKit
import Foundation
import Observation

/// 列表 / 地图 / 检查器共享的照片条目。
///
/// `details` 是磁盘上的真实状态，`stagedCoordinate` 是尚未写入的临时位置，
/// 两者不同即表示有未保存的修改。
@MainActor
@Observable
final class PhotoItem: Identifiable {
    let id = UUID()
    let url: URL
    var details: PhotoDetails

    /// 已经写回磁盘的位置（来源于最近一次读取的元数据）。
    var savedCoordinate: GeoCoordinate? { details.gps?.coordinate }

    /// 用户当前编辑的位置，未保存前只存在于内存。
    var stagedCoordinate: GeoCoordinate?

    var thumbnails: [Int: NSImage] = [:]
    var pendingThumbnailSizes: Set<Int> = []

    /// 缩略图失效计数：变化时让界面重新加载预览。
    var thumbnailVersion = 0

    /// 供 `.task(id:)` 使用，保证失效后一定会重新加载而不是永远空白。
    var thumbnailToken: String { "\(id)-\(thumbnailVersion)" }

    func invalidateThumbnails() {
        thumbnails.removeAll()
        pendingThumbnailSizes.removeAll()
        thumbnailVersion += 1
    }

    init(url: URL, details: PhotoDetails) {
        self.url = url
        self.details = details
        self.stagedCoordinate = details.gps?.coordinate
    }

    var isDirty: Bool { stagedCoordinate != savedCoordinate }
    var hasLocation: Bool { stagedCoordinate != nil }
    var isWritable: Bool { details.isWritable }

    var displayName: String { url.lastPathComponent }
    var directoryPath: String { url.deletingLastPathComponent().path }
    var fileExtension: String { url.pathExtension.lowercased() }

    /// 保存成功后同步内存状态，避免反复读取磁盘。
    func commitSavedCoordinate(_ coordinate: GeoCoordinate?) {
        if var gps = details.gps, let coordinate {
            gps.coordinate = coordinate
            details.gps = gps
        } else if let coordinate {
            details.gps = GPSInfo(coordinate: coordinate)
        } else {
            details.gps = nil
        }
        stagedCoordinate = coordinate
    }

    func revertToSaved() {
        stagedCoordinate = savedCoordinate
    }
}
