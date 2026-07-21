//! Headless DDC verification: read brightness of every DDC monitor,
//! nudge it by 5, read back, restore. Run: cargo run --example ddc_probe

use ddc::Ddc;
use ddc_macos::Monitor;
use std::thread::sleep;
use std::time::Duration;

fn get_retry(mon: &mut Monitor) -> Option<(u16, u16)> {
    for attempt in 0..4 {
        if attempt > 0 {
            sleep(Duration::from_millis(30));
        }
        if let Ok(v) = mon.get_vcp_feature(0x10) {
            return Some((v.value(), v.maximum().max(1)));
        }
    }
    None
}

fn main() {
    for mut mon in Monitor::enumerate().expect("enumerate failed") {
        let id = mon.handle().id;
        let name = mon.product_name().unwrap_or_else(|| "?".into());
        println!("monitor id={id} name={name:?}");
        let Some((value, max)) = get_retry(&mut mon) else {
            println!("  read FAILED after retries");
            continue;
        };
        println!("  brightness {value}/{max}");
        let target = if value >= 5 { value - 5 } else { value + 5 };
        match mon.set_vcp_feature(0x10, target) {
            Ok(()) => println!("  wrote {target}"),
            Err(e) => {
                println!("  write FAILED: {e}");
                continue;
            }
        }
        sleep(Duration::from_millis(300));
        let back = get_retry(&mut mon);
        println!("  readback {back:?}");
        sleep(Duration::from_millis(100));
        let _ = mon.set_vcp_feature(0x10, value);
        println!("  restored {value}");
        match back {
            Some((b, _)) if b == target => println!("  PASS"),
            _ => println!("  WARN: readback mismatch (writes may still work; reads are flaky)"),
        }
    }
}
