import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 基于 ImageIO 的元数据读取器，不做任何修改。
enum MetadataReader {
    static func read(url: URL) -> PhotoDetails? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        let typeIdentifier = CGImageSourceGetType(source) as String?
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])

        var details = PhotoDetails(
            formatDescription: formatDescription(for: typeIdentifier, url: url),
            isWritable: PhotoFormats.isWritable(url)
        )

        details.typeIdentifier = typeIdentifier
        details.width = integer(properties, kCGImagePropertyPixelWidth)
        details.height = integer(properties, kCGImagePropertyPixelHeight)
        details.fileSize = resourceValues?.fileSize.map(Int64.init)
        details.fileModificationDate = resourceValues?.contentModificationDate
        details.orientation = integer(properties, kCGImagePropertyOrientation)
        details.colorModel = properties[kCGImagePropertyColorModel] as? String

        details.make = text(tiff, kCGImagePropertyTIFFMake)
        details.model = text(tiff, kCGImagePropertyTIFFModel)
        details.software = text(tiff, kCGImagePropertyTIFFSoftware)
        details.artist = text(tiff, kCGImagePropertyTIFFArtist)
        details.copyright = text(tiff, kCGImagePropertyTIFFCopyright)

        details.lensModel = text(exif, kCGImagePropertyExifLensModel) ?? text(aux, kCGImagePropertyExifAuxLensModel)
        details.focalLength = number(exif, kCGImagePropertyExifFocalLength)
        details.focalLength35mm = integer(exif, kCGImagePropertyExifFocalLenIn35mmFilm)
        details.aperture = number(exif, kCGImagePropertyExifFNumber)
        details.exposureTime = number(exif, kCGImagePropertyExifExposureTime)
        details.exposureBias = number(exif, kCGImagePropertyExifExposureBiasValue)
        details.iso = isoValue(exif)

        details.captureDate = parseExifDate(text(exif, kCGImagePropertyExifDateTimeOriginal))
            ?? parseExifDate(text(exif, kCGImagePropertyExifDateTimeDigitized))
            ?? parseExifDate(text(tiff, kCGImagePropertyTIFFDateTime))

        details.gps = readGPS(gps)
        return details
    }

    // MARK: - 字段解析

    private static func formatDescription(for typeIdentifier: String?, url: URL) -> String {
        if let typeIdentifier, let type = UTType(typeIdentifier) {
            if let description = type.localizedDescription, !description.isEmpty {
                return description
            }
            return type.identifier
        }
        return PhotoFormats.formatName(for: url)
    }

    private static func readGPS(_ dictionary: [CFString: Any]?) -> GPSInfo? {
        guard let dictionary,
              let latitudeValue = number(dictionary, kCGImagePropertyGPSLatitude),
              let longitudeValue = number(dictionary, kCGImagePropertyGPSLongitude)
        else { return nil }

        // 很多相机把未定位的照片写成 0,0，这里视为「没有位置」。
        guard latitudeValue != 0 || longitudeValue != 0 else { return nil }

        let latitudeRef = (text(dictionary, kCGImagePropertyGPSLatitudeRef) ?? "N").uppercased()
        let longitudeRef = (text(dictionary, kCGImagePropertyGPSLongitudeRef) ?? "E").uppercased()

        let coordinate = GeoCoordinate(
            latitude: latitudeRef.hasPrefix("S") ? -latitudeValue : latitudeValue,
            longitude: longitudeRef.hasPrefix("W") ? -longitudeValue : longitudeValue
        )
        guard coordinate.isValid else { return nil }

        var info = GPSInfo(coordinate: coordinate)

        if let altitude = number(dictionary, kCGImagePropertyGPSAltitude) {
            let belowSeaLevel = integer(dictionary, kCGImagePropertyGPSAltitudeRef) == 1
            info.isBelowSeaLevel = belowSeaLevel
            info.altitude = belowSeaLevel ? -altitude : altitude
        }

        info.direction = number(dictionary, kCGImagePropertyGPSImgDirection)
        info.speed = number(dictionary, kCGImagePropertyGPSSpeed)
        info.horizontalError = number(dictionary, kCGImagePropertyGPSHPositioningError)
        info.timestamp = gpsTimestamp(dictionary)
        return info
    }

    private static func isoValue(_ exif: [CFString: Any]) -> Int? {
        if let values = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any],
           let first = values.first as? NSNumber {
            return first.intValue
        }
        return integer(exif, kCGImagePropertyExifISOSpeedRatings)
    }

    private static func parseExifDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(trimmed.prefix(19)))
    }

    private static func gpsTimestamp(_ dictionary: [CFString: Any]) -> Date? {
        guard let stamp = text(dictionary, kCGImagePropertyGPSDateStamp) else { return nil }
        let dateParts = stamp.split(separator: ":").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }

        var components = DateComponents()
        components.year = dateParts[0]
        components.month = dateParts[1]
        components.day = dateParts[2]

        if let time = dictionary[kCGImagePropertyGPSTimeStamp] as? [Any], time.count >= 3 {
            let hour = (time[0] as? NSNumber)?.intValue ?? 0
            let minute = (time[1] as? NSNumber)?.intValue ?? 0
            let second = (time[2] as? NSNumber)?.intValue ?? 0
            components.hour = hour
            components.minute = minute
            components.second = second
        }

        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)
    }

    // MARK: - 类型转换

    private static func number(_ dictionary: [CFString: Any], _ key: CFString) -> Double? {
        switch dictionary[key] {
        case let value as NSNumber: return value.doubleValue
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as String: return Double(value)
        default: return nil
        }
    }

    private static func integer(_ dictionary: [CFString: Any], _ key: CFString) -> Int? {
        switch dictionary[key] {
        case let value as NSNumber: return value.intValue
        case let value as Int: return value
        case let value as Double: return Int(value)
        case let value as String: return Int(value)
        default: return nil
        }
    }

    private static func text(_ dictionary: [CFString: Any], _ key: CFString) -> String? {
        guard let value = dictionary[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
