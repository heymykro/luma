import AppKit
import CoreGraphics
import Foundation

/// Keyboard brightness-key interception via an active CGEventTap.
///
/// Brightness keys arrive by two routes, and we intercept both:
/// - plain keyDown keycodes: 144/145 (HID consumer usages on most third-party
///   keyboards) and opt-in 107/113 (legacy F14/F15);
/// - NX_SYSDEFINED (type 14, subtype 8) media-key events with
///   NX_KEYTYPE_BRIGHTNESS_UP(2)/DOWN(3): Apple keyboards, and some
///   third-party boards on macOS 26 (e.g. rotary-encoder knobs).
/// Consuming the NX route means built-in keyboard brightness keys follow
/// Luma's routing modes too. Requires the Accessibility permission.
final class KeyTap {
    private static let step: Float = 1.0 / 16.0
    private static let vkF14: Int64 = 107
    private static let vkF15: Int64 = 113
    // Verified live: 144 dims up, 145 dims down.
    private static let vkBrightnessUp: Int64 = 144
    private static let vkBrightnessDown: Int64 = 145

    private static let nxSysdefined: UInt32 = 14
    private static let nxSubtypeMediaKey: Int = 8
    private static let nxKeyBrightnessUp = 2
    private static let nxKeyBrightnessDown = 3
    private static let nxKeyDownState = 0x0A

    // Brightness change per scroll pixel. If your wheel feels inverted, the
    // sign convention of pointDeltaAxis1 differs on your device — flip here.
    private static let scrollGain: Float = 0.002

    private let store: Store
    private let controller: BrightnessController
    private let hud: HUDController
    // Two taps: an ACTIVE tap for the keys we consume, and a LISTEN-ONLY tap
    // for scroll so the WindowServer never blocks on Luma for system scrolls.
    private var keyPort: CFMachPort?
    private var scrollPort: CFMachPort?
    private var keySource: CFRunLoopSource?
    private var scrollSource: CFRunLoopSource?
    private var axWasTrusted = true
    /// Called on the main queue when Accessibility trust flips.
    var onAXChanged: ((Bool) -> Void)?

    // Steps accumulate here and drain on a serial queue, so bursts (fast
    // scrolls arrive per-pixel) coalesce into one net adjustment per pass.
    private let pendingDelta = Locked<(delta: Float, invert: Bool)>((0, false))
    private let adjustQueue = DispatchQueue(label: "luma.key-steps")

    init(store: Store, controller: BrightnessController, hud: HUDController) {
        self.store = store
        self.controller = controller
        self.hud = hud
    }

    /// Wait for Accessibility trust (prompting once), then run the tap forever.
    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "key-tap"
        thread.qualityOfService = .userInteractive // a delayed callback risks the OS killing the tap
        thread.start()
    }

    private func run() {
        // Prompt once (main thread — its presentation is run-loop work), then
        // poll until trust lands AND the tap actually creates. A freshly
        // granted trust can take a beat before tapCreate is allowed to succeed,
        // so we retry instead of dying — that beat used to leave keys dead
        // until a manual relaunch.
        if !Accessibility.trusted {
            DispatchQueue.main.async { _ = Accessibility.prompt() }
        }
        while !Accessibility.trusted { Thread.sleep(forTimeInterval: 1) }
        axWasTrusted = true
        DispatchQueue.main.async { self.onAXChanged?(true) }
        while !createTaps() { Thread.sleep(forTimeInterval: 1) }
        Log.note("brightness key tap active")

        // Watchdog: re-enable taps the OS silently disabled, and — critically —
        // fully recreate them when trust flips back on (re-enabling a port the
        // OS invalidated on revoke does not resume delivery).
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = Accessibility.trusted
            if trusted != self.axWasTrusted {
                self.axWasTrusted = trusted
                DispatchQueue.main.async { self.onAXChanged?(trusted) }
                if trusted {
                    Log.note("AX re-granted — recreating taps")
                    _ = self.createTaps()
                }
            }
            for port in [self.keyPort, self.scrollPort] {
                if let port, !CGEvent.tapIsEnabled(tap: port) {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        CFRunLoopRun()
    }

    /// (Re)create both taps on the current run loop. Returns false only if the
    /// active key tap couldn't be made (trust not yet propagated).
    private func createTaps() -> Bool {
        teardownTaps()
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue().handle(type: type, event: event)
        }
        let rl = CFRunLoopGetCurrent()

        let keyMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventMask(Self.nxSysdefined))
        guard let kp = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: keyMask, callback: cb, userInfo: refcon
        ) else { return false }
        keyPort = kp
        keySource = CFMachPortCreateRunLoopSource(nil, kp, 0)
        CFRunLoopAddSource(rl, keySource, .commonModes)

        let scrollMask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        if let sp = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: scrollMask, callback: cb, userInfo: refcon
        ) {
            scrollPort = sp
            scrollSource = CFMachPortCreateRunLoopSource(nil, sp, 0)
            CFRunLoopAddSource(rl, scrollSource, .commonModes)
        }
        return true
    }

    private func teardownTaps() {
        let rl = CFRunLoopGetCurrent()
        for src in [keySource, scrollSource] where src != nil {
            CFRunLoopRemoveSource(rl, src, .commonModes)
        }
        for port in [keyPort, scrollPort] where port != nil {
            CGEvent.tapEnable(tap: port!, enable: false)
        }
        keyPort = nil; scrollPort = nil; keySource = nil; scrollSource = nil
    }

    // MARK: - Tap callback (runs on the tap thread, every matched event)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            for port in [keyPort, scrollPort] where port != nil {
                CGEvent.tapEnable(tap: port!, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if store.paused.get() {
            return Unmanaged.passUnretained(event) // paused: pass through untouched
        }

        if type == .keyDown {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let legacy = store.legacyFKeys.get()
            let direction: Bool?
            switch keycode {
            case Self.vkBrightnessUp: direction = true
            case Self.vkBrightnessDown: direction = false
            case Self.vkF15 where legacy: direction = true
            case Self.vkF14 where legacy: direction = false
            default: direction = nil
            }
            if let up = direction {
                return step(up: up, event: event, quarter: quarterStep(event))
            }
        }

        // NX_SYSDEFINED media keys (Apple keyboards, rotary knobs, ...).
        if type.rawValue == Self.nxSysdefined {
            if let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == Self.nxSubtypeMediaKey {
                let data1 = ns.data1
                let key = (data1 >> 16) & 0xFFFF
                if key == Self.nxKeyBrightnessUp || key == Self.nxKeyBrightnessDown {
                    // Step on key-down; consume the key-up too so macOS never
                    // sees an unmatched half of the press.
                    guard (data1 >> 8) & 0xFF == Self.nxKeyDownState else { return nil }
                    return step(up: key == Self.nxKeyBrightnessUp, event: event, quarter: quarterStep(event))
                }
            }
        }

        // Scrolling over the tray icon adjusts brightness. Passed through
        // (the menu bar doesn't scroll anyway); overTray is set by a tracking
        // area on the status button — but exits aren't reliably delivered
        // (menu tracking swallows them), so verify the pointer really is in a
        // menu-bar strip and self-heal if not.
        if type == .scrollWheel, store.overTray.get() {
            if !DisplayManager.pointInMenuBar(event.location) {
                store.overTray.set(false)
                return Unmanaged.passUnretained(event)
            }
            let delta = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            if delta != 0 {
                enqueue(delta: Float(delta) * Self.scrollGain, invert: flipHeld(event))
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func flipHeld(_ event: CGEvent) -> Bool {
        event.flags.rawValue & store.flipMask.get() != 0
    }

    /// macOS convention: Option+Shift moves brightness in 1/4 steps (finer).
    private func quarterStep(_ event: CGEvent) -> Bool {
        let flags = event.flags.rawValue
        return flags & CGEventFlags.maskAlternate.rawValue != 0
            && flags & CGEventFlags.maskShift.rawValue != 0
    }

    /// Route a brightness step — or pass the key through when there's nothing
    /// to adjust (excluded/uncontrollable target), so macOS still handles the
    /// built-in natively instead of the key feeling dead.
    private func step(up: Bool, event: CGEvent, quarter: Bool) -> Unmanaged<CGEvent>? {
        let invert = flipHeld(event)
        guard controller.hasAdjustableTarget(invertRouting: invert) else {
            return Unmanaged.passUnretained(event)
        }
        let magnitude = quarter ? Self.step / 4 : Self.step
        enqueue(delta: up ? magnitude : -magnitude, invert: invert)
        return nil
    }

    private func enqueue(delta: Float, invert: Bool) {
        let wasIdle = pendingDelta.withLock { pending -> Bool in
            let idle = pending.delta == 0
            pending.delta += delta
            pending.invert = invert
            return idle
        }
        guard wasIdle else { return } // a drain pass is already scheduled
        adjustQueue.async { [weak self] in
            guard let self else { return }
            let (delta, invert) = self.pendingDelta.withLock { pending -> (Float, Bool) in
                defer { pending = (0, false) }
                return pending
            }
            guard delta != 0 else { return }
            if let value = self.controller.adjust(delta: delta, invertRouting: invert) {
                DispatchQueue.main.async { self.hud.show(value: value) }
            }
        }
    }
}
