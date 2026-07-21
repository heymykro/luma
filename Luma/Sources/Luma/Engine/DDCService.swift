import CoreGraphics
import Darwin
import Foundation
import IOKit

/// DDC/CI over I2C for non-Apple external monitors on Apple Silicon, using the
/// private IOAVService API.
///
/// One `DDCService` wraps one monitor's IOAVService handle. Handles go stale
/// after sleep/wake or replug; `DDCWorker` rebuilds them when writes fail.
final class DDCService {
    static let brightnessVCP: UInt8 = 0x10

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias WriteFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias ReadFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private struct API {
        let create: CreateFn
        let write: WriteFn
        let read: ReadFn
    }

    /// IOAVService* symbols live in CoreDisplay; make sure it's loaded, then
    /// resolve dynamically so we never hard-link a private framework.
    private static let api: API? = {
        dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        guard let create = dlsym(dlopen(nil, RTLD_LAZY), "IOAVServiceCreateWithService"),
              let write = dlsym(dlopen(nil, RTLD_LAZY), "IOAVServiceWriteI2C"),
              let read = dlsym(dlopen(nil, RTLD_LAZY), "IOAVServiceReadI2C")
        else { return nil }
        return API(
            create: unsafeBitCast(create, to: CreateFn.self),
            write: unsafeBitCast(write, to: WriteFn.self),
            read: unsafeBitCast(read, to: ReadFn.self)
        )
    }()

    let displayID: CGDirectDisplayID
    private let service: AnyObject
    /// I2C slave address. 0x37 for the usual DisplayPort path; 0xB7 for
    /// Apple Silicon built-in HDMI routed through the MCDP29xx DP->HDMI
    /// bridge.
    private let chipAddress: UInt32

    private init(displayID: CGDirectDisplayID, service: AnyObject, chipAddress: UInt32) {
        self.displayID = displayID
        self.service = service
        self.chipAddress = chipAddress
    }

    /// EDID identity of the panel attached to a port, as published by that
    /// port's framebuffer. Compared against the CGDisplay* identity numbers.
    private struct PanelID: Equatable {
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
    }

    /// One unmatched External IOAVService: the handle, its chip address, and
    /// the identity of whatever panel is plugged into that port (nil if the
    /// framebuffer publishes none). Paired to a display in `enumerate`.
    private struct Candidate {
        let service: AnyObject
        let chipAddress: UInt32
        let panel: PanelID?
    }

    // MARK: - Enumeration

    /// All external DCPAVServiceProxy handles, matched to the given
    /// CGDisplayIDs by the EDID identity of the panel on each port.
    ///
    /// Getting this right matters more than it looks: the External proxies
    /// include ports driving Apple displays (a Studio Display is an external
    /// monitor), which never appear in `displayIDs`. Pairing by iteration
    /// order therefore hands a non-Apple display someone else's I2C bus — DDC
    /// writes land on the wrong monitor and reads come back as garbage.
    static func enumerate(displayIDs: [CGDirectDisplayID]) -> [DDCService] {
        guard let api else { return [] }

        let panels = panelIDsByPort()
        var candidates: [Candidate] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard property(entry, "Location") as? String == "External",
                  let av = api.create(kCFAllocatorDefault, entry)?.takeRetainedValue()
            else { continue }
            candidates.append(Candidate(
                service: av,
                chipAddress: chipAddress(for: entry),
                panel: portToken(entry).flatMap { panels[$0] }
            ))
        }

        var out: [DDCService] = []
        var remainingDisplays = displayIDs
        var unmatched: [Candidate] = []

        func pair(_ candidate: Candidate, _ index: Int) {
            let id = remainingDisplays.remove(at: index)
            out.append(DDCService(displayID: id, service: candidate.service,
                                  chipAddress: candidate.chipAddress))
        }
        func identity(_ id: CGDirectDisplayID) -> PanelID {
            PanelID(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id))
        }

        // Pass 1: full EDID identity. Distinguishes two of the same model as
        // long as they report distinct serials.
        // ponytail: two identical panels that both report serial 0 pair in
        // iteration order and can end up swapped. Scoring the framebuffer's
        // IODisplayLocation against the display's would settle it; add that if
        // the setup ever turns up.
        for candidate in candidates {
            if let panel = candidate.panel,
               let idx = remainingDisplays.firstIndex(where: { identity($0) == panel }) {
                pair(candidate, idx)
            } else {
                unmatched.append(candidate)
            }
        }
        // Pass 2: vendor + model. Some panels report a serial on one side only.
        var anonymous: [Candidate] = []
        for candidate in unmatched {
            guard let panel = candidate.panel else { anonymous.append(candidate); continue }
            if let idx = remainingDisplays.firstIndex(where: {
                CGDisplayVendorNumber($0) == panel.vendor && CGDisplayModelNumber($0) == panel.model
            }) {
                pair(candidate, idx)
            }
            // else: this port drives a display we were not asked about (an
            // Apple external, or one excluded upstream). Dropping it is the
            // whole point — never let it soak up an unrelated display below.
        }
        // Pass 3: ports whose framebuffer publishes no identity at all.
        // ponytail: ordering, which is arbitrary but no worse than the
        // alternatives once there's nothing left to match on.
        for (candidate, id) in zip(anonymous, remainingDisplays) {
            out.append(DDCService(displayID: id, service: candidate.service,
                                  chipAddress: candidate.chipAddress))
        }
        return out
    }

    /// Port token -> panel identity, for every framebuffer publishing one.
    private static func panelIDsByPort() -> [String: PanelID] {
        var out: [String: PanelID] = [:]
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator
        ) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let token = portToken(entry),
                  let attributes = property(entry, "DisplayAttributes") as? [String: Any],
                  let product = attributes["ProductAttributes"] as? [String: Any],
                  let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                  let model = (product["ProductID"] as? NSNumber)?.uint32Value
            else { continue }
            out[token] = PanelID(
                vendor: vendor, model: model,
                serial: (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0
            )
        }
        return out
    }

    /// The display-port token in an IORegistry path (`dispext0`, `disp0`).
    /// The AV proxy sits at `dispext0:dcpav-service-epic:0` and the
    /// framebuffer at `dispext0@B0000000` — same port, so this pairs them.
    private static func portToken(_ entry: io_object_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2048)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS
        else { return nil }
        return String(cString: buffer).split(separator: "/")
            .last { $0.hasPrefix("disp") }
            .map { String($0.prefix { $0 != ":" && $0 != "@" }) }
    }

    private static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    /// 0xB7 if the proxy's provider is the MCDP29xx DP->HDMI bridge (built-in
    /// HDMI on some Apple Silicon Macs), else the standard 0x37.
    private static func chipAddress(for entry: io_object_t) -> UInt32 {
        var parent = io_object_t()
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
        else { return 0x37 }
        defer { IOObjectRelease(parent) }
        return (property(parent, "EPICProviderClass") as? String) == "AppleDCPMCDP29XX"
            ? 0xB7 : 0x37
    }

    // MARK: - DDC/CI transport (source address 0x51, XOR checksum)

    /// DDC source (host) address, sent as the I2C sub-address on writes.
    private static let sourceAddress: UInt32 = 0x51
    /// Destination byte of the DDC frame: the 7-bit chip address, shifted.
    /// 0x37 and 0xB7 both land on 0x6E.
    private var destination: UInt8 { UInt8((chipAddress << 1) & 0xFF) }

    /// Frame `payload`, append the XOR checksum, and put it on the bus.
    ///
    /// The checksum covers the destination and source addresses too, but both
    /// travel out of band (I2C address + sub-address), so they are folded in
    /// as `seed` instead. A read request omits the source byte from that
    /// seed while a write includes it; monitors that validate the request
    /// checksum reject the frame otherwise.
    private func send(_ payload: [UInt8], seed: UInt8) -> Bool {
        guard let api = Self.api else { return false }
        var packet = payload
        var checksum = seed
        for byte in packet { checksum ^= byte }
        packet.append(checksum)
        // Written twice: monitors drop the first packet often enough to
        // matter, and I2C ACKs it regardless, so an error-triggered retry can
        // never see the miss.
        var ok = false
        for _ in 0..<2 {
            usleep(10_000)
            ok = packet.withUnsafeMutableBytes { buf in
                api.write(service, chipAddress, Self.sourceAddress,
                          buf.baseAddress!, UInt32(buf.count)) == KERN_SUCCESS
            }
        }
        return ok
    }

    /// Set VCP feature (0x03). Retried by the caller; one attempt here.
    func setVCP(_ code: UInt8, value: UInt16) -> Bool {
        send([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)],
             seed: destination ^ UInt8(Self.sourceAddress))
    }

    /// Get VCP feature (0x01) -> (current, max). Single attempt; ~30% of raw
    /// reads fail on Apple Silicon I2C, so the caller retries.
    func getVCP(_ code: UInt8) -> (value: UInt16, max: UInt16)? {
        guard let api = Self.api, send([0x82, 0x01, code], seed: destination) else { return nil }
        usleep(40_000) // give the monitor time to stage the reply
        var reply = [UInt8](repeating: 0, count: 11)
        // Reads pass offset 0, NOT the 0x51 sub-address used for writes:
        // passing 0x51 here returns garbage from every monitor.
        let ok = reply.withUnsafeMutableBytes { buf in
            api.read(service, chipAddress, 0, buf.baseAddress!, UInt32(buf.count)) == KERN_SUCCESS
        }
        guard ok, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }
        var checksum: UInt8 = 0x50
        for byte in reply[0..<10] { checksum ^= byte }
        guard checksum == reply[10] else { return nil }
        let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return (min(current, Swift.max(maxValue, 1)), Swift.max(maxValue, 1))
    }
}
