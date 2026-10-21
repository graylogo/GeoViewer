import Foundation

/// 只读的照片概要信息，用于界面展示与命令行输出。
///
/// 该类型刻意只包含值类型，便于在工作线程读取后安全地送回主线程。
struct PhotoDetails: Sendable, Codable, Hashable {
    var formatDescription: String
    var isWritable: Bool

    var typeIdentifier: String?
    var width: Int?
    var height: Int?
    var fileSize: Int64?
    var fileModificationDate: Date?
    var orientation: Int?
    var colorModel: String?

    var captureDate: Date?
    var make: String?
    var model: String?
    var lensModel: String?
    var software: String?
    var artist: String?
    var copyright: String?

    var focalLength: Double?
    var focalLength35mm: Int?
    var aperture: Double?
    var exposureTime: Double?
    var exposureBias: Double?
    var iso: Int?

    var gps: GPSInfo?

    init(formatDescription: String = "未知格式", isWritable: Bool = false) {
        self.formatDescription = formatDescription
        self.isWritable = isWritable
    }
}

/// 支持的图片格式。写入范围刻意保持保守：只处理已知可安全写回 EXIF/GPS 的容器。
enum PhotoFormats {
    static let readableExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "heic", "heif", "tif", "tiff", "png",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef",
        "webp", "gif", "bmp"
    ]

    /// RAW 与 PNG 等格式暂时只读，避免破坏私有元数据结构。
    static let writableExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "heic", "heif", "tif", "tiff"
    ]

    static func isReadable(_ url: URL) -> Bool {
        readableExtensions.contains(url.pathExtension.lowercased())
    }

    static func isWritable(_ url: URL) -> Bool {
        writableExtensions.contains(url.pathExtension.lowercased())
    }

    static func formatName(for url: URL) -> String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "未知格式" : ext
    }
}
