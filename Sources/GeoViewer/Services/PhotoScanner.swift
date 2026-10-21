import Foundation

/// 把文件 / 文件夹展开成可读取的图片列表。
enum PhotoScanner {
    static func collectImageURLs(from urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var results: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard !seen.contains(standardized.path) else { return }
            seen.insert(standardized.path)
            results.append(standardized)
        }

        for url in urls {
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                guard let enumerator = fileManager.enumerator(
                    at: standardized,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let fileURL as URL in enumerator where PhotoFormats.isReadable(fileURL) {
                    append(fileURL)
                }
            } else if PhotoFormats.isReadable(standardized) {
                append(standardized)
            }
        }

        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
