import AppKit
import SwiftUI

/// HUD-material vibrancy as a SwiftUI background, so the whole popover can be a
/// single SwiftUI view hosted by a controller that auto-sizes the window.
/// That is what lets the warmth card animate its height: AppKit resizes the
/// window in the same layout pass SwiftUI lays out, instead of a manual resize
/// running a frame behind (which is what made every earlier attempt jump).
struct HUDBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 22
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The tray popover: a non-activating panel (never steals focus from the app
/// you're in — the reason this isn't an NSPopover) with HUD-material
/// vibrancy, shown under the status item, hidden on any outside click.
final class PopoverPanel: NSPanel {
    private var clickMonitor: Any?
    private var refreshTimer: Timer?
    /// Fired ~4x/sec while the panel is open so the sliders track brightness
    /// changed by anything (keys, knob, Control Center, auto-brightness) —
    /// the same live-mirror trick macOS Control Center uses.
    var onTick: (() -> Void)?

    init(model: AppModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The popover is a deliberately dark, HUD-material surface; pin dark
        // appearance so the white-on-vibrancy design stays legible even when
        // the system is in light mode.
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true

        // A hosting controller (not a hosting view) so the window follows the
        // SwiftUI content's size automatically, animation frames included.
        let controller = NSHostingController(
            rootView: PopoverView(model: model)
                .background(HUDBackground())
        )
        controller.sizingOptions = [.preferredContentSize]
        contentViewController = controller
    }

    /// Hold the top edge when the window sizes to its content on open, so the
    /// popover hangs from the menu bar rather than being centred on its origin.
    override func setContentSize(_ size: NSSize) {
        let top = frame.maxY
        super.setContentSize(size)
        setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top))
    }

    /// Toggle below the status item button.
    func toggle(relativeTo button: NSStatusBarButton) {
        if isVisible {
            close()
            return
        }
        layoutIfNeeded()
        if let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let size = frame.size
            var x = buttonFrame.midX - size.width / 2
            if let screen = buttonWindow.screen {
                x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
            }
            setFrameTopLeftPoint(NSPoint(x: x, y: buttonFrame.minY - 6))
        }
        orderFrontRegardless()

        // Live-mirror brightness while open.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.onTick?() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        // Hide on any click outside the panel (the panel never becomes main,
        // so there is no resign notification to lean on).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.close()
        }
    }

    override func close() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        orderOut(nil)
    }
}
