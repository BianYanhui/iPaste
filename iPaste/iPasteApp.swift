import SwiftUI

@main
struct iPasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar agent. The status item lives in AppDelegate; this scene
        // only exists so SwiftUI has a Scene, and so ⌘, is not a blank window.
        Settings {
            SettingsHelpView()
        }
    }
}

private struct SettingsHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iPaste")
                .font(.title2.bold())
            Text("在其它应用里用 ⌘C 复制成功后，光标旁会闪一下暴击。开关在菜单栏的闪电图标里。")
            Text("监听 ⌘C 需要系统「输入监视」。这一版不申请「辅助功能」。")
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
    }
}
