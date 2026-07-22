import Foundation

/// A parsed luma:// action. One command vocabulary shared by the URL scheme
/// (today) and hotkeys / Shortcuts (later), so there's a single place that
/// knows what Luma can be told to do.
///
///   luma://set?level=40                     set every display to 40%
///   luma://set?display=<uuid>&level=70      set one display
///   luma://up   luma://down                 step brightness
///   luma://profile/Movie                    apply a saved profile
///   luma://pause            luma://pause?on=true
///   luma://warm?level=40    set Night Shift warmth (also turns it on)
///   luma://warm?on=false    turn warmth off without changing its level
enum LumaCommand {
    case setAll(Float)
    case setDisplay(uuid: String, level: Float)
    case step(up: Bool)
    case profile(String)
    case pause(Bool?) // nil = toggle
    /// level nil = leave the strength alone; on nil = toggle.
    case warm(level: Float?, on: Bool?)

    static func parse(_ url: URL) -> LumaCommand? {
        guard url.scheme?.lowercased() == "luma" else { return nil }
        let action = (url.host ?? url.pathComponents.dropFirst().first ?? "").lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ key: String) -> String? { items.first { $0.name == key }?.value }
        func level(_ s: String?) -> Float? {
            guard let n = s.flatMap({ Float($0) }) else { return nil }
            return min(1, max(0, n > 1 ? n / 100 : n)) // accept 0–1 or 0–100
        }

        switch action {
        case "set":
            guard let lvl = level(query("level")) else { return nil }
            if let uuid = query("display") { return .setDisplay(uuid: uuid, level: lvl) }
            return .setAll(lvl)
        case "up": return .step(up: true)
        case "down": return .step(up: false)
        case "profile":
            let name = query("name") ?? url.pathComponents.dropFirst().first
            return name.map { .profile($0) }
        case "pause":
            if let on = query("on") { return .pause(on == "true" || on == "1") }
            return .pause(nil)
        case "warm":
            let lvl = level(query("level"))
            let on = query("on").map { $0 == "true" || $0 == "1" }
            // Bare luma://warm toggles; a level implies you want it on.
            return .warm(level: lvl, on: lvl == nil && on == nil ? nil : (on ?? true))
        default:
            return nil
        }
    }
}
