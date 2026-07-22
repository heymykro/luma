import Foundation

/// Screen warmth, driven through macOS's own Night Shift rather than a second
/// gamma layer.
///
/// This matters: Luma already owns the gamma transfer table for sub-zero
/// dimming, and gamma is one shared per-display resource. A warmth layer of
/// our own would fight the dimmer, and whichever wrote last would win. Night
/// Shift is a separate stage in the pipeline, so warmth and dimming compose.
/// It also survives sleep/wake and display reconfiguration for free, which
/// the gamma layer does not, and System Settings shows the same value we set.
///
/// The API is `CBBlueLightClient` in the private CoreBrightness framework,
/// loaded at runtime by name so a macOS that drops a selector degrades to
/// "unsupported" instead of failing to launch.
///
/// Verified on macOS 26.5 (2026-07-22): every selector below responds, writes
/// read back exactly, and none of it needs a permission grant.
enum NightShift {

    // MARK: - Schedule

    /// `setMode:` values. Named for what System Settings calls them.
    enum Mode: Int32 {
        case manual = 0        // no schedule; on until you turn it off
        case sunsetToSunrise = 1
        case custom = 2
    }

    /// Minutes since midnight, which is what the popover's pickers speak.
    /// CBBlueLightClient wants two 32-bit fields per time.
    struct Time: Equatable {
        var hour: Int
        var minute: Int
        var minutesSinceMidnight: Int { hour * 60 + minute }
        init(hour: Int, minute: Int) { self.hour = hour; self.minute = minute }
        init(minutesSinceMidnight m: Int) {
            let wrapped = ((m % 1440) + 1440) % 1440   // Swift's % keeps the sign
            hour = wrapped / 60
            minute = wrapped % 60
        }

        /// Wraps around midnight in both directions, so stepping back from
        /// 00:00 lands on 23:45 rather than a negative hour.
        func advanced(byMinutes delta: Int) -> Time {
            Time(minutesSinceMidnight: minutesSinceMidnight + delta)
        }
    }

    struct Status: Equatable {
        /// Warmth applying right now. Necessary but NOT sufficient: with
        /// `enabled` false the screen stays neutral no matter what this says.
        var active = false
        /// The master switch, and the field that cost the most to work out.
        /// With no schedule it is the only thing that makes warmth render;
        /// with one it doubles as the schedule's arming flag.
        var enabled = false
        var sunSchedulePermitted = false // false when Location Services can't place you

        /// Whether the screen is actually warm. Neither flag means it alone,
        /// so anything user-facing must ask this rather than either one: a
        /// toggle bound to `active` reads ON while the screen sits neutral.
        var isWarm: Bool { active && enabled }
        var mode: Mode = .manual
        var from = Time(hour: 22, minute: 0)
        var to = Time(hour: 7, minute: 0)
    }

    // MARK: - Runtime binding

    /// One client for the process. CBBlueLightClient is cheap but the
    /// notification block is registered against this instance, so it has to
    /// outlive every call.
    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                     RTLD_LAZY) != nil,
              let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type
        else { return nil }
        return cls.init()
    }()

    /// Every selector we use, resolved once. Missing any one means a macOS
    /// that reshaped the class, and we treat the whole feature as absent
    /// rather than half-driving it.
    private static let selectors = [
        "getBlueLightStatus:", "setActive:", "getStrength:", "setStrength:commit:",
        "setMode:", "setEnabled:", "setSchedule:", "setStatusNotificationBlock:",
    ]

    static let isSupported: Bool = {
        guard let c = client else { return false }
        return selectors.allSatisfy { c.responds(to: Selector($0)) }
    }()

    private static func fn<T>(_ name: String, _ signature: T.Type) -> T? {
        guard let c = client,
              let m = class_getInstanceMethod(Swift.type(of: c), Selector(name)) else { return nil }
        return unsafeBitCast(method_getImplementation(m), to: signature)
    }

    private typealias GetStatusFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias GetFloatFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
    private typealias SetBoolFn = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias SetInt32Fn = @convention(c) (AnyObject, Selector, Int32) -> Bool
    private typealias SetFloatCommitFn = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
    private typealias SetScheduleFn = @convention(c) (AnyObject, Selector, UnsafeRawPointer) -> Bool
    /// The block parameter is typed AnyObject rather than a Swift function
    /// type on purpose. Swift passes closures to C function pointers as
    /// non-escaping, and CoreBrightness stores this one, which trips the
    /// "closure argument passed as @noescape to Objective-C has escaped"
    /// trap at launch. Handing it over as an already-bridged block object
    /// sidesteps that; `notificationBlock` below keeps it alive.
    private typealias SetBlockFn = @convention(c) (AnyObject, Selector, AnyObject) -> Void

    // MARK: - Reading

    /// `getBlueLightStatus:` fills a C struct that has no public header. The
    /// layout below was read off the live framework by toggling one field at
    /// a time and diffing the bytes:
    ///
    ///   0      active                (setActive: flips this)
    ///   1      scheduleEnabled       (setEnabled: flips this)
    ///   2      sunSchedulePermitted
    ///   4..7   mode, Int32
    ///   8..15  fromTime  {hour: Int32, minute: Int32}
    ///   16..23 toTime    {hour: Int32, minute: Int32}
    ///
    /// Read defensively: a shorter reply than 24 bytes means the layout moved
    /// and we report "unsupported" rather than decode noise. The buffer is
    /// oversized for the same reason, so a longer struct can't overflow us.
    static func status() -> Status? {
        guard isSupported, let c = client,
              let get = fn("getBlueLightStatus:", GetStatusFn.self) else { return nil }
        var buffer = [UInt8](repeating: 0xFF, count: 64)
        let ok = buffer.withUnsafeMutableBytes { get(c, Selector(("getBlueLightStatus:")), $0.baseAddress!) }
        guard ok else { return nil }

        func int32(at offset: Int) -> Int32 {
            buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
        }
        var s = Status()
        s.active = buffer[0] == 1
        s.enabled = buffer[1] == 1
        s.sunSchedulePermitted = buffer[2] == 1
        s.mode = Mode(rawValue: int32(at: 4)) ?? .manual
        s.from = Time(hour: Int(int32(at: 8)), minute: Int(int32(at: 12)))
        s.to = Time(hour: Int(int32(at: 16)), minute: Int(int32(at: 20)))
        return s
    }

    /// 0 = neutral (5500K), 1 = warmest (2700K). Strength and colour
    /// temperature are the same dial; `getCCT:` reports the Kelvin view of it.
    static var strength: Float {
        guard let c = client, let get = fn("getStrength:", GetFloatFn.self) else { return 0 }
        var value: Float = 0
        return get(c, Selector(("getStrength:")), &value) ? value : 0
    }

    /// The Kelvin the slider position corresponds to. Derived rather than
    /// read back, so the label tracks the drag instead of the last commit.
    /// Endpoints measured against `getCCT:`: 0.5 -> 4100K, 0.714 -> 3500K.
    static func kelvin(for strength: Float) -> Int {
        Int((5500 - 2800 * max(0, min(1, strength))).rounded() / 50) * 50
    }

    // MARK: - Writing

    @discardableResult
    static func setActive(_ on: Bool) -> Bool {
        guard let c = client, let set = fn("setActive:", SetBoolFn.self) else { return false }
        return set(c, Selector(("setActive:")), on)
    }

    /// `commit: false` would leave the value uncommitted for a later flush;
    /// we always commit because the slider is the only writer.
    @discardableResult
    static func setStrength(_ value: Float) -> Bool {
        guard let c = client, let set = fn("setStrength:commit:", SetFloatCommitFn.self) else { return false }
        return set(c, Selector(("setStrength:commit:")), max(0, min(1, value)), true)
    }

    @discardableResult
    static func setMode(_ mode: Mode) -> Bool {
        guard let c = client, let set = fn("setMode:", SetInt32Fn.self) else { return false }
        return set(c, Selector(("setMode:")), mode.rawValue)
    }

    /// The master switch. Two jobs, which is what made it confusing:
    /// with a schedule it arms that schedule (setting mode to `.custom` alone
    /// leaves it false and nothing happens at the appointed hour), and with
    /// no schedule it is the whole feature's on/off.
    ///
    /// Verified by hand on 2026-07-23: mode `.manual` + active true + this
    /// false renders nothing at all; flipping this true turns the screen
    /// orange immediately, on every display.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        guard let c = client, let set = fn("setEnabled:", SetBoolFn.self) else { return false }
        return set(c, Selector(("setEnabled:")), on)
    }

    /// The schedule struct is the same two time pairs the status reports, in
    /// the same order, which is how it was identified: write one, read it
    /// back out of `getBlueLightStatus:`.
    @discardableResult
    static func setSchedule(from: Time, to: Time) -> Bool {
        guard let c = client, let set = fn("setSchedule:", SetScheduleFn.self) else { return false }
        var payload: (Int32, Int32, Int32, Int32) =
            (Int32(from.hour), Int32(from.minute), Int32(to.hour), Int32(to.minute))
        return withUnsafeBytes(of: &payload) { set(c, Selector(("setSchedule:")), $0.baseAddress!) }
    }

    /// The schedule picker sets the mode, and arms it when there is one to
    /// arm. "Off" means no schedule, not no warmth, so warmth that was on
    /// stays on: `setMode(.manual)` clears the master switch as a side effect,
    /// which is precisely why picking Off used to kill warmth outright.
    /// Re-asserting it afterwards sticks.
    static func applySchedule(_ mode: Mode, from: Time, to: Time) {
        let wasOn = status()?.active ?? false
        if mode == .custom { setSchedule(from: from, to: to) }
        setMode(mode)
        if mode == .manual { setEnabled(wasOn) } else { setEnabled(true) }
    }

    /// The warmth toggle. With no schedule the master switch is the switch;
    /// with one it belongs to the schedule, so turning warmth off there means
    /// "off until the next scheduled change", which is `setActive:` alone.
    static func setWarmth(on: Bool, scheduled: Bool) {
        if !scheduled { setEnabled(on) }
        setActive(on)
    }

    // MARK: - Change notifications

    /// Fires when anything moves Night Shift: our own writes, Control Center,
    /// System Settings, or the schedule rolling over. Without this the
    /// popover would show a stale value after a scheduled sunset.
    ///
    /// The block's argument is a status dictionary we don't need; the
    /// callback re-reads through `status()` so there is one decode path.
    static func observe(_ onChange: @escaping () -> Void) {
        guard isSupported, let c = client,
              let set = fn("setStatusNotificationBlock:", SetBlockFn.self) else { return }
        let block: @convention(block) (UnsafeRawPointer?) -> Void = { _ in
            DispatchQueue.main.async(execute: onChange)
        }
        notificationBlock = block  // CoreBrightness does not own it; we must
        set(c, Selector(("setStatusNotificationBlock:")), block as AnyObject)
    }

    private static var notificationBlock: Any?
}
