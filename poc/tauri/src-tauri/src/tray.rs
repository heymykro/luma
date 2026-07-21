//! Tray icon: right-click quick-actions menu, pause state, scroll tracking.
//! The menu is rebuilt (main thread) whenever displays or settings change so
//! checkmarks always reflect canonical state.

use crate::commands::{self, AppState, HudPosition, KeyMode};
use crate::display::Backend;
use std::sync::atomic::Ordering;
use tauri::{
    image::Image,
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu},
    AppHandle, Manager, Wry,
};
use tauri_plugin_autostart::ManagerExt;

const PRESETS: [(&str, f32); 4] = [("25%", 0.25), ("50%", 0.5), ("75%", 0.75), ("100%", 1.0)];

pub fn build_menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let state = app.state::<AppState>();
    let settings = state.settings.lock().unwrap().clone();
    let displays = state.displays.lock().unwrap().clone();
    let paused = state.paused.load(Ordering::Relaxed);

    let version = MenuItem::with_id(
        app,
        "version",
        format!("Luma {}", app.package_info().version),
        false,
        None::<&str>,
    )?;

    // All-displays presets.
    let mut preset_items: Vec<MenuItem<Wry>> = Vec::new();
    for (label, v) in PRESETS {
        preset_items.push(MenuItem::with_id(
            app,
            format!("preset-all-{v}"),
            label,
            true,
            None::<&str>,
        )?);
    }
    let preset_refs: Vec<&dyn tauri::menu::IsMenuItem<Wry>> =
        preset_items.iter().map(|i| i as _).collect();
    let all_presets = Submenu::with_id_and_items(app, "all-presets", "All Displays", true, &preset_refs)?;

    // Key routing mode.
    let mode_all = CheckMenuItem::with_id(
        app,
        "mode-all",
        "Keys Adjust All Displays",
        true,
        settings.key_mode == KeyMode::All,
        None::<&str>,
    )?;
    let mode_mouse = CheckMenuItem::with_id(
        app,
        "mode-mouse",
        "Keys Adjust Display Under Mouse",
        true,
        settings.key_mode == KeyMode::UnderMouse,
        None::<&str>,
    )?;

    let pause = CheckMenuItem::with_id(
        app,
        "pause",
        "Pause Luma",
        true,
        paused,
        None::<&str>,
    )?;

    // Per-display submenus.
    let mut display_menus: Vec<Submenu<Wry>> = Vec::new();
    for d in &displays {
        let mut items: Vec<Box<dyn tauri::menu::IsMenuItem<Wry>>> = Vec::new();
        if d.backend != Backend::None {
            for (label, v) in PRESETS {
                items.push(Box::new(MenuItem::with_id(
                    app,
                    format!("preset-{}-{v}", d.id),
                    label,
                    !d.excluded,
                    None::<&str>,
                )?));
            }
            items.push(Box::new(PredefinedMenuItem::separator(app)?));
        }
        items.push(Box::new(CheckMenuItem::with_id(
            app,
            format!("exclude-{}", d.id),
            "Exclude from Luma",
            d.uuid.is_some(),
            d.excluded,
            None::<&str>,
        )?));
        let refs: Vec<&dyn tauri::menu::IsMenuItem<Wry>> =
            items.iter().map(|i| i.as_ref()).collect();
        display_menus.push(Submenu::with_id_and_items(
            app,
            format!("display-{}", d.id),
            &d.name,
            true,
            &refs,
        )?);
    }

    // HUD position.
    let hud_items: Vec<CheckMenuItem<Wry>> = [
        ("hud-top", "Top", HudPosition::Top),
        ("hud-left", "Left", HudPosition::Left),
        ("hud-right", "Right", HudPosition::Right),
    ]
    .into_iter()
    .map(|(id, label, pos)| {
        CheckMenuItem::with_id(app, id, label, true, settings.hud_position == pos, None::<&str>)
    })
    .collect::<Result<_, _>>()?;
    let hud_refs: Vec<&dyn tauri::menu::IsMenuItem<Wry>> = hud_items.iter().map(|i| i as _).collect();
    let hud_menu = Submenu::with_id_and_items(app, "hud-menu", "HUD Position", true, &hud_refs)?;

    let refresh = MenuItem::with_id(app, "refresh", "Refresh Displays", true, None::<&str>)?;
    let diag = MenuItem::with_id(app, "diag", "Copy Diagnostics", true, None::<&str>)?;
    let autostart = CheckMenuItem::with_id(
        app,
        "autostart",
        "Launch at Login",
        true,
        app.autolaunch().is_enabled().unwrap_or(false),
        None::<&str>,
    )?;
    let quit = MenuItem::with_id(app, "quit", "Quit Luma", true, Some("cmd+q"))?;
    let sep = || PredefinedMenuItem::separator(app);

    let mut items: Vec<&dyn tauri::menu::IsMenuItem<Wry>> = vec![&version, &all_presets];
    let s1 = sep()?;
    items.push(&s1);
    for m in &display_menus {
        items.push(m);
    }
    let s2 = sep()?;
    items.push(&s2);
    items.push(&mode_all);
    items.push(&mode_mouse);
    items.push(&pause);
    let s3 = sep()?;
    items.push(&s3);
    items.push(&hud_menu);
    items.push(&refresh);
    items.push(&diag);
    let s4 = sep()?;
    items.push(&s4);
    items.push(&autostart);
    items.push(&quit);

    Menu::with_items(app, &items)
}

/// Rebuild + install the menu on the main thread (macOS requirement).
pub fn rebuild(app: &AppHandle) {
    let app = app.clone();
    let _ = app.clone().run_on_main_thread(move || {
        if let Some(tray) = app.tray_by_id("main") {
            if let Ok(menu) = build_menu(&app) {
                let _ = tray.set_menu(Some(menu));
            }
        }
    });
}

pub fn handle_menu_event(app: &AppHandle, id: &str) {
    let state = app.state::<AppState>();
    match id {
        "quit" => {
            state.flush_levels();
            app.exit(0);
        }
        "pause" => {
            let paused = !state.paused.load(Ordering::Relaxed);
            state.paused.store(paused, Ordering::Relaxed);
            if let Some(tray) = app.tray_by_id("main") {
                let icon = if paused {
                    Image::from_bytes(include_bytes!("../icons/tray-paused.png"))
                } else {
                    Image::from_bytes(include_bytes!("../icons/tray.png"))
                };
                if let Ok(icon) = icon {
                    let _ = tray.set_icon(Some(icon));
                    let _ = tray.set_icon_as_template(true);
                }
            }
            rebuild(app);
        }
        "mode-all" | "mode-mouse" => {
            let mut s = state.settings.lock().unwrap().clone();
            s.key_mode = if id == "mode-all" { KeyMode::All } else { KeyMode::UnderMouse };
            commands::update_settings(app, s);
        }
        "hud-top" | "hud-left" | "hud-right" => {
            let mut s = state.settings.lock().unwrap().clone();
            s.hud_position = match id {
                "hud-left" => HudPosition::Left,
                "hud-right" => HudPosition::Right,
                _ => HudPosition::Top,
            };
            commands::update_settings(app, s);
        }
        "autostart" => {
            let al = app.autolaunch();
            let _ = if al.is_enabled().unwrap_or(false) { al.disable() } else { al.enable() };
            rebuild(app);
        }
        "refresh" => {
            let app = app.clone();
            std::thread::spawn(move || commands::refresh_displays(&app));
        }
        "diag" => {
            // Menu events arrive on the main thread; NSPasteboard is safe here.
            use objc2_app_kit::{NSPasteboard, NSPasteboardTypeString};
            use objc2_foundation::NSString;
            let text = diagnostics(app);
            unsafe {
                let pb = NSPasteboard::generalPasteboard();
                pb.clearContents();
                pb.setString_forType(&NSString::from_str(&text), NSPasteboardTypeString);
            }
        }
        _ if id.starts_with("preset-all-") => {
            if let Ok(v) = id["preset-all-".len()..].parse::<f32>() {
                commands::apply_all_emit(app, v);
            }
        }
        _ if id.starts_with("preset-") => {
            // preset-<display id>-<value>
            let rest = &id["preset-".len()..];
            if let Some((did, v)) = rest.split_once('-') {
                if let (Ok(did), Ok(v)) = (did.parse::<u32>(), v.parse::<f32>()) {
                    let applied = commands::apply_brightness(app, did, v);
                    let _ = tauri::Emitter::emit(
                        app,
                        "brightness-changed",
                        serde_json::json!({ "id": did, "value": applied }),
                    );
                }
            }
        }
        _ if id.starts_with("exclude-") => {
            if let Ok(did) = id["exclude-".len()..].parse::<u32>() {
                let uuid = state
                    .displays
                    .lock()
                    .unwrap()
                    .iter()
                    .find(|d| d.id == did)
                    .and_then(|d| d.uuid.clone());
                if let Some(uuid) = uuid {
                    let mut s = state.settings.lock().unwrap().clone();
                    if let Some(i) = s.excluded.iter().position(|u| u == &uuid) {
                        s.excluded.remove(i);
                    } else {
                        s.excluded.push(uuid);
                    }
                    commands::update_settings(app, s);
                }
            }
        }
        _ => {}
    }
}

fn diagnostics(app: &AppHandle) -> String {
    let state = app.state::<AppState>();
    let settings = state.settings.lock().unwrap().clone();
    let displays = state.displays.lock().unwrap().clone();
    let macos = objc2_foundation::NSProcessInfo::processInfo()
        .operatingSystemVersionString()
        .to_string();

    let mut s = format!(
        "Luma {} diagnostics\nmacOS {} ({})\nAccessibility: {}\nPaused: {}\n\nDisplays:\n",
        app.package_info().version,
        macos,
        std::env::consts::ARCH,
        if crate::keys::ax_trusted() { "granted" } else { "not granted" },
        state.paused.load(Ordering::Relaxed),
    );
    for d in &displays {
        s.push_str(&format!(
            "- id={} \"{}\" backend={:?} vendor=0x{:x} builtin={} brightness={:.2} excluded={} uuid={}\n",
            d.id,
            d.name,
            d.backend,
            crate::display::vendor(d.id),
            d.builtin,
            d.brightness,
            d.excluded,
            d.uuid.as_deref().unwrap_or("?"),
        ));
    }
    s.push_str(&format!(
        "\nSettings: keys={:?} hud={:?} legacyFKeys={}\n",
        settings.key_mode, settings.hud_position, settings.legacy_f_keys
    ));
    s
}
