import SwiftUI

struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if model.isLoading {
                ProgressView().controlSize(.mini)
                Text(model.loadingMessage ?? "正在读取…")
            } else if model.isSaving, let progress = model.saveProgress {
                ProgressView().controlSize(.mini)
                Text("正在保存 \(progress.completed)/\(progress.total)…")
            } else {
                Text("共 \(model.photos.count) 张照片")
                Text("·").foregroundStyle(.tertiary)
                Text("已定位 \(model.locatedCount) 张")
                if model.dirtyCount > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(model.dirtyCount) 张待保存")
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Text("仅写入 GPS 元数据 · 不改动照片其它信息")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 8) {
                Image(systemName: toast.kind.systemImage)
                    .foregroundStyle(tint(for: toast.kind))

                Text(toast.message)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                switch toast.action {
                case .none:
                    EmptyView()
                case .undo:
                    Button("撤销") { model.undo() }
                        .buttonStyle(.link)
                        .font(.callout)
                case .openSettings:
                    Button("去开启") { model.openSettings() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.black.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.bottom, 40)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func tint(for kind: ToastMessage.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
