import Foundation

enum Format {
    static func coordinate(_ coordinate: GeoCoordinate?) -> String {
        coordinate?.formatted ?? "未记录"
    }

    static func fileSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "未知" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    static func dimensions(width: Int?, height: Int?) -> String {
        guard let width, let height else { return "未知" }
        return "\(width) × \(height)"
    }

    static func focalLength(_ value: Double?, equivalent: Int?) -> String {
        guard let value else { return "未知" }
        if let equivalent {
            return String(format: "%.0f 毫米（等效 %d 毫米）", value, equivalent)
        }
        return String(format: "%.0f 毫米", value)
    }

    static func aperture(_ value: Double?) -> String {
        guard let value else { return "未知" }
        return String(format: "f/%.1f", value)
    }

    static func shutter(_ value: Double?) -> String {
        guard let value, value > 0 else { return "未知" }
        if value >= 1 {
            return String(format: "%.1f 秒", value)
        }
        return "1/\(Int((1 / value).rounded())) 秒"
    }

    static func iso(_ value: Int?) -> String {
        guard let value else { return "未知" }
        return "ISO \(value)"
    }

    static func exposureBias(_ value: Double?) -> String {
        guard let value else { return "未知" }
        return String(format: "%+.1f EV", value)
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 列表用的紧凑时间戳，精确到秒，便于按拍摄时间判断照片是否同一批。
    ///
    /// 固定 POSIX 区域与 24 小时制，避免跟随系统 12/24 小时设置漂移，
    /// 导致同一批照片在不同机器上看起来对不齐。
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func captureTimestamp(_ date: Date?) -> String {
        guard let date else { return "无拍摄时间" }
        return timestampFormatter.string(from: date)
    }

    static func altitude(_ info: GPSInfo?) -> String {
        guard let altitude = info?.altitude else { return "未记录" }
        return String(format: "%.1f 米%@", abs(altitude), altitude < 0 ? "（海平面以下）" : "")
    }

    static func direction(_ info: GPSInfo?) -> String {
        guard let direction = info?.direction else { return "未记录" }
        return String(format: "%.0f°", direction)
    }

    static func camera(make: String?, model: String?) -> String {
        switch (make, model) {
        case let (make?, model?):
            return model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
        case let (make?, nil):
            return make
        case let (nil, model?):
            return model
        default:
            return "未知"
        }
    }

    static func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "未记录" }
        return value
    }

    static func filePermission(writable: Bool) -> String {
        writable ? "可写入位置" : "只读（暂不支持写入）"
    }

    static func latitudeDirection(_ coordinate: GeoCoordinate?) -> String {
        guard let coordinate else { return "-" }
        return coordinate.latitude >= 0 ? "北纬" : "南纬"
    }

    static func longitudeDirection(_ coordinate: GeoCoordinate?) -> String {
        guard let coordinate else { return "-" }
        return coordinate.longitude >= 0 ? "东经" : "西经"
    }
}
