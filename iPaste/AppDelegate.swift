import AppKit

extension Notification.Name {
    static let iPasteWillQuitForUpdate = Notification.Name("iPaste.willQuitForUpdate")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var versionItem: NSMenuItem?
    private var monitorStatusItem: NSMenuItem?
    private var enableListenItem: NSMenuItem?
    private var autoUpdateItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        CopyChordMonitor.shared.onStatusChange = { [weak self] in
            self?.refreshMonitorMenu()
        }
        CopyChordMonitor.shared.start()
        refreshMonitorMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillQuitForUpdate),
            name: .iPasteWillQuitForUpdate,
            object: nil
        )
        AppUpdater.shared.checkOnLaunchIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CopyChordMonitor.shared.stop()
        CritOverlayController.shared.hide()
    }

    @objc private func handleWillQuitForUpdate() {
        CopyChordMonitor.shared.stop()
        CritOverlayController.shared.hide()
    }

    func menuWillOpen(_ menu: NSMenu) {
        CopyChordMonitor.shared.retryIfNeeded()
        refreshMonitorMenu()
        autoUpdateItem?.state = AppUpdater.shared.autoCheckEnabled ? .on : .off
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = statusImage()
            image.isTemplate = true
            button.image = image
            button.toolTip = "iPaste \(versionLabel()) — 复制成功时在光标旁闪一下暴击"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let version = NSMenuItem(title: "iPaste \(versionLabel())", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        versionItem = version

        let monitor = NSMenuItem(title: "正在检查 ⌘C 监听…", action: nil, keyEquivalent: "")
        monitor.isEnabled = false
        menu.addItem(monitor)
        monitorStatusItem = monitor

        let enable = NSMenuItem(title: "启用 ⌘C 监听…", action: #selector(explainAndRequestListen), keyEquivalent: "")
        enable.target = self
        menu.addItem(enable)
        enableListenItem = enable

        let settings = NSMenuItem(title: "打开「输入监视」设置…", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let preview = NSMenuItem(title: "预览暴击效果", action: #selector(previewCrit), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)

        let selfWrite = NSMenuItem(
            title: "写入剪贴板（不触发暴击）",
            action: #selector(writePasteboardWithoutCrit),
            keyEquivalent: ""
        )
        selfWrite.target = self
        menu.addItem(selfWrite)

        menu.addItem(.separator())

        let update = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        let auto = NSMenuItem(title: "自动检查更新", action: #selector(toggleAutoCheck), keyEquivalent: "")
        auto.target = self
        auto.state = AppUpdater.shared.autoCheckEnabled ? .on : .off
        menu.addItem(auto)
        autoUpdateItem = auto

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 iPaste", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func versionLabel() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func refreshMonitorMenu() {
        let monitor = CopyChordMonitor.shared
        switch monitor.status {
        case .listening:
            monitorStatusItem?.title = "⌘C 监听已开启"
            enableListenItem?.isHidden = true
        case .needsRelaunch:
            monitorStatusItem?.title = "已授权输入监视，请退出并重新打开 iPaste"
            enableListenItem?.isHidden = false
            enableListenItem?.title = "重新尝试监听"
        case .needsPermission:
            monitorStatusItem?.title = "需要「输入监视」才能看到 ⌘C"
            enableListenItem?.isHidden = false
            enableListenItem?.title = "启用 ⌘C 监听…"
        }
    }

    private func statusImage() -> NSImage {
        if let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "iPaste") {
            return image
        }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.labelColor.setFill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 10, y: 17))
        path.line(to: NSPoint(x: 4, y: 9))
        path.line(to: NSPoint(x: 9, y: 9))
        path.line(to: NSPoint(x: 7, y: 1))
        path.line(to: NSPoint(x: 14, y: 9))
        path.line(to: NSPoint(x: 9, y: 9))
        path.close()
        path.fill()
        image.unlockFocus()
        return image
    }

    // MARK: - Actions

    @objc private func explainAndRequestListen() {
        let alert = NSAlert()
        alert.messageText = "需要「输入监视」权限"
        alert.informativeText = """
        iPaste 要在其它应用里知道你松开了 ⌘C，才能在复制成功时闪一下暴击。

        用的是系统「输入监视」，不是「辅助功能」。iPaste 只判断这一下是不是 ⌘C，不记录其它按键，也不读取你选中的文字。

        点「继续」后，请在系统设置里打开 iPaste 的开关。第一次允许后通常要退出并重新打开 iPaste 才会生效。
        """
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        CopyChordMonitor.shared.requestInputMonitoringPrompt()
        openListenEventSettings()
        refreshMonitorMenu()
    }

    @objc private func openInputMonitoringSettings() {
        openListenEventSettings()
    }

    private func openListenEventSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        ]
        for raw in candidates {
            guard let url = URL(string: raw) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func previewCrit() {
        CritOverlayController.shared.present(at: NSEvent.mouseLocation)
    }

    @objc private func writePasteboardWithoutCrit() {
        PasteboardSelfWrite.shared.replaceGeneralPasteboard(string: "iPaste 自写测试（不应触发暴击）")
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdatesFromMenu()
    }

    @objc private func toggleAutoCheck() {
        AppUpdater.shared.autoCheckEnabled.toggle()
        autoUpdateItem?.state = AppUpdater.shared.autoCheckEnabled ? .on : .off
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
