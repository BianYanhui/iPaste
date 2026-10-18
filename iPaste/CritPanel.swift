import AppKit

/// Borderless overlay that cannot become key or main and cannot activate iPaste.
final class CritPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func makeKey() {
        // Never take keyboard focus from the app the user copied in.
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderFrontRegardless()
    }
}
