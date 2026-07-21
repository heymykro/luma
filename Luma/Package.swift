// swift-tools-version: 5.9
// Luma — menu bar brightness for every display.
// SPM keeps the project text-based and diff-friendly; `make app` in this
// directory assembles the signed .app bundle. Xcode users: `open Package.swift`.
import PackageDescription

let package = Package(
    name: "Luma",
    platforms: [.macOS(.v13)],
    targets: [
        // Resources (icon, tray PNGs, Info.plist) are copied into the .app by
        // the Makefile and loaded via Bundle.main, so the target itself ships
        // no SPM resource bundle.
        .executableTarget(name: "Luma", path: "Sources/Luma")
    ]
)
