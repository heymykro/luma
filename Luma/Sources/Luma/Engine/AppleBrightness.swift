import CoreGraphics
import Darwin
import Foundation

/// Brightness for built-in panels and Apple externals (Studio Display,
/// Pro Display XDR, UltraFine) via the private DisplayServices framework.
///
/// Loaded at runtime with dlopen so a future macOS that removes a symbol
/// degrades this path to "unsupported" instead of killing the app at launch.
enum AppleBrightness {
    private typealias CanChangeFn = @convention(c) (UInt32) -> Bool
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private struct API {
        let canChange: CanChangeFn
        let get: GetFn
        let set: SetFn
    }

    private static let api: API? = {
        guard let lib = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ) else { return nil }
        guard let can = dlsym(lib, "DisplayServicesCanChangeBrightness"),
              let get = dlsym(lib, "DisplayServicesGetBrightness"),
              let set = dlsym(lib, "DisplayServicesSetBrightness")
        else { return nil }
        return API(
            canChange: unsafeBitCast(can, to: CanChangeFn.self),
            get: unsafeBitCast(get, to: GetFn.self),
            set: unsafeBitCast(set, to: SetFn.self)
        )
    }()

    static func canChange(_ id: CGDirectDisplayID) -> Bool {
        api?.canChange(id) ?? false
    }

    /// Current brightness 0...1, or nil if the call fails.
    static func get(_ id: CGDirectDisplayID) -> Float? {
        guard let api else { return nil }
        var value: Float = -1
        guard api.get(id, &value) == 0, value >= 0 else { return nil }
        return value
    }

    @discardableResult
    static func set(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let api else { return false }
        return api.set(id, min(max(value, 0), 1)) == 0
    }
}
