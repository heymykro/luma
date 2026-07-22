import AppKit
import CoreGraphics

/// Entry point. Menu-bar only (LSUIElement in Info.plist + accessory policy).
@main
enum LumaApp {
    static func main() {
        // Two instances = two event taps = double brightness steps. Test for
        // *another* process rather than count > 1: a directly-exec'd instance
        // isn't in LaunchServices yet at this point, so it wouldn't see itself.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.getluma.Luma"
        ).contains { $0.processIdentifier != me }
        if others {
            NSLog("[luma] already running — exiting")
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication.delegate is weak and `delegate` is its only strong
        // owner; pin it past run() so ARC can't release it early.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var controller: BrightnessController!
    private var model: AppModel!
    private var statusController: StatusItemController!
    private var keyTap: KeyTap!
    private var hud: HUDController!
    private var hotplug: HotplugWatcher!
    private var configWatcher: ConfigWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = Store()
        controller = BrightnessController(store: store, ddc: DDCWorker())
        hud = HUDController(store: store)
        model = AppModel(store: store, controller: controller)

        let popover = PopoverPanel(model: model)
        statusController = StatusItemController(
            store: store, controller: controller, popover: popover, model: model
        )

        // UI mirror: engine threads mutate the store, UI re-reads on main and
        // the menu bar icon redraws from the new average brightness.
        store.onChange = { [weak self] in
            self?.model.refresh()
            self?.statusController.refreshIcon()
        }
        model.onAdjust = { [weak self] in self?.statusController.refreshIcon() }
        model.axTrusted = Accessibility.trusted
        model.launchAtLogin = LaunchAtLogin.isEnabled

        // Initial display scan (serialized off the main thread).
        controller.scheduleRescan()

        // Hotplug: re-scan after topology settles (DDC handles go stale).
        hotplug = HotplugWatcher { [weak self] removed in
            self?.controller.scheduleRescan(removedIDs: removed)
        }

        // Sleep/wake: DDC handles go stale and panels may reset to factory
        // brightness with no CG event — proactively heal on wake instead of
        // waiting for the user's first (silently-dropped) adjustment.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Log.note("system woke")
            self?.controller.healAfterWake()
        }

        // Brightness key interception (waits for the Accessibility grant).
        keyTap = KeyTap(store: store, controller: controller, hud: hud)
        keyTap.onAXChanged = { [weak self] trusted in self?.model.axTrusted = trusted }
        keyTap.start()

        // Unsigned and outside the App Store, so nothing tells a user their
        // build is stale. One quiet check a day; silent unless there's news.
        Updater.checkOnLaunchIfDue()

        // luma:// URL scheme (Shortcuts "Open URL", Raycast, scripts).
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )

        // First light: the sun rises in the menu bar, then the popover opens
        // itself so the whole pipeline proves itself in a few seconds.
        if !store.settings.get().hasOnboarded {
            statusController.sunrise()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                self?.statusController.openPopover()
            }
        }

        // Hot-reload: apply hand-edits to settings.json live (config as API).
        configWatcher = ConfigWatcher(directory: ConfigFiles.directory) { [weak self] in
            guard let self,
                  let disk = ConfigFiles.load(Settings.self, from: ConfigFiles.settings),
                  disk != self.store.settings.get() // ignore our own writes (no loop)
            else { return }
            Log.note("settings.json changed on disk — reloading")
            self.store.updateSettings(disk)
            self.controller.reapplyAllLevels()
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string), let command = LumaCommand.parse(url) else { return }
        run(command)
    }

    /// Execute a parsed command from any source (URL scheme today).
    func run(_ command: LumaCommand) {
        switch command {
        case .setAll(let v):
            controller.applyAll(value: v)
        case .setDisplay(let uuid, let v):
            if let id = store.displays.get().first(where: { $0.uuid == uuid })?.id {
                controller.apply(id: id, value: v)
                store.notifyChanged()
            }
        case .step(let up):
            if let value = controller.adjust(delta: up ? 1.0 / 16 : -1.0 / 16, invertRouting: false) {
                hud.show(value: value)
            }
        case .profile(let name):
            controller.applyProfile(name)
        case .pause(let on):
            store.paused.set(on ?? !store.paused.get())
            statusController.refreshIcon()
            store.notifyChanged()
        case .warm(let level, let on):
            if let level { NightShift.setStrength(level) }
            NightShift.setActive(on ?? !(NightShift.status()?.active ?? false))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushLevels()
    }
}

/// CGDisplayRegisterReconfigurationCallback with a debounce: rescan only
/// after 1.5s pass with no further topology events. Removed/disabled ids are
/// collected across the window so a fast unplug+replug (one coalesced rescan,
/// same display id) still counts as a reconnect for brightness restore.
final class HotplugWatcher {
    private let onSettled: (Set<CGDirectDisplayID>) -> Void
    private let pending = Locked<Set<CGDirectDisplayID>>([])
    private var debounce: DispatchWorkItem?

    init(onSettled: @escaping (Set<CGDirectDisplayID>) -> Void) {
        self.onSettled = onSettled
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ id, flags, userInfo in
            guard let userInfo else { return }
            let watcher = Unmanaged<HotplugWatcher>.fromOpaque(userInfo).takeUnretainedValue()
            watcher.event(id: id, flags: flags)
        }, refcon)
    }

    private func event(id: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        if flags.contains(.beginConfigurationFlag) { return }
        // Everything that changes list membership: hotplug, enable/disable,
        // and mirror toggles (mirrored displays are filtered out of the list).
        let topology: CGDisplayChangeSummaryFlags = [
            .addFlag, .removeFlag, .enabledFlag, .disabledFlag, .mirrorFlag, .unMirrorFlag,
        ]
        guard !flags.intersection(topology).isEmpty else { return }
        if !flags.intersection([.removeFlag, .disabledFlag]).isEmpty {
            pending.withLock { _ = $0.insert(id) }
        }

        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let removed = self.pending.withLock { removed -> Set<CGDirectDisplayID> in
                defer { removed.removeAll() }
                return removed
            }
            self.onSettled(removed)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
