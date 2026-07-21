import CoreGraphics
import Foundation

enum KeyMode: String, Codable, CaseIterable {
    case all = "all"
    case underMouse = "under-mouse"
}

enum FlipModifier: String, Codable, CaseIterable {
    case option, control, shift, command

    /// CGEventFlags mask bit for this modifier.
    var mask: UInt64 {
        switch self {
        case .option: return CGEventFlags.maskAlternate.rawValue
        case .control: return CGEventFlags.maskControl.rawValue
        case .shift: return CGEventFlags.maskShift.rawValue
        case .command: return CGEventFlags.maskCommand.rawValue
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }
}

enum HUDPosition: String, Codable, CaseIterable {
    /// Notch / dynamic-island style, top-center.
    case top
    /// Vertical pill sliding out from the left edge.
    case left
    /// Vertical pill sliding out from the right edge.
    case right
}

/// Persisted app settings. Field names and JSON shape match the Tauri POC so
/// an existing settings.json carries over unchanged.
struct Settings: Codable, Equatable {
    var keyMode: KeyMode = .all
    /// Also treat F14/F15 as brightness keys (off by default: they collide
    /// with real F-key mappings on full-size keyboards).
    var legacyFKeys: Bool = false
    var hudPosition: HUDPosition = .top
    /// Held during a brightness key/scroll to temporarily flip the routing.
    var flipModifier: FlipModifier = .option
    /// Extend every slider below the hardware minimum with software (gamma)
    /// dimming — a too-bright panel can go darker at night.
    var subZero: Bool = false
    /// Stable UUIDs of displays Luma should leave alone.
    var excluded: [String] = []
    /// Cleared once the first-run welcome has been dismissed.
    var hasOnboarded: Bool = false

    // Tolerate missing fields from older versions of the file.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Per-field `try?`: one unknown enum case or bad value (e.g. a newer
        // Luma's HUDPosition) falls back to its default instead of failing the
        // whole decode and silently wiping every setting including exclusions.
        keyMode = (try? c.decode(KeyMode.self, forKey: .keyMode)) ?? .all
        legacyFKeys = (try? c.decode(Bool.self, forKey: .legacyFKeys)) ?? false
        hudPosition = (try? c.decode(HUDPosition.self, forKey: .hudPosition)) ?? .top
        flipModifier = (try? c.decode(FlipModifier.self, forKey: .flipModifier)) ?? .option
        subZero = (try? c.decode(Bool.self, forKey: .subZero)) ?? false
        excluded = (try? c.decode([String].self, forKey: .excluded)) ?? []
        hasOnboarded = (try? c.decode(Bool.self, forKey: .hasOnboarded)) ?? false
    }
}

enum ConfigFiles {
    private static var supportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// ~/Library/Application Support/Luma
    static var directory: URL {
        let dir = supportBase.appendingPathComponent("Luma", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var settings: URL { directory.appendingPathComponent("settings.json") }
    static var levels: URL { directory.appendingPathComponent("levels.json") }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil } // missing = normal
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Corrupt/unreadable: preserve it as .bad rather than let the next
            // save silently overwrite the user's real data.
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            Log.note("config: \(url.lastPathComponent) unreadable — moved to \(bad.lastPathComponent)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
