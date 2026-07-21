use crate::display::{self, Backend, DisplayInfo};
use crate::engine::{self, DdcMsg};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_autostart::ManagerExt;

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug, Default)]
#[serde(rename_all = "kebab-case")]
pub enum KeyMode {
    #[default]
    All,
    UnderMouse,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug, Default)]
#[serde(rename_all = "kebab-case")]
pub enum FlipModifier {
    #[default]
    Option,
    Control,
    Shift,
    Command,
}

impl FlipModifier {
    /// CGEventFlags mask bit for this modifier.
    pub fn mask(self) -> u64 {
        match self {
            FlipModifier::Option => 1 << 19,  // kCGEventFlagMaskAlternate
            FlipModifier::Control => 1 << 18, // kCGEventFlagMaskControl
            FlipModifier::Shift => 1 << 17,   // kCGEventFlagMaskShift
            FlipModifier::Command => 1 << 20, // kCGEventFlagMaskCommand
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug, Default)]
#[serde(rename_all = "kebab-case")]
pub enum HudPosition {
    /// Notch / dynamic-island style, top-center.
    #[default]
    Top,
    /// Vertical pill sliding out from the left edge.
    Left,
    /// Vertical pill sliding out from the right edge.
    Right,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub key_mode: KeyMode,
    /// Also treat F14/F15 as brightness keys (off by default — they collide
    /// with real F-key mappings on full-size keyboards).
    pub legacy_f_keys: bool,
    pub hud_position: HudPosition,
    /// Held during a brightness key/scroll to temporarily flip the routing.
    pub flip_modifier: FlipModifier,
    /// Stable UUIDs of displays Luma should leave alone.
    pub excluded: Vec<String>,
}

pub struct AppState {
    pub displays: Mutex<Vec<DisplayInfo>>,
    pub ddc: Sender<DdcMsg>,
    pub settings: Mutex<Settings>,
    pub settings_path: PathBuf,
    /// Mirror of settings.legacy_f_keys for the event-tap callback (lock-free).
    pub legacy_f_keys: AtomicBool,
    /// Mirror of settings.flip_modifier.mask() for the tap callback.
    pub flip_mask: AtomicU64,
    /// Generation counter for HUD auto-hide debouncing.
    pub hud_gen: AtomicU64,
    /// Session-only: brightness keys/scroll pass through untouched while set.
    pub paused: AtomicBool,
    /// Pointer currently over the tray icon (for scroll-to-adjust).
    pub over_tray: AtomicBool,
    /// Last user-set brightness per display UUID; restored when a DDC display
    /// reconnects (they reset themselves on power-cycle).
    pub saved_levels: Mutex<HashMap<String, f32>>,
    pub levels_dirty: AtomicBool,
    pub levels_path: PathBuf,
}

impl AppState {
    pub fn load(app: &AppHandle, ddc: Sender<DdcMsg>) -> Self {
        let dir = app.path().app_config_dir().expect("no app config dir");
        let _ = std::fs::create_dir_all(&dir);
        let settings_path = dir.join("settings.json");
        let settings: Settings = std::fs::read(&settings_path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let levels_path = dir.join("levels.json");
        let saved_levels: HashMap<String, f32> = std::fs::read(&levels_path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        Self {
            displays: Mutex::new(Vec::new()),
            ddc,
            legacy_f_keys: AtomicBool::new(settings.legacy_f_keys),
            flip_mask: AtomicU64::new(settings.flip_modifier.mask()),
            settings: Mutex::new(settings),
            settings_path,
            hud_gen: AtomicU64::new(0),
            paused: AtomicBool::new(false),
            over_tray: AtomicBool::new(false),
            saved_levels: Mutex::new(saved_levels),
            levels_dirty: AtomicBool::new(false),
            levels_path,
        }
    }

    /// Flush saved levels to disk if dirty (saver thread + quit path).
    pub fn flush_levels(&self) {
        if self.levels_dirty.swap(false, Ordering::Relaxed) {
            if let Ok(json) = serde_json::to_vec_pretty(&*self.saved_levels.lock().unwrap()) {
                let _ = std::fs::write(&self.levels_path, json);
            }
        }
    }

    pub fn save_settings(&self) {
        if let Ok(json) = serde_json::to_vec_pretty(&*self.settings.lock().unwrap()) {
            let _ = std::fs::write(&self.settings_path, json);
        }
    }
}

/// Rebuild the display list (topology + backends + brightness) and notify the UI.
/// Call from a background thread — it round-trips to the main thread for
/// NSScreen names and blocks on the DDC worker for reads.
pub fn refresh_displays(app: &AppHandle) {
    refresh_displays_after_removal(app, &std::collections::HashSet::new());
}

/// `removed_ids`: displays that got a REMOVE/DISABLED reconfiguration event in
/// the batch that triggered this refresh — treated as reconnects for restore
/// even when the id survived the debounce window.
pub fn refresh_displays_after_removal(
    app: &AppHandle,
    removed_ids: &std::collections::HashSet<u32>,
) {
    // Names must come from the main thread (NSScreen).
    let (names_tx, names_rx) = channel();
    let _ = app.run_on_main_thread(move || {
        let mtm = objc2_foundation::MainThreadMarker::new().expect("main thread");
        let _ = names_tx.send(display::display_names(mtm));
    });
    let names: HashMap<u32, String> = names_rx
        .recv_timeout(Duration::from_secs(3))
        .unwrap_or_default();

    let state = app.state::<AppState>();

    // Snapshot write generations so slider/key writes that land while the
    // (slow, seconds-long) DDC refresh is in flight aren't clobbered by the
    // stale values the refresh read before them.
    let gen_snapshot: HashMap<u32, u64> = state
        .displays
        .lock()
        .unwrap()
        .iter()
        .map(|d| (d.id, d.write_gen))
        .collect();

    // DDC enumeration + reads happen on the worker thread.
    let (ddc_tx, ddc_rx) = channel();
    let _ = state.ddc.send(DdcMsg::Refresh(ddc_tx));
    let ddc_levels: HashMap<u32, Option<f32>> = ddc_rx
        .recv_timeout(Duration::from_secs(10))
        .unwrap_or_default();

    // Last-known values, for write-only DDC monitors whose reads fail.
    let prev: HashMap<u32, f32> = state
        .displays
        .lock()
        .unwrap()
        .iter()
        .map(|d| (d.id, d.brightness))
        .collect();

    let prev_ids: Vec<u32> = prev.keys().copied().collect();
    let excluded_uuids = state.settings.lock().unwrap().excluded.clone();

    let mut list = Vec::new();
    for id in display::active_display_ids() {
        if display::mirrors_another(id) {
            continue;
        }
        let uuid = display::stable_uuid(id);
        let excluded = uuid
            .as_ref()
            .map(|u| excluded_uuids.contains(u))
            .unwrap_or(false);
        let builtin = display::is_builtin(id);
        // Strict vendor guard: on macOS 15+ DisplayServices "works" on non-Apple
        // HDR displays but drives the SDR-peak slider, not the backlight.
        let apple = builtin
            || (display::vendor(id) == display::APPLE_VENDOR_ID && engine::apple_can_change(id));
        let (backend, mut brightness) = if apple {
            (Backend::Apple, engine::apple_get(id).unwrap_or(0.5))
        } else if let Some(level) = ddc_levels.get(&id) {
            // None = write-only/flaky reads: fall back to last-known, else 75%.
            let b = level.or_else(|| prev.get(&id).copied()).unwrap_or(0.75);
            (Backend::Ddc, b)
        } else {
            (Backend::None, 0.0)
        };

        // Restore-on-reconnect: DDC monitors reset themselves on power-cycle.
        // Only for newly-appeared (or just-removed, when unplug+replug fell in
        // one debounce window) DDC displays — Apple displays persist their own
        // brightness, and existing displays would fight the user. This also
        // fires on the first scan at launch, intentionally: it covers monitors
        // power-cycled while Luma wasn't running.
        if backend == Backend::Ddc
            && !excluded
            && (!prev_ids.contains(&id) || removed_ids.contains(&id))
        {
            if let Some(saved) = uuid
                .as_ref()
                .and_then(|u| state.saved_levels.lock().unwrap().get(u).copied())
            {
                if (saved - brightness).abs() > 0.01 {
                    let _ = state.ddc.send(DdcMsg::Set(id, saved));
                    brightness = saved;
                }
            }
        }

        let name = names.get(&id).cloned().unwrap_or_else(|| {
            if builtin { "Built-in Display".into() } else { format!("Display {id}") }
        });
        list.push(DisplayInfo { id, name, builtin, backend, brightness, excluded, uuid, write_gen: 0 });
    }

    // Externals first (the ones people actually adjust), built-in last.
    list.sort_by_key(|d| (d.builtin, d.id));

    for d in &list {
        eprintln!(
            "[luma] display {} \"{}\" backend={:?} brightness={:.2}",
            d.id, d.name, d.backend, d.brightness
        );
    }

    // Install atomically; writes that raced the refresh win over the values
    // the refresh read (their queued Set lands on hardware last).
    {
        let mut displays = state.displays.lock().unwrap();
        for d in list.iter_mut() {
            if let Some(cur) = displays.iter().find(|c| c.id == d.id) {
                if gen_snapshot.get(&d.id) != Some(&cur.write_gen) {
                    d.brightness = cur.brightness;
                }
                d.write_gen = cur.write_gen;
            }
        }
        *displays = list.clone();
    }
    let _ = app.emit("displays-changed", &list);
    crate::tray::rebuild(app);
}

/// Set one display; returns the value actually applied.
pub fn apply_brightness(app: &AppHandle, id: u32, value: f32) -> f32 {
    let value = value.clamp(0.0, 1.0);
    let state = app.state::<AppState>();
    let mut displays = state.displays.lock().unwrap();
    if let Some(d) = displays.iter_mut().find(|d| d.id == id) {
        match d.backend {
            Backend::Apple => {
                engine::apple_set(id, value);
            }
            Backend::Ddc => {
                let _ = state.ddc.send(DdcMsg::Set(id, value));
            }
            Backend::None => return d.brightness,
        }
        d.brightness = value;
        d.write_gen += 1;
        if let Some(uuid) = d.uuid.clone() {
            state.saved_levels.lock().unwrap().insert(uuid, value);
            state.levels_dirty.store(true, Ordering::Relaxed);
        }
    }
    value
}

/// Set every non-excluded display and notify the UI (tray/preset paths —
/// slider-initiated changes don't need the echo).
pub fn apply_all_emit(app: &AppHandle, value: f32) {
    let ids: Vec<u32> = app
        .state::<AppState>()
        .displays
        .lock()
        .unwrap()
        .iter()
        .filter(|d| !d.excluded && d.backend != Backend::None)
        .map(|d| d.id)
        .collect();
    for id in ids {
        let v = apply_brightness(app, id, value);
        let _ = app.emit("brightness-changed", serde_json::json!({ "id": id, "value": v }));
    }
}

#[tauri::command]
pub fn list_displays(state: State<AppState>) -> Vec<DisplayInfo> {
    let mut displays = state.displays.lock().unwrap();
    // Apple brightness can drift (Control Center, auto-brightness) — re-read, it's cheap.
    for d in displays.iter_mut() {
        if d.backend == Backend::Apple {
            if let Some(v) = engine::apple_get(d.id) {
                d.brightness = v;
            }
        }
    }
    displays.clone()
}

#[tauri::command]
pub fn set_brightness(app: AppHandle, id: u32, value: f32) {
    apply_brightness(&app, id, value);
}

#[tauri::command]
pub fn set_all_brightness(app: AppHandle, state: State<AppState>, value: f32) {
    let ids: Vec<u32> = state
        .displays
        .lock()
        .unwrap()
        .iter()
        .filter(|d| !d.excluded)
        .map(|d| d.id)
        .collect();
    for id in ids {
        apply_brightness(&app, id, value);
    }
}

#[tauri::command]
pub fn get_settings(state: State<AppState>) -> Settings {
    state.settings.lock().unwrap().clone()
}

/// Single path for settings changes (popover command + tray menu): persists,
/// syncs the exclusion flags into the display list, and refreshes the tray.
pub fn update_settings(app: &AppHandle, settings: Settings) {
    let state = app.state::<AppState>();
    state.legacy_f_keys.store(settings.legacy_f_keys, Ordering::Relaxed);
    state.flip_mask.store(settings.flip_modifier.mask(), Ordering::Relaxed);
    let excluded = settings.excluded.clone();
    *state.settings.lock().unwrap() = settings;
    state.save_settings();

    let mut exclusion_changed = false;
    let list = {
        let mut displays = state.displays.lock().unwrap();
        for d in displays.iter_mut() {
            let now = d.uuid.as_ref().map(|u| excluded.contains(u)).unwrap_or(false);
            if now != d.excluded {
                d.excluded = now;
                exclusion_changed = true;
            }
        }
        displays.clone()
    };
    if exclusion_changed {
        let _ = app.emit("displays-changed", &list);
    }
    crate::tray::rebuild(app);
}

#[tauri::command]
pub fn set_settings(app: AppHandle, state: State<AppState>, mut settings: Settings) {
    // Exclusions are tray-owned; the popover's snapshot may be stale — never
    // let its round-trip revert them.
    settings.excluded = state.settings.lock().unwrap().excluded.clone();
    update_settings(&app, settings);
}

#[tauri::command]
pub fn ax_status() -> bool {
    crate::keys::ax_trusted()
}

#[tauri::command]
pub fn open_accessibility_settings() {
    let _ = std::process::Command::new("open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        .spawn();
}

#[tauri::command]
pub fn get_autostart(app: AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
pub fn set_autostart(app: AppHandle, enabled: bool) {
    let autolaunch = app.autolaunch();
    let _ = if enabled { autolaunch.enable() } else { autolaunch.disable() };
    crate::tray::rebuild(&app); // keep the tray checkmark honest
}
