// Self-check for the Night Shift binding. Run it with `make check`.
//
// Worth having because none of this is documented: the status struct has no
// public header, so its field offsets were read off the live framework. If a
// macOS update moves them, the decode goes quietly wrong rather than failing,
// and this is the thing that notices.
//
// It writes to the live Night Shift state and restores it afterwards.
import Foundation

var failures = 0
func check(_ label: String, _ passed: Bool) {
    print((passed ? "  ok   " : "  FAIL ") + label)
    if !passed { failures += 1 }
}

// Kelvin mapping, against the two points measured with getCCT:
check("0.5 -> 4100K", NightShift.kelvin(for: 0.5) == 4100)
check("0.714 -> 3500K", NightShift.kelvin(for: 0.714) == 3500)
check("0 -> 5500K", NightShift.kelvin(for: 0) == 5500)
check("1 -> 2700K", NightShift.kelvin(for: 1) == 2700)
check("clamps above 1", NightShift.kelvin(for: 4) == 2700)

// Command parsing
func warm(_ s: String) -> (Float?, Bool?)? {
    guard case .warm(let l, let o)? = LumaCommand.parse(URL(string: s)!) else { return nil }
    return (l, o)
}
check("luma://warm toggles", warm("luma://warm").map { $0.0 == nil && $0.1 == nil } ?? false)
check("level implies on", warm("luma://warm?level=40").map { $0.0 == 0.4 && $0.1 == true } ?? false)
check("explicit off", warm("luma://warm?on=false").map { $0.0 == nil && $0.1 == false } ?? false)

// Stepping the schedule times wraps at midnight in both directions.
let t = NightShift.Time(hour: 0, minute: 0)
check("00:00 back 15m -> 23:45", t.advanced(byMinutes: -15) == .init(hour: 23, minute: 45))
check("23:50 on 15m -> 00:05", NightShift.Time(hour: 23, minute: 50)
        .advanced(byMinutes: 15) == .init(hour: 0, minute: 5))
check("a full day is a no-op", t.advanced(byMinutes: 1440) == t)
check("22:00 on 15m -> 22:15", NightShift.Time(hour: 22, minute: 0)
        .advanced(byMinutes: 15) == .init(hour: 22, minute: 15))

// ── solar maths ────────────────────────────────────────────────────────
// Checked against invariants rather than an almanac, because an almanac
// figure I half-remember is not evidence. Day lengths at the solstices are
// the exception: those two are textbook constants.
func utc(_ y: Int, _ mo: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = 12
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}
func hhmmUTC(_ d: Date) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let c = cal.dateComponents([.hour, .minute], from: d)
    return Double(c.hour!) + Double(c.minute!) / 60
}
func dayLength(_ lat: Double, _ lon: Double, _ date: Date) -> Double? {
    SolarTimes.riseAndSet(latitude: lat, longitude: lon, on: date)
        .map { $0.sunset.timeIntervalSince($0.sunrise) / 3600 }
}

// Equator at an equinox: the sun rises at 06:00 and sets at 18:00 local
// solar time, which at longitude 0 is UTC. This is the shape of the whole
// algorithm; get a sign wrong and it moves hours.
if let e = SolarTimes.riseAndSet(latitude: 0, longitude: 0, on: utc(2026, 3, 20)) {
    check("equator equinox rises ~06:00 UTC", abs(hhmmUTC(e.sunrise) - 6) < 0.2)
    check("equator equinox sets ~18:00 UTC", abs(hhmmUTC(e.sunset) - 18) < 0.2)
    check("equator equinox day is ~12h", abs(e.sunset.timeIntervalSince(e.sunrise) / 3600 - 12) < 0.2)
} else { check("equator equinox resolves", false) }

// Longitude shifts the clock by 4 minutes per degree and nothing else.
if let a = SolarTimes.riseAndSet(latitude: 0, longitude: 0, on: utc(2026, 3, 20)),
   let b = SolarTimes.riseAndSet(latitude: 0, longitude: 15, on: utc(2026, 3, 20)) {
    let shift = a.sunrise.timeIntervalSince(b.sunrise) / 60
    check("15 deg east is 1h earlier", abs(shift - 60) < 3)
}

// Textbook solstice day lengths, north and south.
check("London solstice day ~16h39m", dayLength(51.5074, -0.1278, utc(2026, 6, 21)).map { abs($0 - 16.65) < 0.15 } ?? false)
check("Sydney solstice day ~9h54m", dayLength(-33.8688, 151.2093, utc(2026, 6, 21)).map { abs($0 - 9.9) < 0.15 } ?? false)
check("Sydney summer day ~14h25m", dayLength(-33.8688, 151.2093, utc(2026, 12, 21)).map { abs($0 - 14.4) < 0.15 } ?? false)

// Above the Arctic circle in June the sun never sets, and there is no time
// to print. Returning a bogus one would be worse than saying nothing.
check("polar day returns nothing",
      SolarTimes.riseAndSet(latitude: 78.22, longitude: 15.63, on: utc(2026, 6, 21)) == nil)
check("polar night returns nothing",
      SolarTimes.riseAndSet(latitude: 78.22, longitude: 15.63, on: utc(2026, 12, 21)) == nil)

guard NightShift.isSupported, let before = NightShift.status() else {
    print("\nCoreBrightness unavailable; skipped the live round trip.")
    exit(failures == 0 ? 0 : 1)
}
// observe() is checked before anything else writes: registering the block is
// what crashed at launch once, and it only fails when a write fires it.
//
// It also counts callbacks, because they coalesce: registering late or
// writing in a burst can collapse several changes into one. That is why the
// popover re-reads on open rather than trusting the block alone.
var notified = false
var notifications = 0
NightShift.observe { notified = true; notifications += 1 }

let strengthBefore = NightShift.strength
print("\nas found: active=\(before.active) mode=\(before.mode) "
      + "\(before.from.hour):\(before.from.minute) -> \(before.to.hour):\(before.to.minute) "
      + "strength=\(strengthBefore)")

// The decode is only trustworthy if a field we flip is the field we read.
NightShift.setActive(!before.active); usleep(400_000)
check("setActive moves status().active", NightShift.status()?.active == !before.active)

let beforeStrengthWrites = notifications
NightShift.setStrength(0.42); usleep(400_000)
check("strength reads back", abs(NightShift.strength - 0.42) < 0.001)
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
print("       (that write notified \(notifications - beforeStrengthWrites)x)")

NightShift.applySchedule(.custom, from: .init(hour: 21, minute: 15), to: .init(hour: 6, minute: 45))
usleep(400_000)
let scheduled = NightShift.status()
check("custom schedule round-trips",
      scheduled?.mode == .custom
      && scheduled?.from == NightShift.Time(hour: 21, minute: 15)
      && scheduled?.to == NightShift.Time(hour: 6, minute: 45))
check("custom mode arms the schedule", scheduled?.enabled == true)

// The one that took a human looking at a screen to settle: with no schedule,
// `enabled` is the master switch, and warmth renders only when it is true.
// setMode(.manual) clears it as a side effect, so switching the schedule off
// while warmth is on has to put it back or the screen goes neutral.
NightShift.setWarmth(on: true, scheduled: false); usleep(300_000)
NightShift.applySchedule(.manual, from: before.from, to: before.to)
usleep(400_000)
check("schedule Off keeps warmth on", NightShift.status()?.enabled == true)
NightShift.setWarmth(on: false, scheduled: false); usleep(300_000)
NightShift.applySchedule(.manual, from: before.from, to: before.to)
usleep(400_000)
check("schedule Off leaves warmth off", NightShift.status()?.enabled == false)
NightShift.setWarmth(on: false, scheduled: false); usleep(400_000)
check("warmth off clears both", NightShift.status().map { !$0.enabled && !$0.active } == true)
NightShift.setWarmth(on: true, scheduled: false); usleep(400_000)
check("warmth on sets both", NightShift.status().map { $0.enabled && $0.active } == true)
check("isWarm agrees when on", NightShift.status()?.isWarm == true)

// The toggle bug: warmth on while a schedule is armed must still render, not
// just set active and leave the master switch off.
NightShift.applySchedule(.sunsetToSunrise, from: before.from, to: before.to)
NightShift.setWarmth(on: false, scheduled: true); usleep(300_000)
NightShift.setEnabled(false); usleep(300_000)   // force the neutral-but-armed state
NightShift.setWarmth(on: true, scheduled: true); usleep(400_000)
check("toggle on renders under a schedule", NightShift.status()?.isWarm == true)
NightShift.setWarmth(on: false, scheduled: true); usleep(300_000)
check("toggle off under a schedule keeps it armed", NightShift.status()?.enabled == true)

// active alone is what the toggle used to read, and this is the state that
// exposed it: it says on, the screen says otherwise.
NightShift.setActive(true); NightShift.setEnabled(false); usleep(400_000)
check("active without enabled is not warm", NightShift.status().map { $0.active && !$0.isWarm } == true)

// Order matters on the way back: setMode clears the master switch, so
// applySchedule has to run before `enabled` is restored, not after.
NightShift.applySchedule(before.mode, from: before.from, to: before.to)
NightShift.setSchedule(from: before.from, to: before.to)
NightShift.setStrength(strengthBefore)
NightShift.setActive(before.active)
NightShift.setEnabled(before.enabled)
usleep(400_000)
let after = NightShift.status()
// observe() delivers on the main queue, which a command-line tool only drains
// if something runs the runloop. Without this the check reports a false miss.
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
check("observe() fires on change", notified)
check("restored to as-found", after == before && abs(NightShift.strength - strengthBefore) < 0.001)

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
