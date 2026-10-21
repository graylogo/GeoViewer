import Foundation
import ImageIO

enum MetadataError: LocalizedError {
    case unsupportedFormat(String)
    case unreadable
    case metadataUnavailable
    case cannotCreateDestination
    case copyFailed(String)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "暂不支持写入 \(ext.isEmpty ? "该" : ext.uppercased()) 格式"
        case .unreadable:
            return "无法读取文件或元数据"
        case .metadataUnavailable:
            return "无法安全读取该文件的元数据，已跳过写入"
        case .cannotCreateDestination:
            return "无法创建输出数据"
        case .copyFailed(let message):
            return "写入元数据失败：\(message)"
        case .fileSystem(let message):
            return "文件写入失败：\(message)"
        }
    }
}

/// 位置写入器。
///
/// 实现要点：
/// 1. 通过 `CGImageMetadata` 在原始元数据副本上只改 GPS 标签，其它标签保持原样；
/// 2. 通过 `CGImageDestinationCopyImageSource` 直接复制压缩后的图像数据，不重新编码，因此画质无损；
/// 3. 先写同目录临时文件，再用 `replaceItemAt` 替换，保留创建时间、权限与扩展属性。
enum MetadataWriter {
    static func setLocation(_ coordinate: GeoCoordinate?, for url: URL) throws {
        guard PhotoFormats.isWritable(url) else {
            throw MetadataError.unsupportedFormat(url.pathExtension)
        }

        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe":
            let original = try readData(at: url)
            let updated = try JPEGLocationWriter.setLocation(coordinate, in: original)
            guard updated != original else { return }
            try replaceFile(at: url, with: updated)
        case "tif", "tiff":
            let original = try readData(at: url)
            let updated = try TIFFLocationEditor.setLocation(coordinate, in: [UInt8](original))
            guard updated != [UInt8](original) else { return }
            try replaceFile(at: url, with: Data(updated))
        default:
            try writeViaImageIO(coordinate, for: url)
        }
    }

    private static func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw MetadataError.fileSystem(error.localizedDescription)
        }
    }

    /// HEIC / HEIF：ImageIO 的元数据复制路径不会重新编码，实测可保留其余标签。
    private static func writeViaImageIO(_ coordinate: GeoCoordinate?, for url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeIdentifier = CGImageSourceGetType(source)
        else { throw MetadataError.unreadable }

        let metadata: CGMutableImageMetadata
        if let existing = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            guard let copy = CGImageMetadataCreateMutableCopy(existing) else {
                throw MetadataError.metadataUnavailable
            }
            metadata = copy
        } else {
            // 完全没有元数据的文件（例如刚导出的图片），可以从零创建 GPS 标签。
            guard !hasExistingMetadata(source) else { throw MetadataError.metadataUnavailable }
            metadata = CGImageMetadataCreateMutable()
        }

        if let coordinate {
            setGPS(coordinate, in: metadata)
        } else {
            removeGPSTags(in: metadata)
        }

        let data = try makeData(metadata: metadata, typeIdentifier: typeIdentifier, source: source)
        try replaceFile(at: url, with: data)
    }

    // MARK: - GPS 标签

    private static func setGPS(_ coordinate: GeoCoordinate, in metadata: CGMutableImageMetadata) {
        _ = CGImageMetadataSetValueWithPath(metadata, nil, "exif:GPSLatitude" as CFString, abs(coordinate.latitude) as CFNumber)
        _ = CGImageMetadataSetValueWithPath(metadata, nil, "exif:GPSLatitudeRef" as CFString, (coordinate.latitude >= 0 ? "N" : "S") as CFString)
        _ = CGImageMetadataSetValueWithPath(metadata, nil, "exif:GPSLongitude" as CFString, abs(coordinate.longitude) as CFNumber)
        _ = CGImageMetadataSetValueWithPath(metadata, nil, "exif:GPSLongitudeRef" as CFString, (coordinate.longitude >= 0 ? "E" : "W") as CFString)
    }

    private static func removeGPSTags(in metadata: CGMutableImageMetadata) {
        guard let tags = CGImageMetadataCopyTags(metadata) else { return }
        for case let tag as CGImageMetadataTag in (tags as NSArray) {
            let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            guard prefix == "exif", name.hasPrefix("GPS") else { continue }
            _ = CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString)
        }
    }

    private static func hasExistingMetadata(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        let keys: [CFString] = [
            kCGImagePropertyExifDictionary,
            kCGImagePropertyTIFFDictionary,
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary
        ]
        return keys.contains { key in
            guard let dictionary = properties[key] as? [CFString: Any] else { return false }
            return !dictionary.isEmpty
        }
    }

    // MARK: - 写出

    private static func makeData(
        metadata: CGMutableImageMetadata,
        typeIdentifier: CFString,
        source: CGImageSource
    ) throws -> Data {
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, typeIdentifier, 1, nil)
        else { throw MetadataError.cannotCreateDestination }

        var error: Unmanaged<CFError>?
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "未知错误"
            throw MetadataError.copyFailed(message)
        }
        return data as Data
    }

    private static func replaceFile(at url: URL, with data: Data) throws {
        let fileManager = FileManager.default
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".geoviewer-\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporaryURL, options: .atomic)
        } catch {
            throw MetadataError.fileSystem(error.localizedDescription)
        }

        let originalAttributes = try? fileManager.attributesOfItem(atPath: url.path)

        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL, backupItemName: nil, options: [])
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw MetadataError.fileSystem(error.localizedDescription)
        }

        var attributes: [FileAttributeKey: Any] = [:]
        if let creationDate = originalAttributes?[.creationDate] as? Date {
            attributes[.creationDate] = creationDate
        }
        if let modificationDate = originalAttributes?[.modificationDate] as? Date {
            attributes[.modificationDate] = modificationDate
        }
        if let permissions = originalAttributes?[.posixPermissions] {
            attributes[.posixPermissions] = permissions
        }
        if !attributes.isEmpty {
            try? fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}
