import SwiftUI

/// Main-actor mirror of the Store for SwiftUI. The engine mutates the Store
/// from its own threads; `refresh()` re-reads it (wired to Store.onChange).
final class AppModel: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var settings = Settings()
    @Published var axTrusted = true
    @Published var launchAtLogin = false

    fileprivate(set) var controller: BrightnessController?
    private let store: Store
    /// Called after a popover-initiated brightness change so the menu bar
    /// icon can redraw (the engine paths go through Store.onChange instead).
    var onAdjust: (() -> Void)?

    init(store: Store, controller: BrightnessController?) {
        self.store = store
        self.controller = controller
        refresh()
    }

    func refresh() {
        displays = store.displays.get()
        settings = store.settings.get()
    }

    /// Non-excluded, controllable displays (what sliders and keys touch).
    var active: [DisplayInfo] { displays.filter { !$0.excluded && $0.backend != .none } }

    var masterValue: Float {
        active.isEmpty ? 0 : active.map(\.brightness).reduce(0, +) / Float(active.count)
    }

    func setBrightness(id: CGDirectDisplayID, value: Float) {
        controller?.apply(id: id, value: value)
        if let i = displays.firstIndex(where: { $0.id == id }) {
            displays[i].brightness = value
        }
        onAdjust?()
    }

    func setAll(value: Float) {
        for display in active { setBrightness(id: display.id, value: value) }
    }

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        var copy = settings
        mutate(&copy)
        // Exclusions are tray-owned; never let the popover revert them.
        copy.excluded = store.settings.get().excluded
        store.updateSettings(copy)
    }

    /// Sub-zero changes the slider→hardware mapping, so re-apply live levels.
    func setSubZero(_ on: Bool) {
        updateSettings { $0.subZero = on }
        controller?.reapplyAllLevels()
    }

    // MARK: - Settings menu

    var versionDisplay: String { Version.display(Diagnostics.appVersion) }
    var isPrerelease: Bool { Version.isPrerelease(Diagnostics.appVersion) }

    var profileNames: [String] { ProfileStore.load().names }

    func applyProfile(_ name: String) {
        controller?.applyProfile(name)
        refresh()
    }

    func refreshDisplays() { controller?.scheduleRescan() }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.text(store: store), forType: .string)
    }

    /// Name prompt for a new profile. Mirrors the tray menu's dialog so both
    /// entry points behave identically.
    func saveProfileDialog() {
        let alert = NSAlert()
        alert.messageText = "Save Profile"
        alert.informativeText = "Name this set of brightness levels."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Day"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        controller?.saveProfile(name)
        objectWillChange.send()
    }
}

/// Outward links used by the settings menu and the footer.
enum AppLinks {
    static let site = URL(string: "https://getluma.app")!
    static let issues = URL(string: "https://github.com/heymykro/luma/issues/new")!
}

extension Color {
    static let warm = Color(red: 1.0, green: 0.62, blue: 0.12)     // #FF9D1F brand
    static let warmHot = Color(red: 1.0, green: 0.80, blue: 0.42)
    static let inkOnWarm = Color(red: 0.16, green: 0.08, blue: 0.0)
}

/// Premium Control Center-style popover: brand header, grouped cards,
/// warm-accented segmented controls, refined sliders.
struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.settings.hasOnboarded { welcome }
            if !model.axTrusted { axBanner }

            card {
                if model.active.count > 1 {
                    sliderRow(icon: "square.grid.2x2.fill", label: "All Displays",
                              value: model.masterValue, bold: true) { model.setAll(value: $0) }
                    divider
                }
                if model.active.isEmpty { emptyState }
                ForEach(model.active) { display in
                    sliderRow(icon: display.builtin ? "laptopcomputer" : "display",
                              label: display.name, value: display.brightness) {
                        model.setBrightness(id: display.id, value: $0)
                    }
                }
            }

            card {
                labeledSegment("KEYS ADJUST", selection: model.settings.keyMode,
                    options: [(KeyMode.all, "All Displays"), (.underMouse, "Under Pointer")]) { mode in
                        model.updateSettings { $0.keyMode = mode } }
                labeledSegment("HUD POSITION", selection: model.settings.hudPosition,
                    options: [(HUDPosition.top, "Top"), (.left, "Left"), (.right, "Right")]) { pos in
                        model.updateSettings { $0.hudPosition = pos } }
                labeledSegment("HOLD TO FLIP ROUTING", selection: model.settings.flipModifier,
                    options: FlipModifier.allCases.map { ($0, $0.symbol) }) { mod in
                        model.updateSettings { $0.flipModifier = mod } }
            }

            card {
                toggleRow("Dim below minimum", isOn: Binding(
                    get: { model.settings.subZero },
                    set: { on in model.setSubZero(on) }))
                divider
                toggleRow("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { LaunchAtLogin.set(enabled: $0); model.launchAtLogin = $0 }))
                divider
                toggleRow("F14 / F15 as brightness keys", isOn: Binding(
                    get: { model.settings.legacyFKeys },
                    set: { on in model.updateSettings { $0.legacyFKeys = on } }))
            }

            footer
        }
        .padding(15)
        .frame(width: 320)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.horizon.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.warmHot, .warm], startPoint: .top, endPoint: .bottom))
            Text("Luma").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            if model.isPrerelease {
                Text("BETA")
                    .font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(Color.inkOnWarm)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.warm))
            }
            Spacer()
            Text("\(model.displays.count) display\(model.displays.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            settingsMenu
        }
        .padding(.horizontal, 2)
    }

    /// Everything that doesn't earn a permanent row in the panel: profiles,
    /// maintenance, links, quit. Keeps the popover about brightness while
    /// still making the rest reachable without hunting for a right-click.
    private var settingsMenu: some View {
        Menu {
            Section("Profiles") {
                ForEach(model.profileNames, id: \.self) { name in
                    Button(name) { model.applyProfile(name) }
                }
                Button("Save Current as Profile…") { model.saveProfileDialog() }
            }
            Divider()
            Button("Refresh Displays") { model.refreshDisplays() }
            Button("Copy Diagnostics") { model.copyDiagnostics() }
            Divider()
            Button("Check for Updates…") { Updater.checkNow() }
            Button("What's New") { NSWorkspace.shared.open(Updater.changelogPage) }
            Button("Luma Website") { NSWorkspace.shared.open(AppLinks.site) }
            Button("Report an Issue") { NSWorkspace.shared.open(AppLinks.issues) }
            Divider()
            Button("Quit Luma") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings and more")
    }

    /// Version line: says plainly that this is a beta and where to read what
    /// changed, so a tester never has to guess which build they're on.
    private var footer: some View {
        HStack(spacing: 6) {
            Text("Version \(model.versionDisplay)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            Spacer()
            Button("What's new") { NSWorkspace.shared.open(Updater.changelogPage) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.warm.opacity(0.85))
        }
        .padding(.horizontal, 3)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }

    /// Drawn in Luma's own hand (a sunless horizon) and naming the actual fix,
    /// instead of the old dead-end "No controllable displays found."
    @ViewBuilder
    private var emptyState: some View {
        let excludedCount = model.displays.filter(\.excluded).count
        let failing = model.displays.filter(\.writeFailed)
        VStack(spacing: 9) {
            Image(systemName: "sun.horizon")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            if model.displays.isEmpty {
                Text("Looking for displays…")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text("Scanning DDC over I²C. This can take a moment on Apple Silicon.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            } else if excludedCount == model.displays.count {
                Text("Every display is excluded")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text("Keys and sliders have nothing to touch. Un-exclude one from the tray menu (right-click the icon).")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            } else if !failing.isEmpty {
                Text("This monitor won't answer")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text("DDC/CI may be off in its on-screen menu, or it's behind a DisplayLink dock.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            } else {
                Text("No controllable displays")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text("Nothing here responds to brightness control yet.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
            Button(action: { model.controller?.scheduleRescan() }) {
                Text("Reconnect").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkOnWarm)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(LinearGradient(colors: [.warmHot, .warm], startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    /// First-run hello. Adapts to whether the keys are live yet, so the last
    /// step is always "now press it" — the first HUD is the celebration.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Brightness for every display.")
                .font(.system(size: 13.5, weight: .bold)).foregroundStyle(.white)
            Text(model.axTrusted
                 ? "You're set. Press a brightness key — every screen moves, and a HUD confirms it."
                 : "Drag a slider to try it now. To use your brightness keys, grant Accessibility below.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { model.updateSettings { $0.hasOnboarded = true } }) {
                Text("Got it").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkOnWarm)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(LinearGradient(colors: [.warmHot, .warm], startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.warm.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.warm.opacity(0.22), lineWidth: 1))
    }

    private var axBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enable keyboard keys")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
            Text("Luma needs Accessibility to intercept brightness keys.")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            // User-initiated prompt() (main thread) reliably registers Luma in
            // the list and shows the dialog; openSystemSettings is the fallback.
            Button(action: { if !Accessibility.prompt() { Accessibility.openSystemSettings() } }) {
                Text("Grant Access…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkOnWarm)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(LinearGradient(colors: [.warmHot, .warm], startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.warm.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.warm.opacity(0.25), lineWidth: 1))
    }

    private func sliderRow(icon: String, label: String, value: Float, bold: Bool = false,
                           onChange: @escaping (Float) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55)).frame(width: 14)
                Text(label).font(.system(size: 12.5, weight: bold ? .bold : .semibold))
                    .foregroundStyle(.white.opacity(bold ? 1 : 0.92)).lineLimit(1)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            BrightnessSlider(value: value, onChange: onChange)
        }
    }

    private func labeledSegment<T: Hashable>(_ label: String, selection: T,
        options: [(T, String)], onPick: @escaping (T) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 10, weight: .bold)).tracking(0.6)
                .foregroundStyle(.white.opacity(0.4))
            SegmentedPicker(options: options, selection: selection, onPick: onPick)
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.92))
        }
        .toggleStyle(WarmToggle())
    }

    @ViewBuilder
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 13) { content() }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.05), lineWidth: 1))
    }
}

/// Warm-accented segmented control (replaces the stock grey Picker).
/// Switch that carries the same warm gradient as a selected segment when on,
/// and a plainly neutral track when off.
///
/// The stock `.switch` style with `.tint(.warm)` left the two states reading
/// almost alike against this panel: macOS applies the tint unevenly and the
/// off track sat at a similar weight, so "on" was easy to misread at a glance.
private struct WarmToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn
                          ? AnyShapeStyle(LinearGradient(colors: [.warmHot, .warm],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.white.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(
                        .white.opacity(configuration.isOn ? 0 : 0.09), lineWidth: 1))
                    .shadow(color: configuration.isOn ? .warm.opacity(0.32) : .clear, radius: 4, y: 1)
                    .frame(width: 36, height: 21)
                Circle()
                    .fill(.white)
                    .frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .padding(.horizontal, 2)
            }
            .frame(width: 36, height: 21)
            .contentShape(Rectangle())
            .onTapGesture { configuration.$isOn.wrappedValue.toggle() }
            .animation(.easeOut(duration: 0.16), value: configuration.isOn)
        }
    }
}

private struct SegmentedPicker<T: Hashable>: View {
    let options: [(T, String)]
    let selection: T
    let onPick: (T) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { option in
                let selected = option.0 == selection
                Text(option.1)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Color.inkOnWarm : .white.opacity(0.62))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? AnyShapeStyle(LinearGradient(colors: [.warmHot, .warm], startPoint: .top, endPoint: .bottom))
                                            : AnyShapeStyle(Color.clear))
                            .shadow(color: selected ? .warm.opacity(0.3) : .clear, radius: 4, y: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(option.0) }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.05)))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// Control Center-style slider: white-fill capsule with a warm sun glyph on a
/// recessed track, draggable anywhere along its length.
private struct BrightnessSlider: View {
    var value: Float
    var onChange: (Float) -> Void
    @State private var lastDetent: Int = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.38))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 1))
                Capsule().fill(LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                    .frame(width: max(30, geo.size.width * CGFloat(value)))
                    .shadow(color: .black.opacity(0.25), radius: 2.5, y: 1)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.55, green: 0.4, blue: 0.16))
                    .padding(.leading, 9)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let v = Float(min(max(drag.location.x / geo.size.width, 0), 1))
                    // Trackpad detent at each quarter mark (0/25/50/75/100).
                    let detent = Int((v * 4).rounded())
                    if detent != lastDetent {
                        lastDetent = detent
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    onChange(v)
                }
                .onEnded { _ in lastDetent = -1 }
            )
        }
        .frame(height: 30)
    }
}
