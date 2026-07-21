import AppKit
import Foundation

enum Diagnostics {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Human-readable state dump for bug reports; copied to the clipboard
    /// from the tray menu. Contains no identifying information.
    static func text(store: Store) -> String {
        let settings = store.settings.get()
        let macos = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif

        var out = """
        Luma \(appVersion) diagnostics
        macOS \(macos) (\(arch))
        Accessibility: \(Accessibility.trusted ? "granted" : "not granted")
        Paused: \(store.paused.get())

        Displays:

        """
        for d in store.displays.get() {
            let vendor = String(DisplayManager.vendor(d.id), radix: 16)
            out += "- id=\(d.id) \"\(d.name)\" backend=\(d.backend.rawValue) vendor=0x\(vendor)"
            out += " builtin=\(d.builtin) brightness=\(String(format: "%.2f", d.brightness))"
            out += " excluded=\(d.excluded)\(d.writeFailed ? " WRITE-FAILED" : "") uuid=\(d.uuid ?? "?")\n"
        }
        out += "\nSettings: keys=\(settings.keyMode.rawValue) hud=\(settings.hudPosition.rawValue)"
        out += " legacyFKeys=\(settings.legacyFKeys) flip=\(settings.flipModifier.rawValue)\n"

        let log = Log.recent()
        if !log.isEmpty {
            out += "\nRecent activity (\(log.count)):\n" + log.joined(separator: "\n") + "\n"
        }
        return out
    }

    static func copyToClipboard(store: Store) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text(store: store), forType: .string)
    }
}
