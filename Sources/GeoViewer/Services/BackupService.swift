import Foundation

/// 写入前把原文件复制到备份目录，按日期分文件夹，绝不修改原文件。
enum BackupService {
    static func backup(url: URL, to root: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let directory = root.appendingPathComponent(dateFolderName(), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var destination = directory.appendingPathComponent(url.lastPathComponent)
        var index = 1
        while fileManager.fileExists(atPath: destination.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            destination = directory.appendingPathComponent(name)
            index += 1
        }

        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    private static func dateFolderName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}
