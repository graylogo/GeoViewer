import Foundation

enum EXIFWriteError: LocalizedError {
    case malformed(String)
    case tooLarge
    case unsupportedContainer

    var errorDescription: String? {
        switch self {
        case .malformed(let reason):
            return "无法解析照片的 EXIF 结构：\(reason)"
        case .tooLarge:
            return "EXIF 数据超过 JPEG 段落上限（64 KB），已跳过写入"
        case .unsupportedContainer:
            return "无法识别的图片容器格式"
        }
    }
}

/// TIFF / EXIF 结构的字节级编辑器。
///
/// 只做三件事：
/// 1. 若 GPS IFD 已存在且四个核心标签齐全 —— 原地覆盖经纬度值（不移动任何数据）；
/// 2. 否则在文件末尾追加新的 GPS IFD 与新 IFD0，并把 TIFF 头的 IFD0 指针指过去；
/// 3. 清除位置时把 IFD0 中的 GPS 指针移除。
///
/// 除上述字节外不做任何重排，因此 MakerNotes、缩略图、色彩配置、私有 IFD 的偏移全部保持有效。
enum TIFFLocationEditor {
    struct RawEntry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var valueField: [UInt8]
        var entryOffset: Int
    }

    private struct ValueEntry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var value: [UInt8]
    }

    // MARK: - 入口

    static func setLocation(_ coordinate: GeoCoordinate?, in blob: [UInt8]) throws -> [UInt8] {
        let little = try byteOrder(of: blob)
        guard blob.count >= 8 else { throw EXIFWriteError.malformed("文件头不完整") }
        let ifd0Offset = Int(try uint32(blob, 4, little))
        guard ifd0Offset >= 8, ifd0Offset + 2 <= blob.count else {
            throw EXIFWriteError.malformed("IFD0 偏移无效")
        }

        let ifd0 = try readIFD(blob, at: ifd0Offset, little)
        let gpsPointerIndex = ifd0.entries.firstIndex { $0.tag == 0x8825 }

        guard let coordinate else {
            guard let gpsPointerIndex else { return blob }
            // 移除 GPS 指针：只重写 IFD0 与 TIFF 头指针。
            var entries = ifd0.entries
            entries.remove(at: gpsPointerIndex)
            return try rewriteIFD0(in: blob, entries: entries, next: ifd0.next, little: little)
        }

        if let gpsPointerIndex {
            let pointer = Int(try uint32(ifd0.entries[gpsPointerIndex].valueField, 0, little))
            if pointer > 0, let patched = patchInPlace(blob, gpsOffset: pointer, coordinate: coordinate, little: little) {
                return patched
            }
        }

        // 需要新建 GPS IFD：复制原有 GPS 附加标签（海拔、方向、时间等）。
        var preserved: [ValueEntry] = []
        if let gpsPointerIndex {
            let pointer = Int(try uint32(ifd0.entries[gpsPointerIndex].valueField, 0, little))
            if pointer > 0, pointer + 2 <= blob.count,
               let gpsIFD = try? readIFD(blob, at: pointer, little) {
                for entry in gpsIFD.entries where !(0x0000...0x0004).contains(entry.tag) {
                    if let value = valueEntry(for: entry, in: blob, little: little) {
                        preserved.append(value)
                    }
                }
            }
        }

        var output = blob
        if output.count % 2 == 1 { output.append(0) }

        let gpsStart = output.count
        let gpsBlock = buildIFD(
            entries: gpsEntries(coordinate: coordinate, preserving: preserved, little: little),
            at: gpsStart,
            next: 0,
            little: little
        )
        output += gpsBlock
        if output.count % 2 == 1 { output.append(0) }

        var entries = ifd0.entries
        let gpsEntry = RawEntry(
            tag: 0x8825,
            type: 4,
            count: 1,
            valueField: encodedUInt32(UInt32(gpsStart), little),
            entryOffset: 0
        )
        if let gpsPointerIndex {
            entries[gpsPointerIndex] = gpsEntry
        } else {
            entries.append(gpsEntry)
        }

        let newIFD0Start = output.count
        output += buildRawIFD(entries: entries, next: ifd0.next, little: little)
        putUInt32(UInt32(newIFD0Start), into: &output, at: 4, little)
        return output
    }

    /// 生成一个只含 GPS 位置的最小 TIFF 结构（用于本来没有 EXIF 的 JPEG）。
    static func makeFreshTIFF(coordinate: GeoCoordinate) -> [UInt8] {
        let little = true
        let ifd0Size = 2 + 12 + 4
        let gpsStart = 8 + ifd0Size
        let gpsBlock = buildIFD(
            entries: gpsEntries(coordinate: coordinate, preserving: [], little: little),
            at: gpsStart,
            next: 0,
            little: little
        )

        var ifd0: [UInt8] = []
        ifd0 += encodedUInt16(1, little)
        ifd0 += encodedUInt16(0x8825, little)
        ifd0 += encodedUInt16(4, little)
        ifd0 += encodedUInt32(1, little)
        ifd0 += encodedUInt32(UInt32(gpsStart), little)
        ifd0 += encodedUInt32(0, little)

        var tiff: [UInt8] = [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]
        tiff += ifd0
        tiff += gpsBlock
        return tiff
    }

    // MARK: - 原地更新

    private static func patchInPlace(
        _ blob: [UInt8],
        gpsOffset: Int,
        coordinate: GeoCoordinate,
        little: Bool
    ) -> [UInt8]? {
        guard gpsOffset + 2 <= blob.count,
              let gpsIFD = try? readIFD(blob, at: gpsOffset, little)
        else { return nil }

        var latitudeRange: Range<Int>?
        var longitudeRange: Range<Int>?
        var latitudeRefOffset: Int?
        var longitudeRefOffset: Int?

        for entry in gpsIFD.entries {
            switch entry.tag {
            case 0x0001:
                if entry.type == 2, entry.count >= 2 { latitudeRefOffset = entry.entryOffset + 8 }
            case 0x0003:
                if entry.type == 2, entry.count >= 2 { longitudeRefOffset = entry.entryOffset + 8 }
            case 0x0002:
                if entry.type == 5, entry.count == 3,
                   let offset = try? uint32(entry.valueField, 0, little),
                   Int(offset) + 24 <= blob.count {
                    latitudeRange = Int(offset)..<(Int(offset) + 24)
                }
            case 0x0004:
                if entry.type == 5, entry.count == 3,
                   let offset = try? uint32(entry.valueField, 0, little),
                   Int(offset) + 24 <= blob.count {
                    longitudeRange = Int(offset)..<(Int(offset) + 24)
                }
            default:
                break
            }
        }

        guard let latitudeRange, let longitudeRange, let latitudeRefOffset, let longitudeRefOffset else {
            return nil
        }

        var output = blob
        writeRationals(&output, at: latitudeRange.lowerBound, value: coordinate.latitude, little)
        writeRationals(&output, at: longitudeRange.lowerBound, value: coordinate.longitude, little)
        output[latitudeRefOffset] = coordinate.latitude >= 0 ? 0x4E : 0x53
        output[longitudeRefOffset] = coordinate.longitude >= 0 ? 0x45 : 0x57
        return output
    }

    // MARK: - IFD 读写

    private static func readIFD(_ blob: [UInt8], at offset: Int, _ little: Bool) throws -> (entries: [RawEntry], next: UInt32) {
        let count = Int(try uint16(blob, offset, little))
        guard count <= 4096 else { throw EXIFWriteError.malformed("IFD 条目过多") }
        let entriesEnd = offset + 2 + count * 12
        guard entriesEnd + 4 <= blob.count else { throw EXIFWriteError.malformed("IFD 越界") }

        var entries: [RawEntry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            let entryOffset = offset + 2 + index * 12
            guard let tag = try? uint16(blob, entryOffset, little),
                  let type = try? uint16(blob, entryOffset + 2, little),
                  let valueCount = try? uint32(blob, entryOffset + 4, little),
                  entryOffset + 12 <= blob.count
            else { throw EXIFWriteError.malformed("条目损坏") }

            entries.append(RawEntry(
                tag: tag,
                type: type,
                count: valueCount,
                valueField: Array(blob[(entryOffset + 8)..<(entryOffset + 12)]),
                entryOffset: entryOffset
            ))
        }

        let next = try uint32(blob, entriesEnd, little)
        return (entries, next)
    }

    private static func rewriteIFD0(
        in blob: [UInt8],
        entries: [RawEntry],
        next: UInt32,
        little: Bool
    ) throws -> [UInt8] {
        var output = blob
        if output.count % 2 == 1 { output.append(0) }
        let start = output.count
        output += buildRawIFD(entries: entries, next: next, little: little)
        putUInt32(UInt32(start), into: &output, at: 4, little)
        return output
    }

    /// 原样保留每个条目的 4 字节值域（其中的偏移保持不变）。
    private static func buildRawIFD(entries: [RawEntry], next: UInt32, little: Bool) -> [UInt8] {
        let sorted = entries.sorted { $0.tag < $1.tag }
        var block: [UInt8] = []
        block.reserveCapacity(2 + sorted.count * 12 + 4)
        block += encodedUInt16(UInt16(sorted.count), little)
        for entry in sorted {
            block += encodedUInt16(entry.tag, little)
            block += encodedUInt16(entry.type, little)
            block += encodedUInt32(entry.count, little)
            block += entry.valueField
        }
        block += encodedUInt32(next, little)
        return block
    }

    /// 构建 IFD，并把它需要的外部数据紧随其后追加，自动计算绝对偏移。
    private static func buildIFD(entries: [ValueEntry], at start: Int, next: UInt32, little: Bool) -> [UInt8] {
        let sorted = entries.sorted { $0.tag < $1.tag }
        let headerSize = 2 + sorted.count * 12 + 4
        var block: [UInt8] = []
        block.reserveCapacity(headerSize + 64)
        block += encodedUInt16(UInt16(sorted.count), little)

        var dataBlob: [UInt8] = []
        for entry in sorted {
            block += encodedUInt16(entry.tag, little)
            block += encodedUInt16(entry.type, little)
            block += encodedUInt32(entry.count, little)

            if entry.value.count <= 4 {
                var inlineValue = entry.value
                if inlineValue.count < 4 {
                    inlineValue += Array(repeating: 0, count: 4 - inlineValue.count)
                }
                block += inlineValue
            } else {
                let dataOffset = start + headerSize + dataBlob.count
                block += encodedUInt32(UInt32(dataOffset), little)
                dataBlob += entry.value
                if dataBlob.count % 2 == 1 { dataBlob.append(0) }
            }
        }

        block += encodedUInt32(next, little)
        block += dataBlob
        return block
    }

    private static func gpsEntries(coordinate: GeoCoordinate, preserving: [ValueEntry], little: Bool) -> [ValueEntry] {
        let latitudeRef: UInt8 = coordinate.latitude >= 0 ? 0x4E : 0x53
        let longitudeRef: UInt8 = coordinate.longitude >= 0 ? 0x45 : 0x57

        var entries: [ValueEntry] = [
            ValueEntry(tag: 0x0000, type: 1, count: 4, value: [2, 3, 0, 0]),
            ValueEntry(tag: 0x0001, type: 2, count: 2, value: [latitudeRef, 0]),
            ValueEntry(tag: 0x0002, type: 5, count: 3, value: rationalData(for: coordinate.latitude, little: little)),
            ValueEntry(tag: 0x0003, type: 2, count: 2, value: [longitudeRef, 0]),
            ValueEntry(tag: 0x0004, type: 5, count: 3, value: rationalData(for: coordinate.longitude, little: little))
        ]
        entries.append(contentsOf: preserving.filter { !(0x0000...0x0004).contains($0.tag) })
        return entries
    }

    private static func valueEntry(for entry: RawEntry, in blob: [UInt8], little: Bool) -> ValueEntry? {
        guard let unitSize = typeSize(entry.type) else { return nil }
        guard entry.count > 0, entry.count < 100_000 else { return nil }
        let totalSize = unitSize * Int(entry.count)
        guard totalSize > 0 else { return nil }

        if totalSize <= 4 {
            return ValueEntry(tag: entry.tag, type: entry.type, count: entry.count, value: Array(entry.valueField.prefix(totalSize)))
        }

        guard let offset = try? uint32(entry.valueField, 0, little),
              Int(offset) + totalSize <= blob.count
        else { return nil }
        return ValueEntry(
            tag: entry.tag,
            type: entry.type,
            count: entry.count,
            value: Array(blob[Int(offset)..<(Int(offset) + totalSize)])
        )
    }

    private static func typeSize(_ type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return nil
        }
    }

    // MARK: - 数值编码

    private static func rationalData(for value: Double, little: Bool) -> [UInt8] {
        let absolute = abs(value)
        var degrees = floor(absolute)
        var minutes = floor((absolute - degrees) * 60)
        var seconds = (absolute - degrees - minutes / 60) * 3600

        if seconds >= 60 {
            seconds = 0
            minutes += 1
        }
        if minutes >= 60 {
            minutes = 0
            degrees += 1
        }

        let denominator: UInt32 = 10_000
        let pairs: [(UInt32, UInt32)] = [
            (UInt32(degrees), 1),
            (UInt32(minutes), 1),
            (UInt32((seconds * Double(denominator)).rounded()), denominator)
        ]

        var bytes: [UInt8] = []
        bytes.reserveCapacity(24)
        for pair in pairs {
            bytes += encodedUInt32(pair.0, little)
            bytes += encodedUInt32(pair.1, little)
        }
        return bytes
    }

    private static func writeRationals(_ blob: inout [UInt8], at offset: Int, value: Double, _ little: Bool) {
        let data = rationalData(for: value, little: little)
        guard offset + data.count <= blob.count else { return }
        for index in data.indices {
            blob[offset + index] = data[index]
        }
    }

    private static func byteOrder(of blob: [UInt8]) throws -> Bool {
        guard blob.count >= 4 else { throw EXIFWriteError.malformed("文件头不完整") }
        if blob[0] == 0x49, blob[1] == 0x49 { return true }
        if blob[0] == 0x4D, blob[1] == 0x4D { return false }
        throw EXIFWriteError.malformed("未知字节序")
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int, _ little: Bool) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw EXIFWriteError.malformed("读取越界")
        }
        if little {
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int, _ little: Bool) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw EXIFWriteError.malformed("读取越界")
        }
        if little {
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func putUInt32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int, _ little: Bool) {
        guard offset >= 0, offset + 4 <= bytes.count else { return }
        if little {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
            bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
        } else {
            bytes[offset] = UInt8((value >> 24) & 0xFF)
            bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
            bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 3] = UInt8(value & 0xFF)
        }
    }

    private static func encodedUInt16(_ value: UInt16, _ little: Bool) -> [UInt8] {
        little
            ? [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
            : [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func encodedUInt32(_ value: UInt32, _ little: Bool) -> [UInt8] {
        little
            ? [
                UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 24) & 0xFF)
            ]
            : [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ]
    }
}
