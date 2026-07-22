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

guard NightShift.isSupported, let before = NightShift.status() else {
    print("\nCoreBrightness unavailable; skipped the live round trip.")
    exit(failures == 0 ? 0 : 1)
}
let strengthBefore = NightShift.strength
print("\nas found: active=\(before.active) mode=\(before.mode) "
      + "\(before.from.hour):\(before.from.minute) -> \(before.to.hour):\(before.to.minute) "
      + "strength=\(strengthBefore)")

// The decode is only trustworthy if a field we flip is the field we read.
NightShift.setActive(!before.active); usleep(400_000)
check("setActive moves status().active", NightShift.status()?.active == !before.active)

NightShift.setStrength(0.42); usleep(400_000)
check("strength reads back", abs(NightShift.strength - 0.42) < 0.001)

NightShift.applySchedule(.custom, from: .init(hour: 21, minute: 15), to: .init(hour: 6, minute: 45))
usleep(400_000)
let scheduled = NightShift.status()
check("custom schedule round-trips",
      scheduled?.mode == .custom
      && scheduled?.from == NightShift.Time(hour: 21, minute: 15)
      && scheduled?.to == NightShift.Time(hour: 6, minute: 45))
check("custom mode arms the schedule", scheduled?.scheduleEnabled == true)

NightShift.applySchedule(before.mode, from: before.from, to: before.to)
NightShift.setSchedule(from: before.from, to: before.to)
NightShift.setStrength(strengthBefore)
NightShift.setActive(before.active)
usleep(400_000)
let after = NightShift.status()
check("restored to as-found", after == before && abs(NightShift.strength - strengthBefore) < 0.001)

print(failures == 0 ? "\nall checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
