//! Keyboard brightness-key interception via an active CGEventTap.
//!
//! Brightness keys arrive by two routes, and we intercept both:
//! - plain keyDown keycodes: 144/145 (HID consumer usages 0x6F/0x70 on most
//!   third-party keyboards) and opt-in 107/113 (legacy F14/F15);
//! - NX_SYSDEFINED (type 14, subtype 8) media-key events with
//!   NX_KEYTYPE_BRIGHTNESS_UP(2)/DOWN(3) — Apple keyboards, and some
//!   third-party boards on macOS 26 (e.g. Jiffy75 rotary knob).
//! Consuming the NX route means built-in keyboard brightness keys follow
//! Luma's routing modes too. Requires the Accessibility permission.

use crate::commands::{self, AppState, KeyMode};
use crate::display::{self, Backend};
use crate::engine;
use objc2_app_kit::NSEvent;
use objc2_core_foundation::{
    kCFRunLoopCommonModes, CFAbsoluteTimeGetCurrent, CFMachPort, CFRetained, CFRunLoop,
    CFRunLoopTimer, CFRunLoopTimerContext,
};
use objc2_core_graphics::{
    CGEvent, CGEventField, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement,
    CGEventTapProxy, CGEventType,
};
use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::OnceLock;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};

const STEP: f32 = 1.0 / 16.0;
const VK_F14: i64 = 107;
const VK_F15: i64 = 113;
// Verified live on this machine: 144 dims up, 145 dims down.
const VK_BRIGHTNESS_UP: i64 = 144;
const VK_BRIGHTNESS_DOWN: i64 = 145;

const NX_SYSDEFINED: u32 = 14;
const NX_SUBTYPE_MEDIA_KEY: i16 = 8;
const NX_KEYTYPE_BRIGHTNESS_UP: isize = 2;
const NX_KEYTYPE_BRIGHTNESS_DOWN: isize = 3;

const SCROLL_WHEEL: u32 = 22; // kCGEventScrollWheel
const SCROLL_POINT_DELTA_AXIS1: u32 = 96; // kCGScrollWheelEventPointDeltaAxis1
// Brightness change per scroll pixel. If your wheel feels inverted, the sign
// convention of pointDeltaAxis1 differs on your input device — flip here.
const SCROLL_GAIN: f32 = 0.002;


mod ax {
    use core_foundation::base::TCFType;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
    use core_foundation::string::{CFString, CFStringRef};

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> bool;
        fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
        static kAXTrustedCheckOptionPrompt: CFStringRef;
    }

    pub fn trusted() -> bool {
        unsafe { AXIsProcessTrusted() }
    }

    /// Check trust, showing the system Accessibility prompt if not granted.
    pub fn prompt() -> bool {
        unsafe {
            let key = CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt);
            let dict = CFDictionary::from_CFType_pairs(&[(
                key.as_CFType(),
                CFBoolean::true_value().as_CFType(),
            )]);
            AXIsProcessTrustedWithOptions(dict.as_concrete_TypeRef())
        }
    }
}

pub use ax::trusted as ax_trusted;

struct TapCtx {
    // (signed brightness delta, invert routing) — invert is true while the
    // configured flip modifier is held, temporarily swapping the routing.
    tx: Sender<(f32, bool)>,
    app: AppHandle,
    port: OnceLock<CFRetained<CFMachPort>>,
    ax_ok: AtomicBool,
}

fn flip_held(event: &CGEvent, state: &AppState) -> bool {
    let mask = state.flip_mask.load(Ordering::Relaxed);
    CGEvent::flags(Some(event)).bits() & mask != 0
}

/// Watchdog (fires on the tap thread's run loop every 5s): re-enables taps
/// the OS silently disabled, and reports Accessibility revocation/re-grant.
unsafe extern "C-unwind" fn watchdog(_timer: *mut CFRunLoopTimer, info: *mut c_void) {
    let ctx = unsafe { &*(info as *const TapCtx) };
    if let Some(port) = ctx.port.get() {
        if !CGEvent::tap_is_enabled(port) {
            CGEvent::tap_enable(port, true);
        }
    }
    let trusted = ax::trusted();
    if ctx.ax_ok.swap(trusted, Ordering::Relaxed) != trusted {
        let _ = ctx.app.emit("ax-changed", trusted);
    }
}

unsafe extern "C-unwind" fn tap_callback(
    _proxy: CGEventTapProxy,
    etype: CGEventType,
    event: NonNull<CGEvent>,
    user_info: *mut c_void,
) -> *mut CGEvent {
    let ctx = unsafe { &*(user_info as *const TapCtx) };

    if etype == CGEventType::TapDisabledByTimeout {
        if let Some(port) = ctx.port.get() {
            CGEvent::tap_enable(port, true);
        }
        return event.as_ptr();
    }

    let state = ctx.app.state::<AppState>();
    if state.paused.load(Ordering::Relaxed) {
        return event.as_ptr(); // paused: everything passes through untouched
    }

    if etype == CGEventType::KeyDown {
        let keycode = CGEvent::integer_value_field(
            Some(unsafe { event.as_ref() }),
            CGEventField::KeyboardEventKeycode,
        );
        let legacy = state.legacy_f_keys.load(Ordering::Relaxed);
        let dir = match keycode {
            VK_BRIGHTNESS_UP => Some(true),
            VK_BRIGHTNESS_DOWN => Some(false),
            VK_F15 if legacy => Some(true),
            VK_F14 if legacy => Some(false),
            _ => None,
        };
        if let Some(up) = dir {
            let invert = flip_held(unsafe { event.as_ref() }, &state);
            let _ = ctx.tx.send((if up { STEP } else { -STEP }, invert));
            return std::ptr::null_mut(); // consume — macOS never sees the key
        }
    }

    // NX_SYSDEFINED media keys (Apple keyboards, Jiffy75 knob, …).
    if etype.0 == NX_SYSDEFINED {
        if let Some(ns) = unsafe { NSEvent::eventWithCGEvent(event.as_ref()) } {
            if ns.subtype().0 == NX_SUBTYPE_MEDIA_KEY {
                let data1 = ns.data1();
                let key = (data1 >> 16) & 0xFFFF;
                if key == NX_KEYTYPE_BRIGHTNESS_UP || key == NX_KEYTYPE_BRIGHTNESS_DOWN {
                    // Step on key-down; consume the key-up too so macOS never
                    // sees an unmatched half of the press.
                    if ((data1 >> 8) & 0xFF) == 0x0A {
                        let up = key == NX_KEYTYPE_BRIGHTNESS_UP;
                        let invert = flip_held(unsafe { event.as_ref() }, &state);
                        let _ = ctx.tx.send((if up { STEP } else { -STEP }, invert));
                    }
                    return std::ptr::null_mut();
                }
            }
        }
    }

    // Scrolling over the tray icon adjusts brightness. Passed through (the
    // menu bar doesn't scroll anyway); over_tray is set by tray Enter/Leave —
    // but Leave isn't reliably delivered (menu tracking swallows it), so
    // verify the pointer is actually in a menu-bar strip and self-heal if not.
    if etype.0 == SCROLL_WHEEL && state.over_tray.load(Ordering::Relaxed) {
        let loc = CGEvent::location(Some(unsafe { event.as_ref() }));
        if !display::point_in_menu_bar(loc.x, loc.y) {
            state.over_tray.store(false, Ordering::Relaxed);
            return event.as_ptr();
        }
        let delta = CGEvent::integer_value_field(
            Some(unsafe { event.as_ref() }),
            objc2_core_graphics::CGEventField(SCROLL_POINT_DELTA_AXIS1),
        );
        if delta != 0 {
            let invert = flip_held(unsafe { event.as_ref() }, &state);
            let _ = ctx.tx.send((delta as f32 * SCROLL_GAIN, invert));
        }
    }

    event.as_ptr()
}

/// Wait for Accessibility trust (prompting once), then run the tap forever.
pub fn spawn(app: AppHandle) {
    thread::Builder::new()
        .name("key-tap".into())
        .spawn(move || {
            if !ax::prompt() {
                while !ax::trusted() {
                    thread::sleep(Duration::from_secs(3));
                }
            }
            let _ = app.emit("ax-changed", true);

            let (tx, rx) = channel::<(f32, bool)>();
            let worker_app = app.clone();
            thread::Builder::new()
                .name("key-steps".into())
                .spawn(move || {
                    while let Ok((first, inv)) = rx.recv() {
                        // Coalesce bursts (fast scrolls arrive per-pixel) into
                        // one net adjustment per worker pass.
                        let mut delta = first;
                        let mut invert = inv;
                        while let Ok((d, i)) = rx.try_recv() {
                            delta += d;
                            invert = i;
                        }
                        if delta != 0.0 {
                            adjust(&worker_app, delta, invert);
                        }
                    }
                })
                .expect("spawn key-steps");

            let ctx: &'static TapCtx = Box::leak(Box::new(TapCtx {
                tx,
                app,
                port: OnceLock::new(),
                ax_ok: AtomicBool::new(true),
            }));
            let mask: u64 =
                (1 << CGEventType::KeyDown.0) | (1 << NX_SYSDEFINED) | (1 << SCROLL_WHEEL);
            let port = match unsafe {
                CGEvent::tap_create(
                    CGEventTapLocation::SessionEventTap,
                    CGEventTapPlacement::HeadInsertEventTap,
                    CGEventTapOptions(0), // active (consuming) tap
                    mask,
                    Some(tap_callback),
                    ctx as *const TapCtx as *mut c_void,
                )
            } {
                Some(p) => p,
                None => {
                    eprintln!("[luma] event tap creation failed (Accessibility revoked?)");
                    return;
                }
            };
            let _ = ctx.port.set(port.clone());
            let source = CFMachPort::new_run_loop_source(None, Some(&port), 0);
            let rl = CFRunLoop::current().expect("runloop");
            rl.add_source(source.as_deref(), unsafe { kCFRunLoopCommonModes });

            let mut timer_ctx = CFRunLoopTimerContext {
                version: 0,
                info: ctx as *const TapCtx as *mut c_void,
                retain: None,
                release: None,
                copyDescription: None,
            };
            let timer = unsafe {
                CFRunLoopTimer::new(
                    None,
                    CFAbsoluteTimeGetCurrent() + 5.0,
                    5.0,
                    0,
                    0,
                    Some(watchdog),
                    &mut timer_ctx,
                )
            };
            rl.add_timer(timer.as_deref(), unsafe { kCFRunLoopCommonModes });

            eprintln!("[luma] brightness key tap active");
            CFRunLoop::run();
        })
        .expect("spawn key-tap");
}

fn adjust(app: &AppHandle, delta: f32, invert: bool) {
    let state = app.state::<AppState>();
    let mut mode = state.settings.lock().unwrap().key_mode;
    if invert {
        // ⌥ held: temporarily the other routing.
        mode = match mode {
            KeyMode::All => KeyMode::UnderMouse,
            KeyMode::UnderMouse => KeyMode::All,
        };
    }

    let targets: Vec<(u32, Backend, f32)> = {
        let displays = state.displays.lock().unwrap();
        let under_mouse = display::display_under_mouse();
        displays
            .iter()
            .filter(|d| d.backend != Backend::None && !d.excluded)
            .filter(|d| mode == KeyMode::All || Some(d.id) == under_mouse)
            .map(|d| (d.id, d.backend, d.brightness))
            .collect()
    };

    let mut hud_value = None;
    for (id, backend, cached) in targets {
        // Apple brightness drifts (auto-brightness, Control Center) — step from live.
        let current = if backend == Backend::Apple {
            engine::apple_get(id).unwrap_or(cached)
        } else {
            cached
        };
        let value = (current + delta).clamp(0.0, 1.0);
        commands::apply_brightness(app, id, value);
        let _ = app.emit("brightness-changed", serde_json::json!({ "id": id, "value": value }));
        hud_value = Some(value);
    }

    if let Some(value) = hud_value {
        show_hud(app, value);
    }
}

// Horizontal (top) and vertical (left/right) pill window sizes.
const HUD_H_SIZE: (f64, f64) = (300.0, 76.0);
const HUD_V_SIZE: (f64, f64) = (76.0, 300.0);

fn show_hud(app: &AppHandle, value: f32) {
    let Some(hud) = app.get_webview_window("hud") else {
        return;
    };
    let pos = {
        let state = app.state::<AppState>();
        let s = state.settings.lock().unwrap();
        s.hud_position
    };
    if let Some(id) = display::display_under_mouse() {
        let (x, y, w, h) = display::bounds(id);
        let ((ww, wh), (wx, wy)) = match pos {
            commands::HudPosition::Top => {
                (HUD_H_SIZE, (x + (w - HUD_H_SIZE.0) / 2.0, y))
            }
            commands::HudPosition::Left => {
                (HUD_V_SIZE, (x, y + (h - HUD_V_SIZE.1) / 2.0))
            }
            commands::HudPosition::Right => {
                (HUD_V_SIZE, (x + w - HUD_V_SIZE.0, y + (h - HUD_V_SIZE.1) / 2.0))
            }
        };
        let _ = hud.set_size(tauri::LogicalSize::new(ww, wh));
        let _ = hud.set_position(tauri::LogicalPosition::new(wx, wy));
    }
    let _ = app.emit(
        "hud-update",
        serde_json::json!({ "value": value, "pos": pos }),
    );
    let _ = hud.show();

    // Auto-hide: emit hud-hide (webview slides the pill out), then hide the
    // window once the ~250ms transition is done. Generation-guarded so a new
    // keypress cancels the pending hide.
    let gen = app.state::<AppState>().hud_gen.fetch_add(1, Ordering::Relaxed) + 1;
    let app = app.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(1200));
        let still = app.state::<AppState>().hud_gen.load(Ordering::Relaxed) == gen;
        if still {
            let _ = app.emit("hud-hide", ());
            thread::sleep(Duration::from_millis(260));
            let still = app.state::<AppState>().hud_gen.load(Ordering::Relaxed) == gen;
            if still {
                if let Some(hud) = app.get_webview_window("hud") {
                    let _ = hud.hide();
                }
            }
        }
    });
}
