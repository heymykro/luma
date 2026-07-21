import CoreGraphics
import Foundation

/// All DDC I2C traffic runs on this one thread. Bursts of writes coalesce
/// last-value-wins per display with >= 50ms between hardware writes (slider
/// drags and key repeats arrive far faster than monitors accept them).
///
/// Faithful port of the Tauri version's worker: a refresh keeps pending
/// writes (they re-apply against fresh handles), a failed write sets a heal
/// flag, and the next pass rebuilds handles once before retrying.
final class DDCWorker {
    private enum Message {
        case refresh(ids: [CGDirectDisplayID], reply: ([CGDirectDisplayID: Float?]) -> Void)
        case set(CGDirectDisplayID, Float)
    }

    private let condition = NSCondition()
    private var queue: [Message] = []
    private var monitors: [CGDirectDisplayID: (service: DDCService, max: UInt16)] = [:]

    private static let writeSpacing: TimeInterval = 0.05
    /// A value is retried across heal-rebuilds up to this many passes before we
    /// give up (a truly dead monitor / DDC-off panel must not spin the loop).
    private static let maxWriteTries = 3

    /// Fired on the worker thread after each write attempt resolves: true =
    /// the monitor took the value, false = gave up. Lets the controller keep
    /// its cache/saved-levels honest instead of trusting fire-and-forget.
    var onWriteResult: ((CGDirectDisplayID, Bool) -> Void)?

    init() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "ddc-worker"
        thread.qualityOfService = .utility // slow I2C busywork shouldn't run at default priority
        thread.start()
    }

    /// Re-enumerate monitors for `ids` and read brightness. The reply maps
    /// id -> 0...1, or nil for monitors that enumerate but won't answer reads
    /// (write-only panels): those stay controllable assuming MCCS max 100.
    func refresh(ids: [CGDirectDisplayID], reply: @escaping ([CGDirectDisplayID: Float?]) -> Void) {
        send(.refresh(ids: ids, reply: reply))
    }

    /// Synchronous refresh with timeout, for the display-rescan path.
    func refreshSync(ids: [CGDirectDisplayID], timeout: TimeInterval = 10) -> [CGDirectDisplayID: Float?] {
        let semaphore = DispatchSemaphore(value: 0)
        // Boxed so a reply arriving after the timeout can't race the read below.
        let box = Locked<[CGDirectDisplayID: Float?]>([:])
        refresh(ids: ids) { levels in
            box.set(levels)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return box.get()
    }

    func set(_ id: CGDirectDisplayID, _ value: Float) {
        send(.set(id, value))
    }

    private func send(_ message: Message) {
        condition.lock()
        queue.append(message)
        condition.signal()
        condition.unlock()
    }

    // MARK: - Worker loop

    /// Monotonic seconds since boot — immune to wall-clock steps (NTP, manual
    /// changes) the way engine.rs's Instant is. Wall time is only ever used to
    /// convert a remaining interval into an NSCondition deadline.
    private static func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func run() {
        // value + how many passes it has survived (a new value resets tries).
        var pending: [CGDirectDisplayID: (value: Float, tries: Int)] = [:]
        var heal = false
        var lastWrite = -Self.writeSpacing // allow the first write immediately

        while true {
            // Block if idle; while writes are pending, wait only until the
            // spacing window elapses so bursts coalesce last-value-wins.
            condition.lock()
            if pending.isEmpty {
                while queue.isEmpty { condition.wait() }
            } else {
                var remaining = Self.writeSpacing - (Self.now() - lastWrite)
                while queue.isEmpty, remaining > 0 {
                    condition.wait(until: Date().addingTimeInterval(remaining))
                    remaining = Self.writeSpacing - (Self.now() - lastWrite)
                }
            }
            let batch = queue
            queue.removeAll()
            condition.unlock()

            for message in batch {
                switch message {
                case .refresh(let ids, let reply):
                    reply(rebuild(ids: ids))
                    heal = false // a refresh IS the heal
                case .set(let id, let value):
                    pending[id] = (value, 0) // fresh value: reset the retry count
                }
            }

            guard !pending.isEmpty, Self.now() - lastWrite >= Self.writeSpacing else {
                continue
            }
            if heal {
                // Stale handles (sleep/wake without a reconfigure callback)
                // fail writes — rebuild once, then retry the pending values.
                Log.note("ddc: healing stale handles")
                _ = rebuild(ids: Array(monitors.keys))
                heal = false
            }
            // Retry-preserving: a failed value STAYS pending (and triggers a
            // heal-rebuild before the next pass) until it lands or we give up,
            // instead of being silently dropped — which used to eat the first
            // adjustment after wake.
            var stillPending: [CGDirectDisplayID: (value: Float, tries: Int)] = [:]
            for (id, item) in pending {
                // Display went away between the queue and here (unplug mid-drag).
                // Drop it silently: reporting success would persist a level the
                // panel never took, and failure would flag a display that's gone.
                guard monitors[id] != nil else { continue }
                if apply(id: id, value: item.value) {
                    onWriteResult?(id, true)
                } else if item.tries + 1 >= Self.maxWriteTries {
                    Log.note("ddc: gave up on display \(id) after \(Self.maxWriteTries) tries")
                    onWriteResult?(id, false)
                } else {
                    stillPending[id] = (item.value, item.tries + 1)
                    heal = true
                }
            }
            pending = stillPending
            lastWrite = Self.now()
        }
    }

    private func rebuild(ids: [CGDirectDisplayID]) -> [CGDirectDisplayID: Float?] {
        monitors.removeAll()
        var out: [CGDirectDisplayID: Float?] = [:]
        for service in DDCService.enumerate(displayIDs: ids) {
            if let reading = readWithRetries(service) {
                out[service.displayID] = Float(reading.value) / Float(reading.max)
                monitors[service.displayID] = (service, reading.max)
            } else {
                out[service.displayID] = Float?.none
                monitors[service.displayID] = (service, 100)
            }
        }
        return out
    }

    private func readWithRetries(_ service: DDCService) -> (value: UInt16, max: UInt16)? {
        for attempt in 0..<4 {
            if attempt > 0 { usleep(30_000) }
            if let reading = service.getVCP(DDCService.brightnessVCP) { return reading }
        }
        return nil
    }

    private func apply(id: CGDirectDisplayID, value: Float) -> Bool {
        guard let (service, maxValue) = monitors[id] else { return false }
        let raw = UInt16((min(max(value, 0), 1) * Float(maxValue)).rounded())
        for attempt in 0..<3 {
            if attempt > 0 { usleep(20_000) }
            if service.setVCP(DDCService.brightnessVCP, value: raw) { return true }
        }
        return false
    }
}
