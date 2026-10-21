import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("保存") {
                Toggle("修改位置后立即写入文件", isOn: $settings.autoSaveAfterEdit)
                Text("关闭时，位置修改会先暂存在列表中，按 ⌘S 统一保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("写入前备份原文件", isOn: $settings.backupEnabled)

                HStack(spacing: 8) {
                    Text(settings.backupFolderPath.isEmpty ? "未选择备份文件夹" : settings.backupFolderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(settings.backupFolderPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("选择…") { chooseBackupFolder() }
                }

                Text("备份按日期复制到所选目录，原文件不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("地图") {
                Picker("地图样式", selection: $settings.mapStyle) {
                    ForEach(MapStyleKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    Text("照片缩略图大小")
                    Slider(value: $settings.pinSize, in: 36...72, step: 2)
                    Text("\(Int(settings.pinSize))")
                        .monospacedDigit()
                        .frame(width: 24, alignment: .trailing)
                }
            }

            Section("关于") {
                LabeledContent("版本", value: version)
                LabeledContent("JPEG / TIFF", value: "字节级 EXIF 编辑（只改 GPS 指针与数值）")
                LabeledContent("HEIC / HEIF", value: "ImageIO 元数据复制（不重编码图像）")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择备份文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            settings.backupFolderPath = url.path
        }
    }
}
