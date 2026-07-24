import SwiftUI

/// Main-actor mirror of the Store for SwiftUI. The engine mutates the Store
/// from its own threads; `refresh()` re-reads it (wired to Store.onChange).
final class AppModel: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var settings = Settings()
    @Published var axTrusted = true
    @Published var launchAtLogin = false
    /// nil when CoreBrightness isn't there to drive, which hides the card.
    @Published var warmth: NightShift.Status?
    @Published var warmStrength: Float = 0
    @Published var panelMaxHeight: CGFloat = 700

    fileprivate(set) var controller: BrightnessController?
    private let store: Store
    private var lastMasterValue: Float?
    /// Called after a popover-initiated brightness change so the menu bar
    /// icon can redraw (the engine paths go through Store.onChange instead).
    var onAdjust: (() -> Void)?

    init(store: Store, controller: BrightnessController?) {
        self.store = store
        self.controller = controller
        refresh()
        refreshWarmth()
        // Control Center, System Settings and the schedule rolling over all
        // move Night Shift behind our back; without this the card goes stale.
        NightShift.observe { [weak self] in self?.refreshWarmth() }
    }

    func refresh() {
        displays = store.displays.get()
        settings = store.settings.get()
        if lastMasterValue == nil || !masterMixed { lastMasterValue = masterValue }
    }

    /// Non-excluded, controllable displays (what sliders and keys touch).
    var active: [DisplayInfo] { displays.filter { !$0.excluded && $0.backend != .none } }

    var masterValue: Float {
        active.isEmpty ? 0 : active.map(\.brightness).reduce(0, +) / Float(active.count)
    }

    var masterMixed: Bool {
        Set(active.map { Int(($0.brightness * 100).rounded()) }).count > 1
    }

    var masterDisplayValue: Float { masterMixed ? (lastMasterValue ?? masterValue) : masterValue }

    func setBrightness(id: CGDirectDisplayID, value: Float) {
        controller?.apply(id: id, value: value)
        if let i = displays.firstIndex(where: { $0.id == id }) {
            displays[i].brightness = value
        }
        onAdjust?()
    }

    func setAll(value: Float) {
        lastMasterValue = value
        for display in active { setBrightness(id: display.id, value: value) }
    }

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        var copy = settings
        mutate(&copy)
        // Exclusions are tray-owned; never let the popover revert them.
        copy.excluded = store.settings.get().excluded
        store.updateSettings(copy)
    }

    // MARK: - Warmth (Night Shift)

    /// macOS owns this state, so Luma stores none of it: every read comes
    /// straight from CoreBrightness and every write goes straight back.
    ///
    /// Called on every popover open as well as from the notification block.
    /// The block is the live path, but it coalesces, so a burst of changes
    /// can land as one late callback; re-reading on open costs one call and
    /// means the card is never showing yesterday's value.
    func refreshWarmth() {
        warmth = NightShift.status()
        warmStrength = NightShift.strength
    }

    func setWarmEnabled(_ on: Bool) {
        NightShift.setMasterEnabled(on, status: warmth ?? NightShift.Status())
        refreshWarmth()
    }

    /// Dragging the slider while warmth is off means you want it on; that is
    /// what Control Center does, and a slider that does nothing reads broken.
    func setWarmStrength(_ value: Float) {
        warmStrength = value
        NightShift.setStrength(value)
        if warmth?.isWarm == false { warmNow() }
    }

    func warmNow() {
        NightShift.setWarmth(on: true, scheduled: warmth?.mode != .manual)
        refreshWarmth()
    }

    func followCustomSchedule() {
        guard let warmth, warmth.mode == .custom else { return }
        NightShift.reconcile(mode: warmth.mode, from: warmth.from, to: warmth.to, enabled: warmth.enabled)
        refreshWarmth()
    }

    /// Night Shift knows tonight's sunset and will not tell us, so we work
    /// it out. The location fix is asked for here and nowhere else: only a
    /// user who has picked a sunset schedule has any reason to be prompted.
    func sunsetLine(permitted: Bool) -> String {
        guard permitted else { return "Needs Location Services to know where you are." }
        guard let here = LocationOnce.shared.coordinate else {
            LocationOnce.shared.request { [weak self] in self?.objectWillChange.send() }
            return LocationOnce.shared.isDenied
                ? "Follows sunset and sunrise where you are."
                : "Finding sunset where you are\u{2026}"
        }
        guard let solar = SolarTimes.riseAndSet(latitude: here.latitude,
                                                longitude: here.longitude, on: Date()) else {
            // Inside a polar circle there is no sunrise today to name.
            return "Follows sunset and sunrise where you are."
        }
        let clock = DateFormatter()
        clock.timeStyle = .short
        clock.dateStyle = .none
        return "Tonight \(clock.string(from: solar.sunset)) to \(clock.string(from: solar.sunrise))"
    }

    func setWarmSchedule(_ mode: NightShift.Mode) {
        let current = warmth ?? NightShift.Status()
        NightShift.applySchedule(mode, from: current.from, to: current.to)
        refreshWarmth()
    }

    /// Times only, never the mode: the mode belongs to the segment alone, so
    /// nudging a time can never drag the schedule back to Custom.
    func setWarmTimes(from: NightShift.Time, to: NightShift.Time) {
        NightShift.setSchedule(from: from, to: to)
        if let warmth {
            NightShift.reconcile(mode: warmth.mode, from: from, to: to, enabled: warmth.enabled)
        }
        refreshWarmth()
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

    func copyDiagnostics() { Diagnostics.copyToClipboard(store: store) }

    func saveProfileDialog() {
        guard let name = promptForProfileName() else { return }
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
        // One stable, top-origin root at every height. ViewThatFits swapped
        // the entire tree when Warmth crossed the screen-height threshold,
        // and NSHostingController briefly centred the new-height content in
        // the old-height window, making the otherwise fixed toggle slide.
        ScrollView(.vertical) { panelContent }
            .frame(maxHeight: model.panelMaxHeight)
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if !model.settings.hasOnboarded { welcome }
            if !model.axTrusted { axBanner }

            card {
                if model.active.count > 1 {
                    sliderRow(icon: "square.grid.2x2.fill", label: "All Displays",
                              value: model.masterDisplayValue, bold: true, mixed: model.masterMixed) {
                        model.setAll(value: $0)
                    }
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

            if let warmth = model.warmth { card { warmthCard(warmth) } }

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
        .padding(10)
        .frame(width: 304)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.horizon.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.warmHot, .warm], startPoint: .top, endPoint: .bottom))
            Text("Luma").font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
            if model.isPrerelease {
                Text("BETA")
                    .font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(Color.inkOnWarm)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.warm))
            }
            Spacer()
            Text("\(model.displays.count) display\(model.displays.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.primary.opacity(0.55))
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
                .foregroundStyle(Color.primary.opacity(0.55))
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
                .foregroundStyle(Color.primary.opacity(0.5))
            Spacer()
            Button("What's new") { NSWorkspace.shared.open(Updater.changelogPage) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.warm.opacity(0.85))
        }
        .padding(.horizontal, 3)
    }

    private var divider: some View { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }

    /// Drawn in Luma's own hand (a sunless horizon) and naming the actual fix,
    /// instead of the old dead-end "No controllable displays found."
    @ViewBuilder
    private var emptyState: some View {
        let excludedCount = model.displays.filter(\.excluded).count
        let failing = model.displays.filter(\.writeFailed)
        VStack(spacing: 5) {
            Image(systemName: "sun.horizon")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.primary.opacity(0.35))
            if model.displays.isEmpty {
                Text("Looking for displays…")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.9))
                Text("Scanning DDC over I²C. This can take a moment on Apple Silicon.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.primary.opacity(0.55))
            } else if excludedCount == model.displays.count {
                Text("Every display is excluded")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.9))
                Text("Keys and sliders have nothing to touch. Un-exclude one from the tray menu (right-click the icon).")
                    .font(.system(size: 11.5)).foregroundStyle(Color.primary.opacity(0.55))
            } else if !failing.isEmpty {
                Text("This monitor won't answer")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.9))
                Text("DDC/CI may be off in its on-screen menu, or it's behind a DisplayLink dock.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.primary.opacity(0.55))
            } else {
                Text("No controllable displays")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.9))
                Text("Nothing here responds to brightness control yet.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.primary.opacity(0.55))
            }
            Button(action: { model.controller?.scheduleRescan() }) {
                Text("Reconnect").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkOnWarm)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Capsule().fill(LinearGradient(colors: [.warmHot, .warm], startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
    }

    /// First-run hello. Adapts to whether the keys are live yet, so the last
    /// step is always "now press it" — the first HUD is the celebration.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Brightness for every display.")
                .font(.system(size: 13.5, weight: .bold)).foregroundStyle(.primary)
            Text(model.axTrusted
                 ? "You're set. Press a brightness key — every screen moves, and a HUD confirms it."
                 : "Drag a slider to try it now. To use your brightness keys, grant Accessibility below.")
                .font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { model.updateSettings { $0.hasOnboarded = true } }) {
                Text("Got it").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkOnWarm)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Capsule().fill(LinearGradient(colors: [.warmHot, .warm], startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.warm.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.warm.opacity(0.22), lineWidth: 1))
    }

    private var axBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Enable keyboard keys")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
            Text("Luma needs Accessibility to intercept brightness keys.")
                .font(.system(size: 11.5)).foregroundStyle(Color.primary.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            // User-initiated prompt() (main thread) reliably registers Luma in
            // the list and shows the dialog; openSystemSettings is the fallback.
            Button(action: { if !Accessibility.prompt() { Accessibility.openSystemSettings() } }) {
                Text("Grant Access…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkOnWarm)
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background(Capsule().fill(LinearGradient(colors: [.warmHot, .warm], startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.warm.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.warm.opacity(0.25), lineWidth: 1))
    }

    /// Warmth is macOS's Night Shift, not a gamma layer of our own, so this
    /// card is a remote control for state that lives outside Luma. The toggle
    /// is always live; everything it controls is revealed beneath it.
    private func warmthCard(_ warmth: NightShift.Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { warmth.enabled }, set: { model.setWarmEnabled($0) })) {
                HStack(spacing: 7) {
                    Image(systemName: warmth.enabled ? "sunset.fill" : "sunset")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(warmth.enabled ? Color.warm : Color.primary.opacity(0.55))
                        .frame(width: 14)
                    Text("Warmth").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.92))
                }
            }
            .toggleStyle(WarmToggle())

            Group {
                if warmth.enabled {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Spacer()
                                Text("\(Int((model.warmStrength * 100).rounded()))%  ·  \(NightShift.kelvin(for: model.warmStrength))K")
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Color.primary.opacity(0.6))
                            }
                            BrightnessSlider(value: model.warmStrength, tint: .warmth,
                                             label: "Warmth", highlighted: warmth.isWarm) {
                                model.setWarmStrength($0)
                            }
                        }

                        labeledSegment("SCHEDULE", selection: warmth.mode,
                            options: [(NightShift.Mode.manual, "None"),
                                      (.sunsetToSunrise, "Sunset"),
                                      (.custom, "Custom")]) { model.setWarmSchedule($0) }

                        if warmth.mode == .custom {
                            HStack(spacing: 12) {
                                timeField("FROM", warmth.from) { model.setWarmTimes(from: $0, to: warmth.to) }
                                timeField("TO", warmth.to) { model.setWarmTimes(from: warmth.from, to: $0) }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            if !NightShift.customScheduleIsActiveNow(from: warmth.from, to: warmth.to) {
                                toggleRow("Warm now", isOn: Binding(
                                    get: { warmth.isWarm },
                                    set: { on in
                                        if on { model.warmNow() }
                                        else { model.followCustomSchedule() }
                                    }
                                ))
                            }
                        } else if warmth.mode == .sunsetToSunrise {
                            scheduleNote(model.sunsetLine(permitted: warmth.sunSchedulePermitted))
                        }
                    }
                    .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeInOut(duration: 0.18), value: warmth.enabled)
        }
    }

    /// A text-entry DatePicker needs a field editor and would make this
    /// non-activating panel steal focus. Menu pickers remain keyboard-free
    /// while allowing direct selection instead of repeated stepping.
    private func timeField(_ label: String, _ time: NightShift.Time,
                           onChange: @escaping (NightShift.Time) -> Void) -> some View {
        let minutes = Array(Set(stride(from: 0, to: 60, by: 5)).union([time.minute])).sorted()
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .bold)).tracking(0.5)
                .foregroundStyle(Color.primary.opacity(0.55))
                .fixedSize()
            HStack(spacing: 3) {
                Picker("Hour", selection: Binding(
                    get: { time.hour },
                    set: { onChange(.init(hour: $0, minute: time.minute)) }
                )) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(String(format: "%02d", hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("\(label) hour"))

                Text(":")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())

                Picker("Minute", selection: Binding(
                    get: { time.minute },
                    set: { onChange(.init(hour: time.hour, minute: $0)) }
                )) {
                    ForEach(minutes, id: \.self) { minute in
                        Text(String(format: "%02d", minute)).tag(minute)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("\(label) minute"))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    private func scheduleNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.58))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sliderRow(icon: String, label: String, value: Float, bold: Bool = false,
                           mixed: Bool = false,
                           onChange: @escaping (Float) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55)).frame(width: 14)
                Text(label).font(.system(size: 12.5, weight: bold ? .bold : .semibold))
                    .foregroundStyle(Color.primary.opacity(bold ? 1 : 0.92)).lineLimit(1)
                Spacer()
                Text(mixed ? "Mixed" : "\(Int((value * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.6))
            }
            BrightnessSlider(value: value, label: "\(label) brightness",
                             mixed: mixed, onChange: onChange)
        }
    }

    private func labeledSegment<T: Hashable>(_ label: String, selection: T,
        options: [(T, String)], onPick: @escaping (T) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .bold)).tracking(0.6)
                .foregroundStyle(Color.primary.opacity(0.55))
            SegmentedPicker(label: label, options: options, selection: selection, onPick: onPick)
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.primary.opacity(0.92))
        }
        .toggleStyle(WarmToggle())
    }

    @ViewBuilder
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
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
        HStack(spacing: 8) {
            configuration.label
            Spacer(minLength: 6)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(configuration.isOn
                          ? AnyShapeStyle(LinearGradient(colors: [.warmHot, .warm],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.primary.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(
                        Color.primary.opacity(configuration.isOn ? 0 : 0.09), lineWidth: 1))
                    .shadow(color: configuration.isOn ? .warm.opacity(0.32) : .clear, radius: 4, y: 1)
                    .frame(width: 34, height: 19)
                    .animation(.easeOut(duration: 0.16), value: configuration.isOn)
                Circle()
                    .fill(.white)
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .offset(x: configuration.isOn ? 17 : 2)
                    .animation(.easeOut(duration: 0.16), value: configuration.isOn)
            }
            .frame(width: 34, height: 19)
        }
        // Whole row is the hit target, label included: a 34pt pill is a small
        // thing to ask someone to hit, and the words next to it look clickable.
        .contentShape(Rectangle())
        .onTapGesture { configuration.$isOn.wrappedValue.toggle() }
    }
}

private struct SegmentedPicker<T: Hashable>: View {
    let label: String
    let options: [(T, String)]
    let selection: T
    let onPick: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let selected = option.0 == selection
                Button { onPick(option.0) } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color.inkOnWarm : Color.primary.opacity(0.62))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? AnyShapeStyle(LinearGradient(colors: [.warmHot, .warm], startPoint: .top, endPoint: .bottom))
                                                : AnyShapeStyle(Color.clear))
                                .shadow(color: selected ? .warm.opacity(0.3) : .clear, radius: 4, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("\(label): \(option.1)"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// Compact slider with a visible knob, draggable anywhere along its track.
private struct BrightnessSlider: View {
    /// The glyph keeps brightness and warmth distinct on the shared track.
    enum Tint {
        case brightness, warmth
        var glyph: String { self == .brightness ? "sun.max.fill" : "sunset.fill" }
    }

    var value: Float
    var tint: Tint = .brightness
    var label: String
    var mixed = false
    var highlighted = true
    var onChange: (Float) -> Void
    @State private var lastDetent: Int = -1

    var body: some View {
        GeometryReader { geo in
            let knobSize: CGFloat = 23
            let percent = Int((value * 100).rounded())
            let displayValue: Float = percent == 100 ? 1 : percent == 0 ? 0 : value
            let position = CGFloat(displayValue)
            let travel = geo.size.width - knobSize
            let active = highlighted && !mixed
            let fillWidth = position * travel + knobSize

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                ZStack {
                    Capsule().fill(Color.gray.opacity(0.48))
                        .opacity(active ? 0 : 1)
                        .animation(.easeInOut(duration: 0.22), value: active)
                    Capsule().fill(LinearGradient(colors: [.warmHot, .warm],
                                                  startPoint: .top, endPoint: .bottom))
                        .opacity(active ? 1 : 0)
                        .animation(.easeInOut(duration: 0.22), value: active)
                }
                // Keep width outside the animated color layers: mixed ↔ active
                // must snap to its value while only the fill colour cross-fades.
                .frame(width: fillWidth)
                Image(systemName: tint.glyph)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(active ? Color.inkOnWarm.opacity(0.75) : Color.primary.opacity(0.58))
                    .padding(.leading, 7)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(
                        active ? Color.black.opacity(0.16) : Color.primary.opacity(0.22),
                        lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: position * travel)
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
        .frame(height: 23)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(mixed ? "Mixed" : "\(Int((value * 100).rounded())) percent"))
        .accessibilityHint(Text(mixed ? "Adjust to set all displays to the same brightness" : ""))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(1, value + 1.0 / 16))
            case .decrement: onChange(max(0, value - 1.0 / 16))
            @unknown default: break
            }
        }
    }
}
