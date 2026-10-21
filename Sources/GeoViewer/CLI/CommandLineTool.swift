import Foundation

/// 隐藏的命令行入口，便于批量处理与调试（GUI 启动时不触发）。
enum CommandLineTool {
    /// LaunchServices 可能注入 `-psn_...` 等参数，只有明确的子命令才进入命令行模式。
    private static let knownCommands: Set<String> = [
        "--help", "-h", "--version", "--dump", "--json", "--set-location", "--clear-location"
    ]

    static func runIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first, knownCommands.contains(command) else { return false }

        let rest = Array(arguments.dropFirst())

        switch command {
        case "--help", "-h":
            printUsage()
        case "--version":
            print(version)
        case "--dump":
            dump(files: rest)
        case "--json":
            dumpJSON(files: rest)
        case "--set-location":
            setLocation(arguments: rest)
        case "--clear-location":
            clearLocation(files: rest)
        default:
            print("未知参数：\(command)\n")
            printUsage()
            exit(1)
        }
        return true
    }

    // MARK: - 命令

    private static func dump(files: [String]) {
        guard !files.isEmpty else { fail("请提供照片文件路径") }

        for path in files {
            let url = URL(fileURLWithPath: path)
            guard let details = MetadataReader.read(url: url) else {
                writeError("无法读取：\(path)")
                continue
            }

            print("文件: \(path)")
            print("格式: \(details.formatDescription) · \(Format.dimensions(width: details.width, height: details.height)) · \(Format.fileSize(details.fileSize))")
            print("拍摄: \(Format.camera(make: details.make, model: details.model)) · \(Format.text(details.lensModel))")
            print("参数: \(Format.focalLength(details.focalLength, equivalent: details.focalLength35mm)) · \(Format.aperture(details.aperture)) · \(Format.shutter(details.exposureTime)) · \(Format.iso(details.iso))")
            print("时间: \(Format.dateTime(details.captureDate))")
            if let gps = details.gps {
                print("位置: \(gps.coordinate.formatted) · 海拔 \(Format.altitude(gps))")
            } else {
                print("位置: 未记录")
            }
            print("写入: \(details.isWritable ? "支持" : "只读")")
            print("")
        }
    }

    private static func dumpJSON(files: [String]) {
        guard !files.isEmpty else { fail("请提供照片文件路径") }

        struct Entry: Encodable {
            let path: String
            let details: PhotoDetails
        }

        var entries: [Entry] = []
        for path in files {
            let url = URL(fileURLWithPath: path)
            guard let details = MetadataReader.read(url: url) else {
                writeError("无法读取：\(path)")
                continue
            }
            entries.append(Entry(path: url.path, details: details))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(entries), let text = String(data: data, encoding: .utf8) else {
            fail("生成 JSON 失败")
        }
        print(text)
    }

    private static func setLocation(arguments: [String]) {
        guard arguments.count >= 2 else {
            fail("用法：GeoViewer --set-location 纬度,经度 文件…")
        }
        guard let coordinate = GeoCoordinate.parse(arguments[0]) else {
            fail("坐标格式不正确：\(arguments[0])（示例 30.2741,120.1551）")
        }

        var failures = 0
        for path in arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            do {
                try MetadataWriter.setLocation(coordinate, for: url)
                print("已写入 \(path) → \(coordinate.formatted)")
            } catch {
                failures += 1
                writeError("失败 \(path)：\(error.localizedDescription)")
            }
        }

        if failures > 0 { exit(1) }
    }

    private static func clearLocation(files: [String]) {
        guard !files.isEmpty else { fail("请提供照片文件路径") }

        var failures = 0
        for path in files {
            let url = URL(fileURLWithPath: path)
            do {
                try MetadataWriter.setLocation(nil, for: url)
                print("已清除位置 \(path)")
            } catch {
                failures += 1
                writeError("失败 \(path)：\(error.localizedDescription)")
            }
        }

        if failures > 0 { exit(1) }
    }

    // MARK: - 辅助

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private static func printUsage() {
        print("""
        GeoViewer — 查看和修改照片的 GPS 位置

        图形界面：
          GeoViewer

        命令行：
          GeoViewer --dump 文件…                       查看照片元数据
          GeoViewer --json 文件…                       以 JSON 输出元数据
          GeoViewer --set-location 纬度,经度 文件…     写入 GPS 位置（只改 GPS）
          GeoViewer --clear-location 文件…             清除 GPS 位置
          GeoViewer --version                          显示版本
        """)
    }

    private static func fail(_ message: String) -> Never {
        writeError(message)
        exit(2)
    }

    private static func writeError(_ message: String) {
        if let data = "\(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
