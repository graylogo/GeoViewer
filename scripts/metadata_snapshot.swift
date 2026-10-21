#!/usr/bin/env swift
//
// 导出照片的全部 ImageIO 元数据以及解码后的像素哈希。
// 用于验证「只改 GPS，其它信息不变」。
//
// 用法：
//   swift scripts/metadata_snapshot.swift a.jpg b.jpg > snapshot.txt
//   diff <(swift scripts/metadata_snapshot.swift 原图.jpg) \
//        <(swift scripts/metadata_snapshot.swift 修改后.jpg)
//
// 预期差异：只有 {GPS} 段落变化，PIXELHASH 行完全一致。

import CoreGraphics
import Foundation
import ImageIO

func render(_ value: Any, indent: Int = 0) -> String {
    let pad = String(repeating: "  ", count: indent)
    if let dictionary = value as? [CFString: Any] {
        let keys = dictionary.keys.map { $0 as String }.sorted()
        var lines: [String] = ["{"]
        for key in keys {
            lines.append("\(pad)  \(key): \(render(dictionary[key as CFString]!, indent: indent + 1))")
        }
        lines.append("\(pad)}")
        return lines.joined(separator: "\n")
    }
    if let array = value as? [Any] {
        return "[" + array.map { render($0, indent: indent) }.joined(separator: ", ") + "]"
    }
    if let data = value as? Data {
        return "<data \(data.count) bytes>"
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    return String(describing: value)
}

for path in CommandLine.arguments.dropFirst() {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        continue
    }

    print("=== \(path)")
    for key in properties.keys.map({ $0 as String }).sorted() {
        print("\(key): \(render(properties[key as CFString]!, indent: 0))")
    }

    if let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
       let providerData = image.dataProvider?.data {
        let bytes = Data(providerData as Data)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        print("PIXELHASH: \(String(hash, radix: 16)) (\(bytes.count) bytes)")
    }
}
