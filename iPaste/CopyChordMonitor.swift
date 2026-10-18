import AppKit
import os

/// Listens for plain ⌘C and, on key-up, confirms the general pasteboard
/// `changeCount` actually moved.
///
/// The tap is listen-only on the session event stream and is attached to the
/// main run loop, so the callback runs before the target app handles the key.
/// That is Input Monitoring (`CGPreflightListenEventAccess`), not Accessibility.
/// `NSEvent` global key monitors are intentionally unused: on current macOS
/// they require Accessibility, which this MVP does not request.
@MainActor
final class CopyChordMonitor {
    static let shared = CopyChordMonitor()

    enum ListenStatus: Equatable {
        case needsPermission
        case needsRelaunch
        case listening
    }

    private(set) var status: ListenStatus = .needsPermission
    var onStatusChange: (@MainActor () -> Void)?

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var becomeActiveObserver: NSObjectProtocol?
    private var chord = CopyChordState()
    private var pollTimer: Timer?
    private var pollDeadline: Date?
    private var pollBaseline: Int = 0
    private var pollMouse: NSPoint = .zero
    private let confirmWindow: TimeInterval = 0.60
    private let log = Logger(subsystem: "io.github.bianyanhui.iPaste", category: "copy")

    private init() {}

    func start() {
        // Prime the pasteboard on the main thread before the tap runs.
        _ = NSPasteboard.general.changeCount
        installTapIfPossible()
        guard becomeActiveObserver == nil else { return }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applicationDidBecomeActive()
            }
        }
    }

    func stop() {
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
            self.becomeActiveObserver = nil
        }
        invalidatePoll()
        removeTap()
    }

    var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Shows the system Input Monitoring prompt. Call only after the user
    /// has read why we need it. Granting it often requires a relaunch.
    func requestInputMonitoringPrompt() {
        _ = CGRequestListenEventAccess()
        installTapIfPossible()
    }

    /// Try again after the user grants Input Monitoring without a full relaunch.
    func retryIfNeeded() {
        if eventTap == nil {
            installTapIfPossible()
        }
    }

    private func applicationDidBecomeActive() {
        retryIfNeeded()
    }

    // MARK: - Tap

    private func installTapIfPossible() {
        guard inputMonitoringGranted else {
            updateStatus(.needsPermission)
            return
        }
        if eventTap != nil {
            updateStatus(.listening)
            return
        }

        let mask = (CGEventMask(1) << Int(CGEventType.keyDown.rawValue))
            | (CGEventMask(1) << Int(CGEventType.keyUp.rawValue))
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: ipasteCopyChordCallback,
            userInfo: userInfo
        ) else {
            log.error("listen-only event tap failed after Input Monitoring preflight")
            updateStatus(.needsRelaunch)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        updateStatus(.listening)
        log.info("⌘C listen-only tap installed")
    }

    private func removeTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
    }

    fileprivate func reenableTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    /// Invoked on the main run loop, ahead of delivery to the front app.
    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableTap()
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let now = ProcessInfo.processInfo.systemUptime

        if type == .keyDown {
            let plain = CopyChordState.isPlainCommandC(
                keyCode: keyCode,
                flags: event.flags,
                isRepeat: isRepeat
            )
            if plain {
                // Snapshot before the target app's keyDown handler copies.
                invalidatePoll()
                let count = NSPasteboard.general.changeCount
                chord.noteKeyDown(
                    isPlainCommandC: true,
                    isRepeat: false,
                    changeCount: count,
                    now: now
                )
            }
            return
        }

        if type == .keyUp {
            guard keyCode == CopyChordState.keyCodeC else { return }
            guard let baseline = chord.noteKeyUp(isC: true, now: now) else { return }
            let mouse = NSEvent.mouseLocation
            // Defer past this callback so the front app can finish the copy,
            // and so the tap callback itself stays short.
            Task { @MainActor in
                self.scheduleConfirm(baseline: baseline, mouse: mouse)
            }
        }
    }

    // MARK: - Pasteboard confirm

    private func scheduleConfirm(baseline: Int, mouse: NSPoint) {
        invalidatePoll()
        pollBaseline = baseline
        pollMouse = mouse
        pollDeadline = Date().addingTimeInterval(confirmWindow)
        log.debug("⌘C key-up, waiting for changeCount > \(baseline, privacy: .public)")
        if consumePasteboardIfReady() { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                _ = self?.consumePasteboardIfReady()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Returns true when this confirm attempt is finished (shown or timed out).
    @discardableResult
    private func consumePasteboardIfReady() -> Bool {
        guard pollDeadline != nil else { return true }
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let show = CopyEffectGate.shouldShow(
            changeCount: pasteboard.changeCount,
            baselineChangeCount: pollBaseline,
            types: types,
            lastSelfWriteChangeCount: PasteboardSelfWrite.shared.lastSelfWriteChangeCount
        )
        if show {
            let mouse = pollMouse
            invalidatePoll()
            log.debug("clipboard changed, showing crit")
            CritOverlayController.shared.present(at: mouse)
            return true
        }
        if let pollDeadline, Date() >= pollDeadline {
            invalidatePoll()
            log.debug("no clipboard change after ⌘C")
            return true
        }
        return false
    }

    private func invalidatePoll() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollDeadline = nil
    }

    private func updateStatus(_ newStatus: ListenStatus) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChange?()
    }
}

private func ipasteCopyChordCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    _ = proxy
    if let userInfo {
        let monitor = Unmanaged<CopyChordMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        // The tap source is scheduled on the main run loop.
        MainActor.assumeIsolated {
            monitor.handle(type: type, event: event)
        }
    }
    return Unmanaged.passUnretained(event)
}
