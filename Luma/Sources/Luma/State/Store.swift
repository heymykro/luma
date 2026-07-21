import CoreGraphics
import Foundation

/// A value guarded by an unfair lock. The event-tap callback runs on its own
/// thread and reads flags on every keystroke; this keeps those reads cheap
/// without pulling in a dependency for atomics.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = UnfairLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.sync { value } }

    func set(_ newValue: Value) { lock.sync { value = newValue } }

    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.sync { body(&value) } }
}

/// Thread-safe canonical state. UI observes via `onChange` (delivered on the
/// main queue); engine threads mutate directly.
final class Store: @unchecked Sendable {
    let displays = Locked<[DisplayInfo]>([])
    let settings: Locked<Settings>

    // Read on every event-tap callback — kept in separate cells so the tap
    // never contends with a display rescan.
    let paused = Locked(false)
    let overTray = Locked(false)
    let legacyFKeys: Locked<Bool>
    let flipMask: Locked<UInt64>

    /// Last user-set brightness per display UUID; restored when a DDC display
    /// reconnects (they reset themselves on power-cycle).
    let savedLevels: Locked<[String: Float]>
    private let levelsDirty = Locked(false)
    private let saveQueue = DispatchQueue(label: "luma.levels-save")
    private var pendingSave: DispatchWorkItem?

    /// HUD auto-hide generation (a new keypress cancels the pending hide).
    let hudGen = Locked<UInt64>(0)

    /// Fired on the main queue after displays or settings change.
    var onChange: (() -> Void)?

    init() {
        let loaded = ConfigFiles.load(Settings.self, from: ConfigFiles.settings) ?? Settings()
        settings = Locked(loaded)
        legacyFKeys = Locked(loaded.legacyFKeys)
        flipMask = Locked(loaded.flipModifier.mask)
        savedLevels = Locked(ConfigFiles.load([String: Float].self, from: ConfigFiles.levels) ?? [:])
    }

    func notifyChanged() {
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: - Settings

    /// Single path for settings changes (popover + tray): persists, mirrors
    /// the tap-thread flags, and syncs exclusion marks into the display list.
    func updateSettings(_ new: Settings) {
        legacyFKeys.set(new.legacyFKeys)
        flipMask.set(new.flipModifier.mask)
        settings.set(new)
        ConfigFiles.save(new, to: ConfigFiles.settings)
        displays.withLock { list in
            for i in list.indices {
                list[i].excluded = list[i].uuid.map { new.excluded.contains($0) } ?? false
            }
        }
        notifyChanged()
    }

    // MARK: - Saved levels

    func rememberLevel(uuid: String, value: Float) {
        savedLevels.withLock { $0[uuid] = value }
        levelsDirty.set(true)
        // Debounced write: coalesce a burst of slider/key changes into one
        // save ~3s after the last one, off the main thread. No polling timer.
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushLevels() }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Flush saved levels to disk if dirty (debounced saver + quit path).
    func flushLevels() {
        guard levelsDirty.withLock({ dirty -> Bool in
            defer { dirty = false }
            return dirty
        }) else { return }
        ConfigFiles.save(savedLevels.get(), to: ConfigFiles.levels)
    }
}
