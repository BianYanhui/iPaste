import Foundation

/// Decides whether a pasteboard generation observed after ⌘C should show
/// the crit. Own writes are ignored via a marker type and the changeCount
/// recorded while this process was writing. Mirrored by the Python selftest.
enum CopyEffectGate {
    static let selfWriteType = "io.github.bianyanhui.iPaste.selfWrite"

    static func shouldShow(
        changeCount: Int,
        baselineChangeCount: Int,
        types: [String],
        lastSelfWriteChangeCount: Int
    ) -> Bool {
        guard changeCount > baselineChangeCount else { return false }
        if changeCount <= lastSelfWriteChangeCount { return false }
        if types.contains(selfWriteType) { return false }
        return true
    }
}
