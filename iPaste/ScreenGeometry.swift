import CoreGraphics
import Foundation

/// Screen-space layout for the crit panel.
///
/// `NSEvent.mouseLocation` and `NSWindow` frames share Cocoa's global
/// coordinate space: origin at the bottom-left of the primary display,
/// y increasing upward, units in points. This type never converts to
/// window-local coordinates or to CGEvent's top-left space.
///
/// Retina: the origin is snapped to the *target* display's
/// `backingScaleFactor`, not the main display's scale.
struct DisplayScreen: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var backingScaleFactor: CGFloat
}

enum ScreenGeometry {
    static let effectSize = CGSize(width: 320, height: 240)
    /// Lifts the visual center above the pointer so the burst sits on the copy.
    static let lift: CGFloat = 48

    static func screen(containing mouse: CGPoint, screens: [DisplayScreen]) -> DisplayScreen? {
        if let hit = screens.first(where: { $0.frame.contains(mouse) }) {
            return hit
        }
        return screens.min { lhs, rhs in
            distanceSquared(mouse, lhs.frame) < distanceSquared(mouse, rhs.frame)
        }
    }

    static func panelFrame(mouse: CGPoint, screen: DisplayScreen) -> CGRect {
        panelFrame(mouse: mouse, size: effectSize, screen: screen, lift: lift)
    }

    static func panelFrame(mouse: CGPoint, size: CGSize, screen: DisplayScreen, lift: CGFloat) -> CGRect {
        let scale = max(screen.backingScaleFactor, 1)
        var x = mouse.x - size.width / 2
        var y = mouse.y + lift - size.height / 2
        let bounds = (screen.visibleFrame.width > 0 && screen.visibleFrame.height > 0)
            ? screen.visibleFrame
            : screen.frame
        let maxX = bounds.maxX - size.width
        let maxY = bounds.maxY - size.height
        if maxX >= bounds.minX {
            x = min(max(x, bounds.minX), maxX)
        } else {
            x = bounds.minX
        }
        if maxY >= bounds.minY {
            y = min(max(y, bounds.minY), maxY)
        } else {
            y = bounds.minY
        }
        return CGRect(x: snap(x, scale: scale), y: snap(y, scale: scale), width: size.width, height: size.height)
    }

    /// Half-away-from-zero so a point lands on a physical pixel.
    static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scaled = value * scale
        let rounded = scaled.rounded(.toNearestOrAwayFromZero)
        return rounded / scale
    }

    private static func distanceSquared(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }
        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }
        return dx * dx + dy * dy
    }
}
