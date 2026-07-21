import Foundation

/// Semver-ish comparison, only as much as Luma's release tags need:
/// `MAJOR.MINOR.PATCH` with an optional `-beta.N` suffix.
///
/// A plain string compare gets this wrong in the one place it matters most —
/// `"0.1.0"` vs `"0.1.0-beta.9"` — because the longer string looks bigger, so
/// shipping the first stable release would read as a downgrade and no beta
/// user would ever be offered it.
enum Version {
    /// Numeric release components, then the pre-release number.
    /// `nil` pre-release means a final build, which outranks any beta.
    private struct Parsed {
        let parts: [Int]
        let prerelease: Int?
    }

    private static func parse(_ raw: String) -> Parsed {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = halves[0].split(separator: ".").map { Int($0) ?? 0 }
        var prerelease: Int?
        if halves.count > 1 {
            // "beta.3" -> 3; a suffix with no number still counts as pre-release.
            let digits = halves[1].split(whereSeparator: { !$0.isNumber })
            prerelease = digits.last.flatMap { Int($0) } ?? 0
        }
        return Parsed(parts: parts, prerelease: prerelease)
    }

    /// True if `candidate` is a strictly newer release than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parse(candidate), b = parse(current)
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x > y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (nil, _): return true      // 0.1.0 beats 0.1.0-beta.9
        case (_, nil): return false
        case let (x?, y?): return x > y
        }
    }

    /// True when this build is a pre-release, so the UI can say so.
    static func isPrerelease(_ raw: String) -> Bool { parse(raw).prerelease != nil }

    /// "0.1.0-beta.1" -> "0.1.0 beta 1", for display.
    static func display(_ raw: String) -> String {
        let p = parse(raw)
        let core = p.parts.map(String.init).joined(separator: ".")
        guard let pre = p.prerelease else { return core }
        return "\(core) beta \(pre)"
    }
}
