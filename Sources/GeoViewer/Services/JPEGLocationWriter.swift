import Foundation

/// JPEG 容器的位置写入：只替换 / 新增 APP1(Exif) 段落，其余字节原样保留。
enum JPEGLocationWriter {
    static func setLocation(_ coordinate: GeoCoordinate?, in data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw EXIFWriteError.unsupportedContainer
        }

        if let segment = findExifSegment(bytes) {
            let payloadStart = segment.start + 4
            let payloadEnd = segment.start + 2 + segment.length
            guard payloadEnd <= bytes.count, payloadEnd - payloadStart >= 6 else {
                throw EXIFWriteError.malformed("APP1 段落长度异常")
            }

            let payload = Array(bytes[payloadStart..<payloadEnd])
            let tiff = Array(payload[6...])
            let updatedTIFF = try TIFFLocationEditor.setLocation(coordinate, in: tiff)
            guard updatedTIFF != tiff else { return data }

            var newPayload = Array("Exif".utf8)
            newPayload += [0, 0]
            newPayload += updatedTIFF
            guard newPayload.count + 2 <= 65_535 else { throw EXIFWriteError.tooLarge }

            var output = Array(bytes[0..<segment.start])
            output += [0xFF, 0xE1]
            output += bigEndianUInt16(UInt16(newPayload.count + 2))
            output += newPayload
            output += bytes[payloadEnd...]
            return Data(output)
        }

        guard let coordinate else { return data }

        var newPayload = Array("Exif".utf8)
        newPayload += [0, 0]
        newPayload += TIFFLocationEditor.makeFreshTIFF(coordinate: coordinate)
        guard newPayload.count + 2 <= 65_535 else { throw EXIFWriteError.tooLarge }

        let insertIndex = insertionPoint(in: bytes)
        var output = Array(bytes[0..<insertIndex])
        output += [0xFF, 0xE1]
        output += bigEndianUInt16(UInt16(newPayload.count + 2))
        output += newPayload
        output += bytes[insertIndex...]
        return Data(output)
    }

    // MARK: - JPEG 段落

    private static func findExifSegment(_ bytes: [UInt8]) -> (start: Int, length: Int)? {
        var index = 2
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]

            if marker == 0xFF {
                index += 1
                continue
            }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                index += 2
                continue
            }
            if marker == 0xDA { return nil }

            guard let length = bigEndianUInt16(bytes, index + 2), length >= 2 else { return nil }
            let segmentEnd = index + 2 + Int(length)
            guard segmentEnd <= bytes.count else { return nil }

            if marker == 0xE1, segmentEnd >= index + 10 {
                let payloadStart = index + 4
                if bytes[payloadStart] == 0x45,
                   bytes[payloadStart + 1] == 0x78,
                   bytes[payloadStart + 2] == 0x69,
                   bytes[payloadStart + 3] == 0x66,
                   bytes[payloadStart + 4] == 0x00,
                   bytes[payloadStart + 5] == 0x00 {
                    return (index, Int(length))
                }
            }

            index = segmentEnd
        }
        return nil
    }

    /// APP1 放在 APP0(JFIF) 之后，符合常见布局。
    private static func insertionPoint(in bytes: [UInt8]) -> Int {
        guard bytes.count >= 6, bytes[2] == 0xFF, bytes[3] == 0xE0,
              let length = bigEndianUInt16(bytes, 4), length >= 2,
              4 + Int(length) <= bytes.count
        else { return 2 }
        return 4 + Int(length)
    }

    private static func bigEndianUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func bigEndianUInt16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
