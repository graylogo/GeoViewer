import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("查看和修改照片的拍摄位置")
                    .font(.title2.weight(.semibold))
                Text("拖入照片或文件夹，或使用下方按钮打开。\n只写入 GPS 位置信息，不重新压缩照片，也不改动其它元数据。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button {
                    model.chooseFiles()
                } label: {
                    Label("打开照片", systemImage: "photo")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.chooseFolder()
                } label: {
                    Label("打开文件夹", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.loadingMessage ?? "正在读取…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("支持 JPEG、HEIC / HEIF、TIFF；RAW 与 PNG 可查看但暂不支持写入位置")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
