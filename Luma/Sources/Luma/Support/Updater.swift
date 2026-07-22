import AppKit
import Foundation

/// Update checks against GitHub Releases. No Sparkle, no telemetry, no
/// background daemon: one request on launch (at most once a day) and one
/// whenever the user asks. An unsigned, non-App-Store app has no other way to
/// learn it is stale.
///
/// When something newer exists the release notes are shown inline, so nobody
/// has to open a browser to decide whether an update is worth taking.
enum Updater {
    private static let repo = "heymykro/luma"
    /// The release LIST, not /releases/latest. GitHub excludes anything flagged
    /// pre-release from that endpoint, so a single ticked checkbox on a future
    /// build would silently end update checks for everyone. Reading the list
    /// and picking the highest version can't be switched off by accident.
    private static let releasesAPI =
        URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!
    private static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!
    static let changelogPage = URL(string: "https://getluma.app/changelog")!

    private static let lastCheckKey = "luma.updater.lastCheck"
    private static let skippedKey = "luma.updater.skippedVersion"

    private struct Release {
        let version: String
        let notes: String
        let downloadURL: URL
    }

    // MARK: - Entry points

    /// User asked. Always reports something, including "you're up to date".
    static func checkNow() { check(silent: false) }

    /// Luma is a menu bar app people leave running for weeks, so a check that
    /// only ran at launch would never reach the users least likely to hear
    /// about a release any other way. The hourly tick is not the rate limit;
    /// the daily guard inside `checkIfDue` is. It just gives it a chance to
    /// fire, including after a wake from sleep.
    ///
    /// `.common` matters: a plain scheduled timer registers in `.default`
    /// only, which is suspended while a menu or a slider drag is tracking.
    static func startPeriodicChecks() {
        checkIfDue()
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { _ in checkIfDue() }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Silent unless there is genuinely something newer, and at most once a
    /// day so relaunching all morning doesn't hammer the API.
    static func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 60 * 60 * 24 else { return }
        // A beat after launch: the first seconds belong to the display scan.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { check(silent: true) }
    }

    // MARK: - Plumbing

    private static func check(silent: Bool) {
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, error in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            let release = data.flatMap(parse)
            DispatchQueue.main.async {
                present(release, failed: error != nil || release == nil, silent: silent)
            }
        }.resume()
    }

    /// Highest-versioned published release in the list. Drafts are skipped;
    /// pre-releases are not, since Luma ships betas as its normal channel.
    private static func parse(_ data: Data) -> Release? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return list
            .filter { ($0["draft"] as? Bool) != true }
            .compactMap { entry -> Release? in
                guard let tag = entry["tag_name"] as? String else { return nil }
                // Prefer the .dmg asset so Download lands on the installer
                // itself; fall back to the release page if naming changes.
                let assets = entry["assets"] as? [[String: Any]] ?? []
                let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
                let url = (dmg?["browser_download_url"] as? String)
                    .flatMap(URL.init(string:)) ?? releasesPage
                return Release(version: tag,
                               notes: (entry["body"] as? String) ?? "",
                               downloadURL: url)
            }
            .max { Version.isNewer($1.version, than: $0.version) }
    }

    private static func present(_ release: Release?, failed: Bool, silent: Bool) {
        let current = Diagnostics.appVersion
        guard let release, !failed else {
            if !silent { info("Couldn't reach GitHub to check for updates.") }
            return
        }
        guard Version.isNewer(release.version, than: current) else {
            if !silent { info("You're up to date.") }
            return
        }
        // On the launch check, respect a version the user already dismissed.
        if silent, UserDefaults.standard.string(forKey: skippedKey) == release.version { return }

        let alert = NSAlert()
        alert.messageText = "Luma \(Version.display(release.version)) is available"
        alert.informativeText = "You're on \(Version.display(current))."
        alert.accessoryView = notesView(release.notes)
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Full Changelog")
        alert.addButton(withTitle: silent ? "Skip This Version" : "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.downloadURL)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(changelogPage)
        default:
            if silent { UserDefaults.standard.set(release.version, forKey: skippedKey) }
        }
    }

    /// Release notes in a scrollable box. GitHub sends Markdown; this flattens
    /// the handful of marks Luma's notes actually use rather than pulling in a
    /// parser for an alert panel.
    private static func notesView(_ markdown: String) -> NSView {
        let size = NSSize(width: 380, height: 220)
        let text = NSTextView(frame: NSRect(origin: .zero, size: size))
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 5, height: 5)
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.string = plain(markdown)

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .lineBorder
        scroll.documentView = text
        return scroll
    }

    private static func info(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Luma \(Version.display(Diagnostics.appVersion))"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func plain(_ markdown: String) -> String {
        var out: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw
            if line.hasPrefix("### ") { line = String(line.dropFirst(4)).uppercased() }
            else if line.hasPrefix("## ") { line = String(line.dropFirst(3)).uppercased() }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            if line.hasPrefix("- ") { line = "  •" + line.dropFirst(1) }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
