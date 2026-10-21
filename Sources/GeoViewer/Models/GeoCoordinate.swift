import CoreLocation
import Foundation

/// 与 UI 解耦的经纬度值类型，便于跨并发域传递。
struct GeoCoordinate: Hashable, Codable, Sendable {
    var latitude: Double
    var longitude: Double

    var location: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        CLLocationCoordinate2DIsValid(location) && !(latitude == 0 && longitude == 0)
    }

    /// 便于复制粘贴的十进制格式。
    var formatted: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }

    var shortDescription: String {
        let latitudeMark = latitude >= 0 ? "N" : "S"
        let longitudeMark = longitude >= 0 ? "E" : "W"
        return String(format: "%.5f°%@ %.5f°%@", abs(latitude), latitudeMark, abs(longitude), longitudeMark)
    }

    /// EXIF 使用度分秒有理数存储，写回后允许米级误差。
    func isClose(to other: GeoCoordinate, tolerance: Double = 0.00001) -> Bool {
        abs(latitude - other.latitude) <= tolerance && abs(longitude - other.longitude) <= tolerance
    }

    /// 解析 “30.2741, 120.1551” 这类输入，支持中英文逗号与空格分隔。
    static func parse(_ text: String) -> GeoCoordinate? {
        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        let coordinate = GeoCoordinate(latitude: parts[0], longitude: parts[1])
        guard (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) else { return nil }
        return coordinate
    }
}

/// 照片中的 GPS 信息（EXIF GPS IFD）。
struct GPSInfo: Hashable, Codable, Sendable {
    var coordinate: GeoCoordinate
    var altitude: Double?
    var isBelowSeaLevel: Bool = false
    var timestamp: Date?
    var direction: Double?
    var speed: Double?
    var horizontalError: Double?
}
