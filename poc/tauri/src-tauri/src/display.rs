use core_graphics::display::CGDisplay;
use core_graphics::event::CGEvent;
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use objc2_app_kit::NSScreen;
use objc2_foundation::{MainThreadMarker, NSNumber, NSString};
use serde::Serialize;
use std::collections::HashMap;

pub const APPLE_VENDOR_ID: u32 = 0x610;

#[derive(Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Backend {
    /// Built-in panel or Apple external (Studio Display, XDR, UltraFine) via DisplayServices.
    Apple,
    /// Non-Apple external via DDC/CI.
    Ddc,
    /// No control path found (e.g. DisplayLink dock, DDC disabled in monitor OSD).
    None,
}

#[derive(Serialize, Clone, Debug)]
pub struct DisplayInfo {
    pub id: u32,
    pub name: String,
    pub builtin: bool,
    pub backend: Backend,
    /// 0.0..=1.0, cached last-known value.
    pub brightness: f32,
    /// Hidden from the popover and skipped by keys/master (user setting).
    pub excluded: bool,
    /// Stable identity for persistence (levels, exclusions).
    #[serde(skip)]
    pub uuid: Option<String>,
    /// Bumped on every user write; lets a refresh detect writes that raced it.
    #[serde(skip)]
    pub write_gen: u64,
}

/// NSScreen localized names keyed by CGDirectDisplayID. Main thread only.
pub fn display_names(mtm: MainThreadMarker) -> HashMap<u32, String> {
    let mut names = HashMap::new();
    let key = NSString::from_str("NSScreenNumber");
    for screen in NSScreen::screens(mtm).iter() {
        let desc = screen.deviceDescription();
        if let Some(num) = desc.objectForKey(&key) {
            if let Ok(num) = num.downcast::<NSNumber>() {
                names.insert(num.unsignedIntValue(), screen.localizedName().to_string());
            }
        }
    }
    names
}

pub fn active_display_ids() -> Vec<u32> {
    CGDisplay::active_displays().unwrap_or_default()
}

pub fn is_builtin(id: u32) -> bool {
    CGDisplay::new(id).is_builtin()
}

pub fn vendor(id: u32) -> u32 {
    CGDisplay::new(id).vendor_number()
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGDisplayMirrorsDisplay(display: u32) -> u32;
    fn CGDisplayCreateUUIDFromDisplayID(display: u32) -> core_foundation_sys::uuid::CFUUIDRef;
}

/// True if this display mirrors another (controlling the primary covers it).
pub fn mirrors_another(id: u32) -> bool {
    unsafe { CGDisplayMirrorsDisplay(id) != 0 }
}

/// True if the point sits in the menu-bar strip (top ~28pt) of any display.
/// Used to self-heal a stuck over-tray flag: a scroll elsewhere can't be a
/// tray-icon scroll. ponytail: strip-level test, not icon-rect precision —
/// tighten with the tray rect from TrayIconEvent if it ever matters.
pub fn point_in_menu_bar(x: f64, y: f64) -> bool {
    active_display_ids().iter().any(|&id| {
        let b = CGDisplay::new(id).bounds();
        x >= b.origin.x
            && x < b.origin.x + b.size.width
            && y >= b.origin.y
            && y - b.origin.y < 28.0
    })
}

/// Stable identity across replug/reboot (CGDirectDisplayIDs are not stable).
pub fn stable_uuid(id: u32) -> Option<String> {
    use core_foundation::base::TCFType;
    unsafe {
        let uuid_ref = CGDisplayCreateUUIDFromDisplayID(id);
        if uuid_ref.is_null() {
            return None;
        }
        let uuid = core_foundation::uuid::CFUUID::wrap_under_create_rule(uuid_ref);
        let s = core_foundation_sys::uuid::CFUUIDCreateString(
            std::ptr::null(),
            uuid.as_concrete_TypeRef(),
        );
        Some(core_foundation::string::CFString::wrap_under_create_rule(s).to_string())
    }
}

/// Display bounds as (x, y, w, h) in CG global coordinates (points, top-left
/// origin) — the same space Tauri window positions use.
pub fn bounds(id: u32) -> (f64, f64, f64, f64) {
    let b = CGDisplay::new(id).bounds();
    (b.origin.x, b.origin.y, b.size.width, b.size.height)
}

/// The display currently containing the mouse pointer.
/// CGEvent location and CGDisplayBounds share the CG global (top-left origin)
/// coordinate space, so this is a plain hit-test — no y-flip.
pub fn display_under_mouse() -> Option<u32> {
    let source = CGEventSource::new(CGEventSourceStateID::CombinedSessionState).ok()?;
    let loc = CGEvent::new(source).ok()?.location();
    let ids = active_display_ids();
    ids.iter()
        .copied()
        .find(|&id| CGDisplay::new(id).bounds().contains(&loc))
        .or_else(|| ids.first().copied())
}
