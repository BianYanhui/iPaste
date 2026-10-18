import AppKit

/// Writes the general pasteboard on behalf of iPaste and records the
/// resulting `changeCount` so the crit does not replay for our own write.
@MainActor
final class PasteboardSelfWrite {
    static let shared = PasteboardSelfWrite()

    /// Highest changeCount produced by this process. `Int.max` while a write
    /// is in progress so a re-entrant poll cannot treat the intermediate
    /// generation as a user copy.
    private(set) var lastSelfWriteChangeCount: Int = -1

    private init() {}

    func replaceGeneralPasteboard(string: String) {
        let pasteboard = NSPasteboard.general
        let marker = NSPasteboard.PasteboardType(CopyEffectGate.selfWriteType)
        lastSelfWriteChangeCount = Int.max
        pasteboard.declareTypes([.string, marker], owner: nil)
        pasteboard.setString(string, forType: .string)
        pasteboard.setString("1", forType: marker)
        lastSelfWriteChangeCount = pasteboard.changeCount
    }
}
