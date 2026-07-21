import AppKit

/// Right-click quick-actions menu, rebuilt on every open so checkmarks
/// always reflect canonical state. Mirrors the Tauri POC's menu exactly.
enum TrayMenu {
    private static let presets: [(String, Float)] = [
        ("25%", 0.25), ("50%", 0.5), ("75%", 0.75), ("100%", 1.0),
    ]

    /// Returns the menu and its action target. The caller MUST retain
    /// `actions` for as long as the menu can be shown — NSMenu.delegate and
    /// NSMenuItem.target are weak, so nothing here keeps it alive otherwise.
    static func build(
        store: Store, controller: BrightnessController, statusController: StatusItemController
    ) -> (menu: NSMenu, actions: AnyObject) {
        let settings = store.settings.get()
        let displays = store.displays.get()
        let menu = NSMenu()
        // Honor our explicit isEnabled flags (excluded-display presets); the
        // default auto-validation would override them to enabled.
        menu.autoenablesItems = false
        let act = MenuActions(
            store: store, controller: controller, statusController: statusController
        )

        let version = item("Luma \(Diagnostics.appVersion)", action: nil, target: act)
        version.isEnabled = false
        menu.addItem(version)

        let allPresets = NSMenu()
        for (label, value) in presets {
            let entry = item(label, action: #selector(MenuActions.presetAll(_:)), target: act)
            entry.representedObject = value
            allPresets.addItem(entry)
        }
        menu.addItem(submenu("All Displays", allPresets))

        // Profiles: named per-display snapshots.
        let profileMenu = NSMenu()
        for name in ProfileStore.load().names {
            let entry = item(name, action: #selector(MenuActions.applyProfileItem(_:)), target: act)
            entry.representedObject = name
            let del = item("Delete", action: #selector(MenuActions.deleteProfileItem(_:)), target: act)
            del.representedObject = name
            let subEntry = NSMenu(); subEntry.autoenablesItems = false
            let apply = item("Apply", action: #selector(MenuActions.applyProfileItem(_:)), target: act)
            apply.representedObject = name
            subEntry.addItem(apply); subEntry.addItem(del)
            entry.submenu = subEntry
            profileMenu.addItem(entry)
        }
        if !ProfileStore.load().names.isEmpty { profileMenu.addItem(.separator()) }
        profileMenu.addItem(item("Save Current as Profile…", action: #selector(MenuActions.saveProfileDialog), target: act))
        menu.addItem(submenu("Profiles", profileMenu))
        menu.addItem(.separator())

        for display in displays {
            let sub = NSMenu()
            if display.backend != .none {
                for (label, value) in presets {
                    let entry = item(label, action: #selector(MenuActions.presetOne(_:)), target: act)
                    entry.representedObject = (display.id, value)
                    entry.isEnabled = !display.excluded
                    sub.addItem(entry)
                }
                sub.addItem(.separator())
            }
            let exclude = item("Exclude from Luma", action: #selector(MenuActions.toggleExclude(_:)), target: act)
            exclude.representedObject = display.id
            exclude.state = display.excluded ? .on : .off
            exclude.isEnabled = display.uuid != nil
            sub.addItem(exclude)
            menu.addItem(submenu(display.name, sub))
        }
        menu.addItem(.separator())

        let modeAll = item("Keys Adjust All Displays", action: #selector(MenuActions.modeAll), target: act)
        modeAll.state = settings.keyMode == .all ? .on : .off
        menu.addItem(modeAll)
        let modeMouse = item("Keys Adjust Display Under Mouse", action: #selector(MenuActions.modeMouse), target: act)
        modeMouse.state = settings.keyMode == .underMouse ? .on : .off
        menu.addItem(modeMouse)
        let pause = item("Pause Luma", action: #selector(MenuActions.togglePause), target: act)
        pause.state = store.paused.get() ? .on : .off
        menu.addItem(pause)
        menu.addItem(.separator())

        let hudMenu = NSMenu()
        for (label, position) in [("Top", HUDPosition.top), ("Left", .left), ("Right", .right)] {
            let entry = item(label, action: #selector(MenuActions.setHUD(_:)), target: act)
            entry.representedObject = position
            entry.state = settings.hudPosition == position ? .on : .off
            hudMenu.addItem(entry)
        }
        menu.addItem(submenu("HUD Position", hudMenu))
        menu.addItem(item("Refresh Displays", action: #selector(MenuActions.refresh), target: act))
        menu.addItem(item("Copy Diagnostics", action: #selector(MenuActions.copyDiagnostics), target: act))
        menu.addItem(item("Check for Updates…", action: #selector(MenuActions.checkForUpdates), target: act))
        menu.addItem(.separator())

        let autostart = item("Launch at Login", action: #selector(MenuActions.toggleAutostart), target: act)
        autostart.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(autostart)
        let quit = item("Quit Luma", action: #selector(MenuActions.quit), target: act)
        quit.keyEquivalent = "q"
        menu.addItem(quit)

        return (menu, act)
    }

    private static func item(_ title: String, action: Selector?, target: AnyObject) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = target
        return entry
    }

    private static func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        sub.autoenablesItems = false // preserve explicit isEnabled on preset items
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = sub
        return entry
    }
}

/// Menu target. Held strongly by StatusItemController for the menu's lifetime
/// (NSMenuItem.target is weak).
private final class MenuActions: NSObject {
    let store: Store
    let controller: BrightnessController
    weak var statusController: StatusItemController?

    init(store: Store, controller: BrightnessController, statusController: StatusItemController) {
        self.store = store
        self.controller = controller
        self.statusController = statusController
    }

    @objc func presetAll(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Float else { return }
        DispatchQueue.global().async { self.controller.applyAll(value: value) }
    }

    @objc func presetOne(_ sender: NSMenuItem) {
        guard let (id, value) = sender.representedObject as? (CGDirectDisplayID, Float) else { return }
        DispatchQueue.global().async {
            self.controller.apply(id: id, value: value)
            self.store.notifyChanged()
        }
    }

    @objc func toggleExclude(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGDirectDisplayID,
              let uuid = store.displays.get().first(where: { $0.id == id })?.uuid
        else { return }
        var settings = store.settings.get()
        if let index = settings.excluded.firstIndex(of: uuid) {
            settings.excluded.remove(at: index)
        } else {
            settings.excluded.append(uuid)
        }
        store.updateSettings(settings)
    }

    @objc func modeAll() { setMode(.all) }
    @objc func modeMouse() { setMode(.underMouse) }
    private func setMode(_ mode: KeyMode) {
        var settings = store.settings.get()
        settings.keyMode = mode
        store.updateSettings(settings)
    }

    @objc func togglePause() {
        store.paused.set(!store.paused.get())
        statusController?.refreshIcon()
        store.notifyChanged()
    }

    @objc func setHUD(_ sender: NSMenuItem) {
        guard let position = sender.representedObject as? HUDPosition else { return }
        var settings = store.settings.get()
        settings.hudPosition = position
        store.updateSettings(settings)
    }

    @objc func refresh() {
        controller.scheduleRescan()
    }

    @objc func applyProfileItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DispatchQueue.global().async { self.controller.applyProfile(name) }
    }

    @objc func deleteProfileItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller.deleteProfile(name)
    }

    @objc func saveProfileDialog() {
        let alert = NSAlert()
        alert.messageText = "Save Current as Profile"
        alert.informativeText = "Snapshots every display's current brightness by name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Profile name"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { controller.saveProfile(name) }
        }
    }

    @objc func copyDiagnostics() {
        Diagnostics.copyToClipboard(store: store)
    }

    @objc func checkForUpdates() {
        Updater.checkNow()
    }

    @objc func toggleAutostart() {
        LaunchAtLogin.set(enabled: !LaunchAtLogin.isEnabled)
    }

    @objc func quit() {
        store.flushLevels()
        NSApp.terminate(nil)
    }
}
