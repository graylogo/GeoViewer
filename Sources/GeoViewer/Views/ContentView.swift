import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if model.photos.isEmpty {
                WelcomeView()
            } else {
                HSplitView {
                    if model.showSidebar {
                        PhotoListView()
                            .frame(minWidth: 230, idealWidth: 290, maxWidth: 420)
                    }

                    MapPane()
                        .frame(minWidth: 420)

                    if model.showInspector {
                        InspectorView()
                            .frame(width: 312)
                    }
                }
            }

            StatusBarView()
        }
        .frame(minWidth: 960, minHeight: 600)
        .navigationTitle("GeoViewer")
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls: urls)
            return true
        } isTargeted: { targeted in
            model.isDropTargeted = targeted
        }
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, dash: [9, 6])
                    )
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            ToastView()
        }
        .task { presentBackupNoticeIfNeeded() }
        .alert("输入经纬度", isPresented: $model.showsCoordinatePrompt) {
            TextField("例如 30.2741, 120.1551", text: $model.coordinateInput)
            Button("应用到所选照片") { model.applyManualInput() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("纬度范围 -90…90，经度范围 -180…180。位置会应用到当前所选的全部照片。")
        }
        .alert("保存失败", isPresented: errorBinding) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model

        ToolbarItemGroup(placement: .navigation) {
            Menu {
                Button("打开照片…") { model.chooseFiles() }
                Button("打开文件夹…") { model.chooseFolder() }
                Divider()
                Button("清空列表") { model.clearList() }
                    .disabled(model.photos.isEmpty)
            } label: {
                Label("打开", systemImage: "folder")
            }
            .help("打开照片或文件夹（⌘O / ⇧⌘O）")

            Button { model.undo() } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .help("撤销位置修改（⌘Z）")

            Button { model.redo() } label: {
                Label("重做", systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .help("重做位置修改（⇧⌘Z）")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.locationMode) {
                Label("定位模式", systemImage: "mappin.and.ellipse")
            }
            .toggleStyle(.button)
            .help("开启后点击地图即可修改所选照片的位置（⌘L）")

            Button {
                withAnimation(.snappy) { model.showSidebar.toggle() }
            } label: {
                Label("照片列表", systemImage: "sidebar.left")
            }
            .help("显示 / 隐藏照片列表")

            Button {
                withAnimation(.snappy) { model.showInspector.toggle() }
            } label: {
                Label("信息面板", systemImage: "sidebar.right")
            }
            .help("显示 / 隐藏信息面板")

            Button { model.saveChanges() } label: {
                Label(model.dirtyCount > 0 ? "保存 \(model.dirtyCount) 项" : "保存", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.hasUnsavedChanges || model.isSaving)
            .help("保存位置修改（⌘S）")
        }
    }

    /// 启动时提示一次原片备份的开关状态；用户选过「暂不开启」后不再重复打扰。
    private func presentBackupNoticeIfNeeded() {
        guard !settings.backupEnabled, !settings.backupNoticeDismissed else { return }
        model.showToast(
            "原片备份当前是关闭的，保存位置会直接改写原文件；点「去开启」打开设置",
            kind: .warning,
            action: .openSettings,
            duration: .seconds(8)
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}
