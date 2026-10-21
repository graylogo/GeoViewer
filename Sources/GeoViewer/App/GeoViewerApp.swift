import AppKit
import SwiftUI

@main
enum GeoViewerEntry {
    @MainActor
    static func main() {
        if CommandLineTool.runIfRequested() { return }
        GeoViewerApp.main()
    }
}

struct GeoViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("GeoViewer") {
            ContentView()
                .environment(model)
                .environment(settings)
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            GeoViewerCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 从访达双击 / 拖到 Dock 图标打开文件时进入这里。
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppModel.shared?.open(urls: urls)
        }
    }

    /// 退出前保护未保存的位置修改。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.shared, model.hasUnsavedChanges else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "还有 \(model.dirtyCount) 张照片的位置修改未保存"
        alert.informativeText = "退出应用会丢失这些修改。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "放弃修改并退出")

        let response = alert.runModal()
        return response == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
