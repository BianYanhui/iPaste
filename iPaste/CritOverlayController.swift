import AppKit
import SwiftUI

/// Hosting view that stays transparent. The default `NSHostingView` is opaque
/// and would paint a white rectangle over the copied text.
final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

/// Shows the crit at a Cocoa screen point and orders it out when the
/// animation finishes. This controller never activates the app.
@MainActor
final class CritOverlayController {
    static let shared = CritOverlayController()

    private var panel: CritPanel?
    private var hosting: ClearHostingView<CritFlashView>?
    private var hideWork: DispatchWorkItem?

    private init() {}

    func present(at mouse: NSPoint) {
        let screens = NSScreen.screens.map {
            DisplayScreen(
                frame: $0.frame,
                visibleFrame: $0.visibleFrame,
                backingScaleFactor: $0.backingScaleFactor
            )
        }
        let screen = ScreenGeometry.screen(containing: mouse, screens: screens)
            ?? screens.first
            ?? DisplayScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             backingScaleFactor: 2)
        let frame = ScreenGeometry.panelFrame(mouse: mouse, screen: screen)
        let panel = ensurePanel()
        panel.setFrame(frame, display: false)
        // Use the scale of the display that contains the pointer. Reading
        // `panel.screen` before the panel is ordered can still report the
        // main display and would snap or stroke for the wrong monitor.
        let scale = max(screen.backingScaleFactor, 1)
        panel.contentView?.layer?.contentsScale = scale

        let view = CritFlashView(token: UUID(), contentsScale: scale)
        if let hosting {
            hosting.rootView = view
            hosting.frame = NSRect(origin: .zero, size: frame.size)
        } else {
            let host = ClearHostingView(rootView: view)
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.frame = NSRect(origin: .zero, size: frame.size)
            host.wantsLayer = true
            host.layer?.contentsScale = scale
            host.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = host
            hosting = host
        }
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> CritPanel {
        if let panel { return panel }
        let panel = CritPanel(contentRect: NSRect(origin: .zero, size: ScreenGeometry.effectSize))
        self.panel = panel
        return panel
    }
}
