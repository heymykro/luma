mod commands;
mod display;
mod engine;
mod keys;
mod tray;

use std::ffi::c_void;
use std::sync::atomic::Ordering;
use std::sync::mpsc::{channel, Sender};
use std::time::Duration;
use tauri::{
    image::Image,
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    ActivationPolicy, Manager, WindowEvent,
};
use tauri_plugin_positioner::{Position, WindowExt};

// ------------------------------------------------------------- display hotplug

type ReconfigCb = extern "C" fn(u32, u32, *mut c_void);
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGDisplayRegisterReconfigurationCallback(cb: ReconfigCb, user_info: *mut c_void) -> i32;
}

const K_CG_DISPLAY_BEGIN_CONFIGURATION: u32 = 1;
const K_CG_DISPLAY_ADD: u32 = 1 << 4;
const K_CG_DISPLAY_REMOVE: u32 = 1 << 5;
const K_CG_DISPLAY_ENABLED: u32 = 1 << 8;
const K_CG_DISPLAY_DISABLED: u32 = 1 << 9;
const K_CG_DISPLAY_MIRROR: u32 = 1 << 10;
const K_CG_DISPLAY_UNMIRROR: u32 = 1 << 11;

extern "C" fn on_display_reconfig(id: u32, flags: u32, user_info: *mut c_void) {
    if flags & K_CG_DISPLAY_BEGIN_CONFIGURATION != 0 {
        return;
    }
    // Everything that changes list membership: hotplug, enable/disable, and
    // mirror toggles (mirrored displays are filtered out of the list).
    const TOPOLOGY: u32 = K_CG_DISPLAY_ADD
        | K_CG_DISPLAY_REMOVE
        | K_CG_DISPLAY_ENABLED
        | K_CG_DISPLAY_DISABLED
        | K_CG_DISPLAY_MIRROR
        | K_CG_DISPLAY_UNMIRROR;
    if flags & TOPOLOGY != 0 {
        let tx = unsafe { &*(user_info as *const Sender<(u32, u32)>) };
        let _ = tx.send((id, flags));
    }
}

// ------------------------------------------------------------------------ app

pub fn run() {
    tauri::Builder::default()
        // Two instances = two event taps = double brightness steps.
        .plugin(tauri_plugin_single_instance::init(|_app, _argv, _cwd| {}))
        .plugin(tauri_plugin_positioner::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .invoke_handler(tauri::generate_handler![
            commands::list_displays,
            commands::set_brightness,
            commands::set_all_brightness,
            commands::get_settings,
            commands::set_settings,
            commands::get_autostart,
            commands::set_autostart,
            commands::ax_status,
            commands::open_accessibility_settings,
        ])
        .setup(|app| {
            app.set_activation_policy(ActivationPolicy::Accessory);

            // Vibrancy comes from windowEffects in tauri.conf.json; its radius
            // must match #app's border-radius in styles.css.
            let win = app.get_webview_window("main").unwrap();

            // Brightness engine + state.
            let ddc = engine::spawn_ddc_worker();
            app.manage(commands::AppState::load(app.handle(), ddc));

            // Initial display scan (blocks on DDC reads — off the main thread).
            let handle = app.handle().clone();
            std::thread::spawn(move || commands::refresh_displays(&handle));

            // Hotplug: re-scan after topology settles (DDC handles go stale).
            // Removed/disabled ids are collected across the debounce window so
            // a fast unplug+replug (one coalesced refresh, same display id)
            // still counts as a reconnect for brightness restore.
            let (hp_tx, hp_rx) = channel::<(u32, u32)>();
            let hp_tx: &'static Sender<(u32, u32)> = Box::leak(Box::new(hp_tx));
            unsafe {
                CGDisplayRegisterReconfigurationCallback(
                    on_display_reconfig,
                    hp_tx as *const Sender<(u32, u32)> as *mut c_void,
                );
            }
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                let note = |(id, flags): (u32, u32), removed: &mut std::collections::HashSet<u32>| {
                    if flags & (K_CG_DISPLAY_REMOVE | K_CG_DISPLAY_DISABLED) != 0 {
                        removed.insert(id);
                    }
                };
                while let Ok(ev) = hp_rx.recv() {
                    let mut removed = std::collections::HashSet::new();
                    note(ev, &mut removed);
                    // Debounce: wait until 1.5s pass with no further events.
                    while let Ok(ev) = hp_rx.recv_timeout(Duration::from_millis(1500)) {
                        note(ev, &mut removed);
                    }
                    commands::refresh_displays_after_removal(&handle, &removed);
                }
            });

            // HUD shown when brightness keys are consumed (click-through pill).
            let hud = tauri::WebviewWindowBuilder::new(
                app,
                "hud",
                tauri::WebviewUrl::App("hud.html".into()),
            )
            .inner_size(300.0, 76.0)
            .visible(false)
            .decorations(false)
            .transparent(true)
            .always_on_top(true)
            .focused(false)
            .focusable(false)
            .shadow(false)
            .build()?;
            let _ = hud.set_ignore_cursor_events(true);

            // Show popover and HUD on every Space, including over fullscreen
            // apps (FullScreenAuxiliary needs raw AppKit; Tauri only exposes
            // CanJoinAllSpaces via set_visible_on_all_workspaces).
            let _ = win.set_visible_on_all_workspaces(true);
            let _ = hud.set_visible_on_all_workspaces(true);
            for w in [&win, &hud] {
                if let Ok(ptr) = w.ns_window() {
                    use objc2_app_kit::{NSWindow, NSWindowCollectionBehavior};
                    let ns: &NSWindow = unsafe { &*(ptr as *const NSWindow) };
                    ns.setCollectionBehavior(
                        ns.collectionBehavior() | NSWindowCollectionBehavior::FullScreenAuxiliary,
                    );
                }
            }
            // HUD floats above the menu bar for the notch/dynamic-island look.
            if let Ok(ptr) = hud.ns_window() {
                let ns: &objc2_app_kit::NSWindow = unsafe { &*(ptr as *const _) };
                ns.setLevel(objc2_app_kit::NSPopUpMenuWindowLevel);
            }

            // Brightness key interception (waits for Accessibility grant).
            keys::spawn(app.handle().clone());

            // Tray with quick-actions menu (rebuilt whenever state changes).
            let menu = tray::build_menu(app.handle())?;
            TrayIconBuilder::with_id("main")
                .icon(Image::from_bytes(include_bytes!("../icons/tray.png"))?)
                .icon_as_template(true)
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| {
                    tray::handle_menu_event(app, event.id().as_ref());
                })
                .on_tray_icon_event(|tray, event| {
                    let app = tray.app_handle();
                    tauri_plugin_positioner::on_tray_event(app, &event);
                    match event {
                        TrayIconEvent::Click {
                            button: MouseButton::Left,
                            button_state: MouseButtonState::Up,
                            ..
                        } => {
                            if let Some(win) = app.get_webview_window("main") {
                                if win.is_visible().unwrap_or(false) {
                                    let _ = win.hide();
                                } else {
                                    let _ = win.move_window(Position::TrayCenter);
                                    let _ = win.show();
                                    let _ = win.set_focus();
                                }
                            }
                        }
                        // Scroll-to-adjust: the event tap acts on scrolls only
                        // while the pointer is over the tray icon.
                        TrayIconEvent::Enter { .. } | TrayIconEvent::Move { .. } => {
                            app.state::<commands::AppState>()
                                .over_tray
                                .store(true, Ordering::Relaxed);
                        }
                        TrayIconEvent::Leave { .. } => {
                            app.state::<commands::AppState>()
                                .over_tray
                                .store(false, Ordering::Relaxed);
                        }
                        _ => {}
                    }
                })
                .build(app)?;

            // Persist saved brightness levels (dirty-flag debounce).
            let handle = app.handle().clone();
            std::thread::spawn(move || loop {
                std::thread::sleep(Duration::from_secs(10));
                handle.state::<commands::AppState>().flush_levels();
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "main" {
                if let WindowEvent::Focused(false) = event {
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running Luma");
}
