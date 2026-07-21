import CoreGraphics
import Foundation

/// Named per-display level snapshots ("Day", "Movie", "Present"), keyed by
/// stable display UUID so they survive replug/reboot. Hand-editable JSON in
/// the same config dir; applied from the tray, a hotkey, or a luma:// URL.
struct ProfileStore: Codable {
    /// name -> (display UUID -> brightness 0…1)
    var profiles: [String: [String: Float]] = [:]

    static var url: URL { ConfigFiles.directory.appendingPathComponent("profiles.json") }

    static func load() -> ProfileStore {
        ConfigFiles.load(ProfileStore.self, from: url) ?? ProfileStore()
    }

    func save() {
        ConfigFiles.save(self, to: Self.url)
    }

    var names: [String] { profiles.keys.sorted() }
}
