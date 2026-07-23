import AppKit
import CoreGraphics
import os

/// The live menu bar mark: a half-sun on a horizon whose ray count tracks
/// brightness (3 rays dim → 7 bright). At 0% the sun sets and a moon rises;
/// paused shows a bare half-disc. Drawn as a template so macOS tints it for
/// light/dark menu bars. StatusItemController animates ray count between the
/// discrete states; the settled states are cached.
enum TrayIcon {
    enum Mode: Equatable { case sun, moon, bare }

    private static let S = 44
    private static let discR: CGFloat = 9
    private static let horizon: CGFloat = 15
    /// Gap between the sun's flat base and the horizon line. Without it the
    /// sun sits directly on the line and the two read as one shape.
    private static let sunGap: CGFloat = 2
    private static let cx = CGFloat(44) / 2
    private static let black = CGColor(gray: 0, alpha: 1)

    /// The settled state for a given brightness / pause.
    static func state(brightness: Float, paused: Bool) -> (rays: Float, mode: Mode) {
        if paused { return (0, .bare) }
        if brightness <= 0.01 { return (0, .moon) } // blacked out: the sun has set
        return (Float(min(7, max(3, 3 + Int((Double(brightness) * 4).rounded())))), .sun)
    }

    // Settled (integer-ray) states are cached; animation frames render live.
    private static var cache: [String: NSImage] = [:]
    private static let cacheLock = OSAllocatedUnfairLock()

    /// A settled, cached image.
    static func image(brightness: Float, paused: Bool) -> NSImage {
        let (rays, mode) = state(brightness: brightness, paused: paused)
        let key = "\(mode)-\(Int(rays))"
        return cacheLock.withLockUnchecked {
            if let img = cache[key] { return img }
            let img = wrap(render(rayFloat: rays, mode: mode, sweep: nil))
            cache[key] = img
            return img
        }
    }

    /// The full fan — what the sunrise sweeps out to before settling.
    static let maxRays: Float = 7

    /// A transient animation frame (fractional rays), not cached.
    /// `sweep` (0…1) instead draws the full fan revealed left→right, for the
    /// first-light animation.
    static func frame(rayFloat: Float, mode: Mode, sweep: Float? = nil) -> NSImage {
        wrap(render(rayFloat: rayFloat, mode: mode, sweep: sweep))
    }

    private static func wrap(_ cg: CGImage) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: 22, height: 22) // 44px asset in a 22pt slot
        let img = NSImage(size: NSSize(width: 22, height: 22))
        img.addRepresentation(rep)
        img.isTemplate = true
        return img
    }

    private static func render(rayFloat: Float, mode: Mode, sweep: Float? = nil) -> CGImage {
        let c = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setLineCap(.round)
        let baseY = horizon + sunGap

        // clip to the sun's own baseline so neither the disc nor the rays
        // spill into the gap above the horizon line
        c.saveGState()
        c.addRect(CGRect(x: 0, y: baseY, width: CGFloat(S), height: CGFloat(S) - baseY))
        c.clip()

        if mode == .moon {
            // crescent: full disc minus an offset disc
            c.addEllipse(in: CGRect(x: cx - discR, y: baseY - discR * 0.15, width: discR * 2, height: discR * 2))
            c.setFillColor(black); c.fillPath()
            c.setBlendMode(.clear)
            c.addEllipse(in: CGRect(x: cx - discR + discR * 0.5, y: baseY - discR * 0.15 + discR * 0.45,
                                    width: discR * 2, height: discR * 2))
            c.fillPath()
            c.setBlendMode(.normal)
        } else {
            // filled semicircle sitting on the horizon
            let disc = CGMutablePath()
            disc.move(to: CGPoint(x: cx - discR, y: baseY))
            disc.addArc(center: CGPoint(x: cx, y: baseY), radius: discR, startAngle: .pi, endAngle: 0, clockwise: true)
            disc.closeSubpath()
            c.addPath(disc); c.setFillColor(black); c.fillPath()

            // Rays divide the semicircle evenly. Normally the outermost
            // fades/grows on fractional counts so transitions tick smoothly;
            // during a sweep the full fan is revealed left→right instead.
            let n = sweep != nil ? Int(Self.maxRays) : Int(ceil(rayFloat))
            if n > 0 {
                let denom = CGFloat(n + 1)
                let r0 = discR + 2.5, span = CGFloat(6)
                for i in 1...n {
                    let a = .pi * CGFloat(i) / denom
                    let frac: CGFloat
                    if let sweep {
                        // i == 1 is the RIGHT-most arm (angle ~0), i == n the
                        // left-most — so count position from the left.
                        let fromLeft = CGFloat(n + 1 - i)
                        frac = max(0, min(1, CGFloat(sweep) * CGFloat(n) - (fromLeft - 1)))
                    } else {
                        frac = (i == n) ? CGFloat(rayFloat - Float(n - 1)) : 1
                    }
                    guard frac > 0 else { continue }
                    let r1 = r0 + span * max(0, min(1, frac))
                    c.setStrokeColor(CGColor(gray: 0, alpha: max(0, min(1, frac * 1.4))))
                    c.setLineWidth(2.1)
                    c.move(to: CGPoint(x: cx + cos(a) * r0, y: baseY + sin(a) * r0))
                    c.addLine(to: CGPoint(x: cx + cos(a) * r1, y: baseY + sin(a) * r1))
                    c.strokePath()
                }
            }
        }
        c.restoreGState()

        // horizon line (the land / the outer two arms)
        c.move(to: CGPoint(x: 6, y: horizon)); c.addLine(to: CGPoint(x: CGFloat(S) - 6, y: horizon))
        c.setStrokeColor(black); c.setLineWidth(2.1); c.strokePath()
        return c.makeImage()!
    }
}
