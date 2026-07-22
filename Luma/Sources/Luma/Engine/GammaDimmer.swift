import CoreGraphics

/// Software dimming via the display's gamma transfer table
/// (public CGSetDisplayTransferByFormula). Two jobs:
///   • the sub-zero tail that lets any slider dim past the hardware backlight
///     floor (a too-bright panel at night), and
///   • a fallback so DDC-less / mirrored displays are still controllable.
///
/// Gamma is a shared per-display resource: anything else touching it (Night
/// Shift, colour-temperature tools) will fight us, and macOS resets it on
/// wake / resolution
/// change — so remembered factors are re-applied from the self-healing layer.
/// Stateless: the BrightnessController re-asserts factors from the store (the
/// source of truth) after wake/reconfigure, so a display that regains DDC
/// never keeps a stale software dim.
enum GammaDimmer {
    /// Never fully black: a screen you can't get back from is a footgun.
    static let floor: Float = 0.12

    /// factor 1 = untouched, floor = darkest. False if the display refused it.
    @discardableResult
    static func set(_ id: CGDirectDisplayID, factor: Float) -> Bool {
        write(id, min(1, max(floor, factor)))
    }

    /// Restore identity gamma for one display (sub-zero off, or backend
    /// regained). Doubles as a harmless probe for whether gamma works here at
    /// all: AirPlay, Sidecar and DisplayLink screens accept no transfer table,
    /// and a slider driving a call that quietly errors is worse than one the
    /// UI admits it can't offer.
    @discardableResult
    static func clear(_ id: CGDirectDisplayID) -> Bool {
        write(id, 1)
    }

    private static func write(_ id: CGDirectDisplayID, _ f: Float) -> Bool {
        let g = CGGammaValue(1) // linear scale, no curve change
        let maxV = CGGammaValue(f)
        return CGSetDisplayTransferByFormula(id, 0, maxV, g, 0, maxV, g, 0, maxV, g) == .success
    }
}
