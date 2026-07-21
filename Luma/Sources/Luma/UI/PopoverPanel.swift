import AppKit
import SwiftUI

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

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: PopoverView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    /// Toggle below the status item button.
    func toggle(relativeTo button: NSStatusBarButton) {
        if isVisible {
            close()
            return
        }
        sizeToFitContent()
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

    private func sizeToFitContent() {
        contentView?.layoutSubtreeIfNeeded()
        if let size = contentView?.fittingSize, size.height > 0 {
            setContentSize(size)
        }
    }
}
