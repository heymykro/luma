import AppKit
import CoreGraphics
import Foundation

enum Backend: String, Codable {
    /// Built-in panel or Apple external (Studio Display, XDR, UltraFine).
    case apple
    /// Non-Apple external via DDC/CI.
    case ddc
    /// No hardware path (DisplayLink dock, DDC disabled/mirrored) — dimmed in
    /// software via the gamma table so it's still controllable.
    case gamma
    /// Truly uncontrollable (shouldn't normally happen now that gamma is a
    /// universal fallback).
    case none
}

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var builtin: Bool
    var backend: Backend
    /// 0...1, cached last-known value.
    var brightness: Float
    /// Hidden from the popover and skipped by keys/master (user setting).
    var excluded: Bool
    /// Stable identity for persistence (CGDirectDisplayIDs are not stable).
    var uuid: String?
    /// Bumped on every user write; lets a rescan detect writes that raced it.
    var writeGen: UInt64 = 0
    /// Set when the last DDC write to this display gave up (monitor asleep,
    /// DDC disabled in its OSD, dead cable). Surfaced in diagnostics/UI.
    var writeFailed: Bool = false
}

/// CoreGraphics display topology: enumeration, classification, geometry.
enum DisplayManager {
    static let appleVendorID: UInt32 = 0x610

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func isBuiltin(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(id) != 0
    }

    static func vendor(_ id: CGDirectDisplayID) -> UInt32 {
        CGDisplayVendorNumber(id)
    }

    /// True if this display mirrors another (controlling the primary covers it).
    static func mirrorsAnother(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
    }

    /// Stable identity across replug/reboot.
    static func stableUUID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Bounds in CG global coordinates (points, top-left origin).
    static func bounds(_ id: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(id)
    }

    /// NSScreen localized names keyed by display id. Main thread only.
    @MainActor
    static func names() -> [CGDirectDisplayID: String] {
        var out: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber {
                out[number.uint32Value] = screen.localizedName
            }
        }
        return out
    }

    /// The display currently containing the mouse pointer. CGEvent location
    /// and CGDisplayBounds share the CG global (top-left origin) space, so
    /// this is a plain hit-test — no y-flip.
    static func displayUnderMouse() -> CGDirectDisplayID? {
        guard let location = CGEvent(source: nil)?.location else {
            return activeDisplayIDs().first
        }
        let ids = activeDisplayIDs()
        return ids.first { bounds($0).contains(location) } ?? ids.first
    }

    /// True if the point sits in the menu-bar strip (top ~28pt) of any
    /// display. Used to self-heal a stuck over-tray flag: a scroll elsewhere
    /// can't be a tray-icon scroll.
    static func pointInMenuBar(_ point: CGPoint) -> Bool {
        activeDisplayIDs().contains { id in
            let b = bounds(id)
            return b.contains(point) && point.y - b.origin.y < 28
        }
    }
}
