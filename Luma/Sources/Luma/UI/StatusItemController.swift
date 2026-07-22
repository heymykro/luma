import AppKit

/// The menu bar presence: left-click toggles the popover, right-click shows
/// the quick-actions menu, and a tracking area arms scroll-to-adjust while
/// the pointer is over the icon.
final class StatusItemController: NSObject {
    private let store: Store
    private let controller: BrightnessController
    private let popover: PopoverPanel
    private let model: AppModel
    private var statusItem: NSStatusItem!
    /// Strong hold on the menu's action target: NSMenu.delegate and
    /// NSMenuItem.target are both weak, so nothing else keeps it alive while
    /// the menu is open.
    private var menuActions: AnyObject?

    init(store: Store, controller: BrightnessController, popover: PopoverPanel, model: AppModel) {
        self.store = store
        self.controller = controller
        self.popover = popover
        self.model = model
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // Scroll-to-adjust arming; the event tap does the actual work.
            let tracking = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            button.addTrackingArea(tracking)
        }
        // While the popover is open, re-read live brightness (Apple displays
        // can drift from keys/Control Center/auto-brightness) and mirror the
        // store into the UI — but only republish the SwiftUI graph and redraw
        // the icon when a value actually moved (diff-gated, ~free when idle).
        popover.onTick = { [weak self] in
            guard let self else { return }
            self.controller.refreshAppleLevels()
            let sig = self.store.displays.get().reduce(Float(0)) { $0 + $1.brightness }
            if sig != self.lastTickSig {
                self.lastTickSig = sig
                self.model.refresh()
                self.refreshIcon()
            }
        }
        refreshIcon()
    }

    private var lastTickSig: Float = -1

    private var iconAnim: Timer?
    private var animRays: Float = 6
    private var animMode: TrayIcon.Mode = .sun
    /// Where the rays are heading. A drag moves this every frame and the
    /// running animation re-aims at it, instead of being restarted.
    private var targetRays: Float = 6

    /// True while the first-light animation plays, so the startup rescan's
    /// refreshIcon() can't cancel it (it used to land ~100ms in and snap the
    /// icon to its settled state, making the sunrise invisible).
    private var sunrising = false

    /// First launch, two beats: the arms sweep out left→right to the full fan,
    /// then settle down to the display's actual brightness.
    func sunrise() {
        sunrising = true
        animMode = .sun
        animRays = TrayIcon.maxRays
        statusItem.button?.image = TrayIcon.frame(rayFloat: 0, mode: .sun, sweep: 0)

        let target = TrayIcon.state(brightness: currentAverage(), paused: false).rays
        let sweepDuration = 0.75, settleDuration = 0.45
        let start = Date()
        iconAnim?.invalidate()
        iconAnim = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed < sweepDuration {
                let t = elapsed / sweepDuration
                let eased = Float(1 - pow(1 - t, 3)) // easeOutCubic
                self.statusItem.button?.image =
                    TrayIcon.frame(rayFloat: TrayIcon.maxRays, mode: .sun, sweep: eased)
            } else {
                let t = min(1, (elapsed - sweepDuration) / settleDuration)
                let eased = Float(t * t * (3 - 2 * t)) // smoothstep
                self.animRays = TrayIcon.maxRays + (target - TrayIcon.maxRays) * eased
                self.statusItem.button?.image =
                    TrayIcon.frame(rayFloat: max(0.001, self.animRays), mode: .sun)
                if t >= 1 {
                    timer.invalidate()
                    self.animRays = target
                    self.sunrising = false
                    self.refreshIcon()
                }
            }
        }
    }

    /// Open the popover programmatically (first-run welcome).
    func openPopover() {
        guard let button = statusItem.button, !popover.isVisible else { return }
        controller.refreshAppleLevels()
        model.refresh()
        model.refreshWarmth()
        popover.toggle(relativeTo: button)
    }

    private func currentAverage() -> Float {
        let active = store.displays.get().filter { !$0.excluded && $0.backend != .none }
        return active.isEmpty ? 0.5 : active.map(\.brightness).reduce(0, +) / Float(active.count)
    }

    /// Redraw the menu bar mark from the current average brightness / pause
    /// state, animating the ray count (and the sun/moon set) between states.
    func refreshIcon() {
        guard !sunrising else { return } // never interrupt first light
        let avg = currentAverage()
        let paused = store.paused.get()
        let (target, targetMode) = TrayIcon.state(brightness: avg, paused: paused)
        targetRays = target

        // A mode change (sun↔moon↔bare) just settles immediately; only ray
        // count within a mode ticks. Keeps the animation cheap and legible.
        guard targetMode == animMode else {
            iconAnim?.invalidate(); iconAnim = nil
            animMode = targetMode
            animRays = target
            statusItem.button?.image = TrayIcon.image(brightness: avg, paused: paused)
            return
        }
        guard abs(target - animRays) > 0.01 else { return }

        // One long-lived timer chases `targetRays`, rather than a fresh timer
        // per call. Restarting it meant a slider drag — which calls this on
        // every event, faster than 60Hz on a ProMotion panel — invalidated
        // each timer before its first tick, so the icon sat frozen for the
        // whole drag and only snapped once the finger lifted.
        guard iconAnim == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let delta = self.targetRays - self.animRays
            guard abs(delta) > 0.02 else {
                self.animRays = self.targetRays
                self.statusItem.button?.image = TrayIcon.image(
                    brightness: self.currentAverage(), paused: self.store.paused.get()
                )
                timer.invalidate()
                self.iconAnim = nil
                return
            }
            self.animRays += delta * 0.35 // ~0.18s to settle, and re-aims mid-flight
            self.statusItem.button?.image = TrayIcon.frame(rayFloat: self.animRays, mode: self.animMode)
        }
        // .common, not Timer.scheduledTimer's default mode. AppKit runs a
        // nested loop in NSEventTrackingRunLoopMode while a drag is in
        // flight, where a default-mode timer never fires — measured in a
        // running NSApplication: 0 ticks on .default vs 15 on .common over
        // 0.25s of tracking. This is the other half of the frozen icon.
        RunLoop.main.add(timer, forMode: .common)
        iconAnim = timer
    }

    // Tracking-area owner callbacks. NSObject isn't an NSResponder, so the
    // Swift names would export as mouseEnteredWith:/mouseExitedWith: — pin the
    // exact selectors NSTrackingArea sends, or these never fire.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        store.overTray.set(true)
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        store.overTray.set(false)
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent, let button = statusItem.button else { return }
        if event.type == .rightMouseUp {
            popover.close()
            let built = TrayMenu.build(
                store: store, controller: controller, statusController: self
            )
            menuActions = built.actions // keep the weak-referenced target alive
            statusItem.menu = built.menu
            button.performClick(nil) // opens the menu at the item
            statusItem.menu = nil // left-click stays ours afterwards
        } else {
            controller.refreshAppleLevels()
            model.refresh()
            // Night Shift can be moved from Control Center or System
            // Settings while the popover is shut. The notification block
            // covers that, but it coalesces; re-reading on open is one call.
            model.refreshWarmth()
            model.launchAtLogin = LaunchAtLogin.isEnabled
            popover.toggle(relativeTo: button)
        }
    }
}
