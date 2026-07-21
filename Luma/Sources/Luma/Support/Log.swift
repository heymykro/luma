import Foundation

/// os_unfair_lock behind a stable heap allocation. Taking `&lock` on a stored
/// property is technically UB (Swift's exclusivity may copy it), so the lock
/// lives at a fixed address for its whole lifetime.
final class UnfairLock: @unchecked Sendable {
    private let ptr: UnsafeMutablePointer<os_unfair_lock>
    init() { ptr = .allocate(capacity: 1); ptr.initialize(to: os_unfair_lock()) }
    deinit { ptr.deinitialize(count: 1); ptr.deallocate() }
    func lock() { os_unfair_lock_lock(ptr) }
    func unlock() { os_unfair_lock_unlock(ptr) }
    @discardableResult
    func sync<R>(_ body: () -> R) -> R { lock(); defer { unlock() }; return body() }
}

/// A 256-entry in-memory ring log surfaced in Copy Diagnostics. The app had a
/// handful of NSLog lines and a dozen silent failure modes; this makes them
/// visible in bug reports with no file I/O and no telemetry.
enum Log {
    private static let capacity = 256
    private static var ring = [String?](repeating: nil, count: capacity)
    private static var count = 0
    private static let lock = UnfairLock()
    private static let start = DispatchTime.now().uptimeNanoseconds

    static func note(_ message: @autoclosure () -> String) {
        // Read `start` FIRST: it's a lazy static, so touching it after
        // DispatchTime.now() initializes it to a *later* value and the UInt64
        // subtraction underflows — which Swift traps on. (This crashed the app
        // on the first log line after Accessibility was granted.)
        let origin = start
        let now = DispatchTime.now().uptimeNanoseconds
        let secs = now > origin ? Double(now - origin) / 1_000_000_000 : 0
        let line = String(format: "%9.2f  %@", secs, message())
        lock.sync {
            ring[count % capacity] = line
            count += 1
        }
        #if DEBUG
        NSLog("[luma] %@", line)
        #endif
    }

    /// Oldest-first, for the diagnostics dump.
    static func recent() -> [String] {
        lock.sync {
            let n = min(count, capacity)
            let base = count > capacity ? count : 0
            return (0..<n).compactMap { ring[(base + $0) % capacity] }
        }
    }
}
