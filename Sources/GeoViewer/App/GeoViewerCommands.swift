import SwiftUI

struct GeoViewerCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开照片…") { model.chooseFiles() }
                .keyboardShortcut("o", modifiers: .command)
            Button("打开文件夹…") { model.chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("清空照片列表") { model.clearList() }
                .disabled(model.photos.isEmpty)
        }

        CommandGroup(replacing: .saveItem) {
            Button("保存位置修改") { model.saveChanges() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.hasUnsavedChanges || model.isSaving)
            Button("放弃所有未保存修改") { model.discardChanges() }
                .disabled(!model.hasUnsavedChanges)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("撤销位置修改") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
            Button("重做位置修改") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }

        CommandMenu("照片") {
            Toggle("定位模式", isOn: Binding(
                get: { model.locationMode },
                set: { model.locationMode = $0 }
            ))
            .keyboardShortcut("l", modifiers: .command)

            Button("输入经纬度…") { model.beginManualInput() }
                .keyboardShortcut("g", modifiers: .command)

            Divider()

            Button("拷贝坐标") { model.copySelectedCoordinate() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.primaryPhoto?.stagedCoordinate == nil)

            Button("粘贴坐标") { model.pasteCoordinateToSelection() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!model.canPasteCoordinate)

            Button("删除位置") { model.clearLocationForSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty)

            Divider()

            Button("在地图上显示") { model.focusOnPrimary() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model.primaryPhoto?.stagedCoordinate == nil)

            Button("放大到街道") { model.zoomToStreetLevelForPrimary() }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(model.primaryPhoto?.stagedCoordinate == nil)

            Button("显示全部照片") { model.fitAll() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(model.locatedCount == 0)
        }

        CommandGroup(after: .sidebar) {
            Toggle("显示照片列表", isOn: Binding(
                get: { model.showSidebar },
                set: { model.showSidebar = $0 }
            ))
            .keyboardShortcut("1", modifiers: [.command, .option])

            Toggle("显示信息面板", isOn: Binding(
                get: { model.showInspector },
                set: { model.showInspector = $0 }
            ))
            .keyboardShortcut("2", modifiers: [.command, .option])
        }
    }
}
