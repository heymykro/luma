//! Brightness backends: Apple DisplayServices (private framework, runtime-loaded)
//! and DDC/CI via a dedicated worker thread with last-value-wins write coalescing.

use ddc::Ddc;
use ddc_macos::Monitor;
use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- DisplayServices

mod ds {
    use std::sync::OnceLock;

    type CanChangeFn = unsafe extern "C" fn(u32) -> bool;
    type GetFn = unsafe extern "C" fn(u32, *mut f32) -> i32;
    type SetFn = unsafe extern "C" fn(u32, f32) -> i32;

    struct Api {
        _lib: libloading::Library,
        can_change: CanChangeFn,
        get: GetFn,
        set: SetFn,
    }

    // Loaded once; None if the framework or a symbol vanishes in a future macOS —
    // Apple path then reports unsupported instead of crashing.
    static API: OnceLock<Option<Api>> = OnceLock::new();

    fn api() -> Option<&'static Api> {
        API.get_or_init(|| unsafe {
            let lib = libloading::Library::new(
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            )
            .ok()?;
            let can_change = *lib.get::<CanChangeFn>(b"DisplayServicesCanChangeBrightness").ok()?;
            let get = *lib.get::<GetFn>(b"DisplayServicesGetBrightness").ok()?;
            let set = *lib.get::<SetFn>(b"DisplayServicesSetBrightness").ok()?;
            Some(Api { _lib: lib, can_change, get, set })
        })
        .as_ref()
    }

    pub fn can_change(id: u32) -> bool {
        api().map(|a| unsafe { (a.can_change)(id) }).unwrap_or(false)
    }

    pub fn get(id: u32) -> Option<f32> {
        let a = api()?;
        let mut v: f32 = -1.0;
        (unsafe { (a.get)(id, &mut v) } == 0 && v >= 0.0).then_some(v)
    }

    pub fn set(id: u32, v: f32) -> bool {
        api().map(|a| unsafe { (a.set)(id, v.clamp(0.0, 1.0)) } == 0).unwrap_or(false)
    }
}

pub use ds::{can_change as apple_can_change, get as apple_get, set as apple_set};

// ---------------------------------------------------------------- DDC worker

const BRIGHTNESS_VCP: u8 = 0x10;

pub enum DdcMsg {
    /// Re-enumerate monitors and read brightness; replies with id -> Some(0..1),
    /// or None for monitors that enumerate but won't answer reads (write-only).
    Refresh(Sender<HashMap<u32, Option<f32>>>),
    Set(u32, f32),
}

struct DdcState {
    monitors: HashMap<u32, (Monitor, u16)>, // id -> (handle, max raw value)
}

impl DdcState {
    fn refresh(&mut self) -> HashMap<u32, Option<f32>> {
        self.monitors.clear();
        let mut out = HashMap::new();
        for mut mon in Monitor::enumerate().unwrap_or_default() {
            let id = mon.handle().id;
            // Apple displays never speak DDC; don't waste retry time on them.
            if crate::display::vendor(id) == crate::display::APPLE_VENDOR_ID {
                continue;
            }
            match read_with_retries(&mut mon) {
                Some((value, max)) => {
                    out.insert(id, Some(value as f32 / max as f32));
                    self.monitors.insert(id, (mon, max));
                }
                None => {
                    // Reads are flaky (or the monitor is write-only). Keep it
                    // controllable rather than dropping it: assume MCCS max 100.
                    out.insert(id, None);
                    self.monitors.insert(id, (mon, 100));
                }
            }
        }
        out
    }

    fn set(&mut self, id: u32, v: f32) -> bool {
        if let Some((mon, max)) = self.monitors.get_mut(&id) {
            let raw = (v.clamp(0.0, 1.0) * *max as f32).round() as u16;
            for attempt in 0..3 {
                if attempt > 0 {
                    thread::sleep(Duration::from_millis(20));
                }
                if mon.set_vcp_feature(BRIGHTNESS_VCP, raw).is_ok() {
                    return true;
                }
            }
            return false; // handle likely stale (sleep/wake) — caller re-enumerates
        }
        true // unknown id: nothing to heal
    }
}

fn read_with_retries(mon: &mut Monitor) -> Option<(u16, u16)> {
    // ~30% raw read failure rate on Apple Silicon I2C is normal — retry.
    for attempt in 0..4 {
        if attempt > 0 {
            thread::sleep(Duration::from_millis(30));
        }
        if let Ok(v) = mon.get_vcp_feature(BRIGHTNESS_VCP) {
            let max = v.maximum().max(1);
            return Some((v.value().min(max), max));
        }
    }
    None
}

/// Spawn the DDC worker. All I2C traffic happens on this one thread;
/// bursts of Set messages are coalesced last-value-wins per display.
pub fn spawn_ddc_worker() -> Sender<DdcMsg> {
    let (tx, rx): (Sender<DdcMsg>, Receiver<DdcMsg>) = channel();
    thread::Builder::new()
        .name("ddc-worker".into())
        .spawn(move || {
            const WRITE_SPACING: Duration = Duration::from_millis(50);
            let mut state = DdcState { monitors: HashMap::new() };
            let mut pending: HashMap<u32, f32> = HashMap::new();
            let mut heal = false;
            let mut last_write = Instant::now() - WRITE_SPACING;

            // Refresh keeps `pending` — queued writes re-apply against the
            // fresh handles afterwards — and clears `heal` (a refresh IS the
            // heal). A pending Set always lands on hardware after the refresh
            // read, so the caller treats in-flight writes as the newer truth.
            let handle = |msg: DdcMsg,
                              state: &mut DdcState,
                              pending: &mut HashMap<u32, f32>,
                              heal: &mut bool| {
                match msg {
                    DdcMsg::Refresh(reply) => {
                        let _ = reply.send(state.refresh());
                        *heal = false;
                    }
                    DdcMsg::Set(id, v) => {
                        pending.insert(id, v);
                    }
                }
            };

            loop {
                // Block if idle; while a write is pending, wait only until the
                // spacing window elapses so bursts coalesce last-value-wins.
                let msg = if pending.is_empty() {
                    match rx.recv() {
                        Ok(m) => Some(m),
                        Err(_) => return,
                    }
                } else {
                    let wait = WRITE_SPACING.saturating_sub(last_write.elapsed());
                    match rx.recv_timeout(wait) {
                        Ok(m) => Some(m),
                        Err(RecvTimeoutError::Timeout) => None,
                        Err(RecvTimeoutError::Disconnected) => return,
                    }
                };
                if let Some(msg) = msg {
                    handle(msg, &mut state, &mut pending, &mut heal);
                    while let Ok(m) = rx.try_recv() {
                        handle(m, &mut state, &mut pending, &mut heal);
                    }
                }
                // Not yet time to write? Loop; recv_timeout above paces us.
                if !pending.is_empty() && last_write.elapsed() < WRITE_SPACING {
                    continue;
                }
                // Stale handles (e.g. after sleep/wake with no reconfigure
                // callback) fail writes — rebuild once, then retry next value.
                if heal {
                    let _ = state.refresh();
                    heal = false;
                }
                if !pending.is_empty() {
                    for (id, v) in pending.drain() {
                        if !state.set(id, v) {
                            heal = true;
                        }
                    }
                    last_write = Instant::now();
                }
            }
        })
        .expect("failed to spawn ddc worker");
    tx
}
