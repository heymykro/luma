import ApplicationServices
import Foundation

enum Accessibility {
    static var trusted: Bool {
        AXIsProcessTrusted()
    }

    /// Check trust, showing the system Accessibility prompt if not granted.
    @discardableResult
    static func prompt() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [url]
        try? task.run()
    }
}
