import CoreGraphics
import Foundation

/// Pure ⌘C chord bookkeeping. The effect is armed on key-down (so we can
/// snapshot `changeCount` before the target app copies) and only *fires*
/// on key-up. Mirrored by `Support/scripts/selftest_update_logic.py`.
struct CopyChordState: Equatable {
    private(set) var baseline: Int?
    private(set) var armedAt: TimeInterval?

    /// Drop a chord if C is released long after it was pressed.
    static let armTimeout: TimeInterval = 1.2

    /// kVK_ANSI_C. Plain Command-C, excluding Shift / Control / Option.
    static let keyCodeC: Int64 = 8

    static func isPlainCommandC(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        guard keyCode == keyCodeC, !isRepeat else { return false }
        guard flags.contains(.maskCommand) else { return false }
        if flags.contains(.maskShift) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return false
        }
        return true
    }

    mutating func noteKeyDown(isPlainCommandC: Bool, isRepeat: Bool, changeCount: Int, now: TimeInterval) {
        guard isPlainCommandC, !isRepeat else { return }
        baseline = changeCount
        armedAt = now
    }

    /// Returns the pre-copy changeCount when this key-up completes a chord.
    mutating func noteKeyUp(isC: Bool, now: TimeInterval) -> Int? {
        guard isC, let baseline, let armedAt else { return nil }
        self.baseline = nil
        self.armedAt = nil
        if now - armedAt > Self.armTimeout { return nil }
        return baseline
    }
}
