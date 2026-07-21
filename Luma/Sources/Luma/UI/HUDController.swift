import AppKit
import SwiftUI

/// The notch-style brightness pill: a click-through borderless window shown
/// on the display under the pointer whenever keys/knob/scroll change
/// brightness, auto-hidden after a beat.
final class HUDController {
    fileprivate final class Model: ObservableObject {
        @Published var value: Float = 0.5
        @Published var position: HUDPosition = .top
        @Published var bump = 0 // incremented to trigger an edge overshoot
        /// On a notched MacBook with the HUD at the top, the pill matches the
        /// notch's radius and sits flush — as if the notch itself extended.
        @Published var notch = false
    }
    private var lastValue: Float = -1

    /// The NSScreen backing a CGDirectDisplayID.
    private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    /// Width of the physical notch, or nil if this display doesn't have one.
    private static func notchWidth(_ screen: NSScreen) -> CGFloat? {
        guard screen.safeAreaInsets.top > 0 else { return nil }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let width = screen.frame.width - left - right
        return width > 40 ? width : nil
    }

    private static let horizontalSize = NSSize(width: 236, height: 46)
    private static let verticalSize = NSSize(width: 48, height: 200)

    private let store: Store
    private let model = Model()
    private let window: NSWindow

    init(store: Store) {
        self.store = store
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.horizontalSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .popUpMenu // floats above the menu bar for the notch look
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    /// Show/refresh the pill on the display under the pointer. Main thread.
    func show(value: Float) {
        let position = store.settings.get().hudPosition
        // Pushing past 0 or 100 (value clamped, unchanged) bumps the pill and
        // ticks the trackpad — the "you're at the end" cue.
        if value == lastValue, value <= 0.001 || value >= 0.999 {
            model.bump += 1
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        lastValue = value
        model.value = value
        model.position = position

        let wasVisible = window.isVisible
        if let id = DisplayManager.displayUnderMouse() {
            let screen = Self.screen(for: id)
            let notchW = position == .top ? screen.flatMap(Self.notchWidth) : nil
            model.notch = notchW != nil

            if let notchW, let screen {
                // Flush under the notch, matching its width — the pill reads as
                // the notch extending down. Slides in only on first appearance.
                let size = NSSize(width: max(notchW, 180), height: 38)
                let x = screen.frame.midX - size.width / 2
                let restY = screen.frame.maxY - size.height
                if wasVisible {
                    window.setFrame(NSRect(x: x, y: restY, width: size.width, height: size.height), display: true)
                } else {
                    window.setFrame(NSRect(x: x, y: screen.frame.maxY, width: size.width, height: size.height), display: false)
                    window.alphaValue = 1
                    window.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.24
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        window.animator().setFrame(
                            NSRect(x: x, y: restY, width: size.width, height: size.height), display: true)
                    }
                }
            } else {
                let bounds = DisplayManager.bounds(id)
                let size = position == .top ? Self.horizontalSize : Self.verticalSize
                // CG global coords are top-left origin; AppKit is bottom-left.
                let primaryHeight = DisplayManager.bounds(CGMainDisplayID()).height
                let cgOrigin: CGPoint
                switch position {
                case .top:
                    cgOrigin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 12)
                case .left:
                    cgOrigin = CGPoint(x: bounds.minX + 12, y: bounds.midY - size.height / 2)
                case .right:
                    cgOrigin = CGPoint(x: bounds.maxX - size.width - 12, y: bounds.midY - size.height / 2)
                }
                let appKitY = primaryHeight - (cgOrigin.y + size.height)
                window.setFrame(
                    NSRect(x: cgOrigin.x, y: appKitY, width: size.width, height: size.height),
                    display: true
                )
            }
        }

        window.alphaValue = 1
        window.orderFrontRegardless()

        // Auto-hide, generation-guarded so a new keypress cancels the fade.
        let gen = store.hudGen.withLock { g -> UInt64 in
            g += 1
            return g
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.store.hudGen.get() == gen else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.store.hudGen.get() == gen else { return }
                self.window.orderOut(nil)
            }
        }
    }
}

/// Notch-style pill: sun glyph, a slim fill gauge, and the live percentage.
/// Dark base + hairline border so it reads over any wallpaper.
private struct HUDView: View {
    @ObservedObject fileprivate var model: HUDController.Model

    private var percent: Int { Int((model.value * 100).rounded()) }

    fileprivate init(model: HUDController.Model) {
        self.model = model
    }

    var body: some View {
        Group {
            if model.position == .top {
                HStack(spacing: 12) {
                    sun
                    gauge(vertical: false)
                    Text("\(percent)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 11) {
                    Text("\(percent)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                    gauge(vertical: true)
                    sun
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 15)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(model.notch ? .black : .black.opacity(0.88)))
        .overlay(model.notch ? nil : AnyView(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)))
        .animation(.easeOut(duration: 0.15), value: model.value)
        // Edge overshoot: a springy squash-and-settle keyed on the bump count.
        .scaleEffect(model.bump % 2 == 0
            ? CGSize(width: 1, height: 1)
            : (model.position == .top ? CGSize(width: 0.96, height: 1) : CGSize(width: 1, height: 0.96)))
        .animation(.spring(response: 0.28, dampingFraction: 0.35), value: model.bump)
    }

    /// Capsule normally; square-topped with a notch-matching bottom radius
    /// when it's pretending to be the notch extending downward.
    private var shape: AnyShape {
        model.notch
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 20,
                                              bottomTrailingRadius: 20, topTrailingRadius: 0,
                                              style: .continuous))
            : AnyShape(Capsule())
    }

    private var sun: some View {
        Image(systemName: "sun.max.fill")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
    }

    /// A 7pt-thick rounded track with a white fill; grows left→right or
    /// bottom→top. Minimum length keeps the fill visible near 0%.
    private func gauge(vertical: Bool) -> some View {
        GeometryReader { geo in
            let full = vertical ? geo.size.height : geo.size.width
            let fill = max(7, full * CGFloat(model.value))
            ZStack(alignment: vertical ? .bottom : .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white)
                    .frame(width: vertical ? nil : fill, height: vertical ? fill : nil)
            }
        }
        .frame(width: vertical ? 7 : nil, height: vertical ? nil : 7)
    }
}
