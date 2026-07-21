import CoreGraphics
import Foundation

/// Applies brightness through the right backend and owns the display rescan.
/// Pure engine: no AppKit except the main-thread hop for NSScreen names.
final class BrightnessController {
    let store: Store
    let ddc: DDCWorker
    /// Rescans (launch, hotplug, manual, wake) run one-at-a-time here so a
    /// slow DDC refresh can't be overtaken by a newer one installing stale data.
    private let rescanQueue = DispatchQueue(label: "luma.rescan")

    init(store: Store, ddc: DDCWorker) {
        self.store = store
        self.ddc = ddc
        // Write-verified brightness: only persist a DDC level once the monitor
        // confirms it; a permanent failure marks the display instead of leaving
        // the slider/HUD/saved-levels showing a value the panel never took.
        ddc.onWriteResult = { [weak self] id, ok in
            guard let self else { return }
            self.store.displays.withLock { list in
                guard let i = list.firstIndex(where: { $0.id == id }) else { return }
                list[i].writeFailed = !ok
                if ok, let uuid = list[i].uuid {
                    self.store.rememberLevel(uuid: uuid, value: list[i].brightness)
                }
            }
            if !ok { self.store.notifyChanged() }
        }
    }

    /// Serialized rescan entry point — every trigger routes through here.
    func scheduleRescan(removedIDs: Set<CGDirectDisplayID> = []) {
        rescanQueue.async { [weak self] in self?.rescanDisplays(removedIDs: removedIDs) }
    }

    /// After wake, DDC panels may have reset to factory brightness with no CG
    /// remove event — force restore-on-reconnect for every DDC display so their
    /// saved level is re-applied (and handles rebuilt) before the user notices.
    func healAfterWake() {
        // Deliberately late. The DDC channel stays unresponsive for seconds
        // after wake, so healing immediately spends all three write attempts
        // into a dead bus, loses the restore, and flags healthy monitors as
        // failed. The dead window runs from seconds to tens of seconds
        // depending on the panel, so this errs late.
        rescanQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let ddcIDs = Set(self.store.displays.get().filter { $0.backend == .ddc }.map(\.id))
            Log.note("wake: healing \(ddcIDs.count) DDC display(s)")
            self.rescanDisplays(removedIDs: ddcIDs)
        }
    }

    // MARK: - Apply

    /// Set one display; returns the value actually applied.
    @discardableResult
    func apply(id: CGDirectDisplayID, value rawValue: Float) -> Float {
        let value = min(max(rawValue, 0), 1)
        let subZero = store.settings.get().subZero
        store.displays.withLock { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            switch list[i].backend {
            case .apple, .ddc:
                // With sub-zero, the bottom of the slider drives gamma while
                // the backlight sits at its floor; otherwise the backlight
                // takes the whole range and gamma is identity.
                let (backlight, gamma) = subZero ? Self.splitSubZero(value) : (value, Float(1))
                if list[i].backend == .apple {
                    if AppleBrightness.set(id, backlight) {
                        list[i].writeFailed = false
                        if let uuid = list[i].uuid { store.rememberLevel(uuid: uuid, value: value) }
                    } else {
                        list[i].writeFailed = true
                        Log.note("apple set failed for display \(id)")
                    }
                } else {
                    // Optimistic cache; the worker's write result settles
                    // rememberLevel + writeFailed.
                    ddc.set(id, backlight)
                }
                if gamma < 1 { GammaDimmer.set(id, factor: gamma) } else { GammaDimmer.clear(id) }
            case .gamma:
                // Software-only: the whole slider is gamma.
                GammaDimmer.set(id, factor: GammaDimmer.floor + value * (1 - GammaDimmer.floor))
                list[i].writeFailed = false
                if let uuid = list[i].uuid { store.rememberLevel(uuid: uuid, value: value) }
            case .none:
                return
            }
            list[i].brightness = value
            list[i].writeGen += 1
        }
        return value
    }

    /// Slider → (hardware backlight, gamma factor) when sub-zero is on. The
    /// top 70% of travel is the backlight range; the bottom 30% parks the
    /// backlight at its floor and dims further in software.
    static func splitSubZero(_ v: Float) -> (backlight: Float, gamma: Float) {
        let tail: Float = 0.30
        if v >= tail { return ((v - tail) / (1 - tail), 1) }
        return (0, GammaDimmer.floor + (v / tail) * (1 - GammaDimmer.floor))
    }

    /// Re-apply every display's current level through `apply` (which respects
    /// the live sub-zero setting) — used when sub-zero is toggled, and after
    /// wake/reconfigure resets the gamma tables.
    func reapplyAllLevels() {
        for d in store.displays.get() where d.backend != .none {
            apply(id: d.id, value: d.brightness)
        }
        store.notifyChanged()
    }

    // MARK: - Profiles

    /// Snapshot every controllable display's current level under `name`.
    func saveProfile(_ name: String) {
        var store = ProfileStore.load()
        var snapshot: [String: Float] = [:]
        for d in self.store.displays.get() where d.backend != .none {
            if let uuid = d.uuid { snapshot[uuid] = d.brightness }
        }
        store.profiles[name] = snapshot
        store.save()
        Log.note("profile saved: \(name) (\(snapshot.count) displays)")
    }

    func deleteProfile(_ name: String) {
        var store = ProfileStore.load()
        store.profiles[name] = nil
        store.save()
    }

    /// Apply a saved profile by name; returns false if it doesn't exist.
    @discardableResult
    func applyProfile(_ name: String) -> Bool {
        guard let snapshot = ProfileStore.load().profiles[name] else { return false }
        for d in store.displays.get() {
            if let uuid = d.uuid, let level = snapshot[uuid] { apply(id: d.id, value: level) }
        }
        store.notifyChanged()
        Log.note("profile applied: \(name)")
        return true
    }

    /// Set every non-excluded display and notify the UI (tray/preset paths).
    func applyAll(value: Float) {
        let ids = store.displays.get()
            .filter { !$0.excluded && $0.backend != .none }
            .map(\.id)
        for id in ids { apply(id: id, value: value) }
        store.notifyChanged()
    }

    /// Whether a key press would actually change any display right now, under
    /// the given routing. Lets the tap pass the key through (native handling)
    /// instead of consuming it into a no-op.
    func hasAdjustableTarget(invertRouting: Bool) -> Bool {
        var mode = store.settings.get().keyMode
        if invertRouting { mode = mode == .all ? .underMouse : .all }
        let underMouse = mode == .all ? nil : DisplayManager.displayUnderMouse()
        return store.displays.get().contains {
            $0.backend != .none && !$0.excluded && (mode == .all || $0.id == underMouse)
        }
    }

    /// Step targets per the routing mode (keys/knob/scroll path).
    /// Returns the value applied to the last target, for the HUD.
    func adjust(delta: Float, invertRouting: Bool) -> Float? {
        var mode = store.settings.get().keyMode
        if invertRouting {
            mode = mode == .all ? .underMouse : .all
        }
        let underMouse = DisplayManager.displayUnderMouse()
        let targets = store.displays.get()
            .filter { $0.backend != .none && !$0.excluded }
            .filter { mode == .all || $0.id == underMouse }

        var hudValue: Float?
        for display in targets {
            // Apple brightness drifts (auto-brightness, Control Center) —
            // step from the live value, not the cache.
            let current = display.backend == .apple
                ? (AppleBrightness.get(display.id) ?? display.brightness)
                : display.brightness
            let value = min(max(current + delta, 0), 1)
            apply(id: display.id, value: value)
            hudValue = value
        }
        if hudValue != nil { store.notifyChanged() }
        return hudValue
    }

    // MARK: - Rescan

    /// Rebuild the display list (topology + backends + brightness) and notify
    /// the UI. Call from a background thread: it round-trips to the main
    /// thread for NSScreen names and blocks on the DDC worker for reads.
    ///
    /// `removedIDs`: displays that got a REMOVE/DISABLED reconfiguration event
    /// in the batch that triggered this rescan — treated as reconnects for
    /// brightness restore even when the id survived the debounce window.
    func rescanDisplays(removedIDs: Set<CGDirectDisplayID> = []) {
        // Boxed so a late main-thread write (if the 3s wait times out under a
        // launch-time main-thread stall) lands harmlessly instead of racing
        // the read below.
        let namesBox = Locked<[CGDirectDisplayID: String]>([:])
        let namesReady = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            namesBox.set(DisplayManager.names())
            namesReady.signal()
        }
        _ = namesReady.wait(timeout: .now() + 3)
        let names = namesBox.get()

        // Snapshot write generations so slider/key writes that land while the
        // (slow, seconds-long) DDC refresh is in flight aren't clobbered by
        // the stale values the refresh read before them.
        let genSnapshot = Dictionary(
            uniqueKeysWithValues: store.displays.get().map { ($0.id, $0.writeGen) }
        )
        let prev = Dictionary(
            uniqueKeysWithValues: store.displays.get().map { ($0.id, $0.brightness) }
        )
        let excludedUUIDs = store.settings.get().excluded

        // Mirror-set members are kept, not filtered out: a mirrored panel is
        // still a physical panel with its own backlight, and dropping it left
        // it invisible and uncontrollable (mirror a laptop to a TV and its
        // brightness was unreachable). Every member is driven; only software
        // dimming is disqualified below.
        let candidateIDs = DisplayManager.activeDisplayIDs()
        let nonAppleIDs = candidateIDs.filter { DisplayManager.vendor($0) != DisplayManager.appleVendorID }
        let ddcLevels = ddc.refreshSync(ids: nonAppleIDs)

        var list: [DisplayInfo] = []
        for id in candidateIDs {
            let uuid = DisplayManager.stableUUID(id)
            let excluded = uuid.map { excludedUUIDs.contains($0) } ?? false
            let builtin = DisplayManager.isBuiltin(id)
            // Strict vendor guard: on macOS 15+ DisplayServices "works" on
            // non-Apple HDR displays but drives the SDR-peak slider, not the
            // backlight.
            let apple = builtin
                || (DisplayManager.vendor(id) == DisplayManager.appleVendorID
                    && AppleBrightness.canChange(id))

            var backend: Backend
            var brightness: Float
            if apple {
                backend = .apple
                brightness = AppleBrightness.get(id) ?? 0.5
            } else if let level = ddcLevels[id], let value = level {
                backend = .ddc
                brightness = value
            } else if mirrorSlave(id) {
                // Gamma belongs to whichever display actually renders; on a
                // mirror slave it either no-ops or double-dims the master's
                // output. With no DDC path there is nothing honest to offer.
                backend = .none
                brightness = prev[id] ?? 1.0
            } else if ddcLevels[id] != nil {
                // Enumerated but never answered a read — DDC switched off in
                // the OSD, or a panel that only pretends to speak it. I2C ACKs
                // the writes either way, so a write looks like it worked while
                // nothing moves; software dimming actually changes the picture.
                // ponytail: costs a true write-only DDC panel its hardware
                // backlight; revisit if one shows up (verify with a read-back).
                backend = softwareBackend(id)
                brightness = prev[id] ?? 1.0
                Log.note("display \(id): DDC enumerated but reads fail — using software dimming")
            } else {
                // No hardware path — controllable in software via gamma, if
                // this display accepts a transfer table at all.
                backend = softwareBackend(id)
                brightness = prev[id] ?? 1.0
            }

            // Restore-on-reconnect: DDC monitors reset themselves on
            // power-cycle. Only for newly-appeared (or just-removed) DDC
            // displays. Intentionally also fires on the first scan at launch:
            // that covers monitors power-cycled while Luma wasn't running.
            if backend == .ddc, !excluded,
               prev[id] == nil || removedIDs.contains(id),
               let uuid, let saved = store.savedLevels.get()[uuid],
               abs(saved - brightness) > 0.01 {
                ddc.set(id, saved)
                brightness = saved
            }

            let name = names[id] ?? (builtin ? "Built-in Display" : "Display \(id)")
            list.append(DisplayInfo(
                id: id, name: name, builtin: builtin, backend: backend,
                brightness: brightness, excluded: excluded, uuid: uuid
            ))
        }

        // Externals first (the ones people actually adjust), built-in last.
        list.sort { ($0.builtin ? 1 : 0, $0.id) < ($1.builtin ? 1 : 0, $1.id) }

        // Install atomically; writes that raced the rescan win over the
        // values the rescan read (their queued Set lands on hardware last).
        // Re-read exclusions here (not the pre-refresh snapshot): the rescan
        // spends seconds in DDC I/O, and a toggle during that window must not
        // be reverted by installing a list built from stale exclusion state.
        let liveExcluded = store.settings.get().excluded
        store.displays.withLock { current in
            for i in list.indices {
                list[i].excluded = list[i].uuid.map { liveExcluded.contains($0) } ?? false
                if let existing = current.first(where: { $0.id == list[i].id }) {
                    if genSnapshot[list[i].id] != existing.writeGen {
                        list[i].brightness = existing.brightness
                    }
                    list[i].writeGen = existing.writeGen
                    list[i].writeFailed = existing.writeFailed
                }
            }
            current = list
        }
        // Gamma tables reset on reconfigure/wake — re-assert any dim factors.
        reassertGamma()
        store.notifyChanged()
    }

    /// True if `id` mirrors another display, i.e. something else renders it.
    private func mirrorSlave(_ id: CGDirectDisplayID) -> Bool {
        DisplayManager.mirrorsAnother(id)
    }

    /// `.gamma` only if this display actually accepts a transfer table.
    /// AirPlay, Sidecar and DisplayLink screens do not, and CoreGraphics says
    /// so rather than failing silently — so ask before offering a slider.
    /// The probe writes identity gamma; `reassertGamma()` restores the real
    /// factor at the end of the rescan.
    private func softwareBackend(_ id: CGDirectDisplayID) -> Backend {
        GammaDimmer.clear(id) ? .gamma : .none
    }

    /// Re-assert the correct gamma for every display (no backlight writes),
    /// driven from the store — after wake/reconfigure zeroed the tables, or a
    /// backend changed.
    private func reassertGamma() {
        let subZero = store.settings.get().subZero
        for d in store.displays.get() {
            switch d.backend {
            case .gamma:
                GammaDimmer.set(d.id, factor: GammaDimmer.floor + d.brightness * (1 - GammaDimmer.floor))
            case .apple, .ddc:
                let gamma = subZero ? Self.splitSubZero(d.brightness).gamma : 1
                if gamma < 1 { GammaDimmer.set(d.id, factor: gamma) } else { GammaDimmer.clear(d.id) }
            case .none:
                break
            }
        }
    }

    /// Re-read Apple backends (cheap) so the popover opens with live values.
    func refreshAppleLevels() {
        store.displays.withLock { list in
            for i in list.indices where list[i].backend == .apple {
                if let v = AppleBrightness.get(list[i].id) {
                    list[i].brightness = v
                }
            }
        }
    }
}
