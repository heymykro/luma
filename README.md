# Luma

**Brightness for every display, from your menu bar and your keyboard.**

macOS ships no brightness control at all for non-Apple monitors, routes plain
brightness keys to the built-in panel first, and hides Apple-external control
behind a Ctrl+key shortcut that custom keyboards can't even send. Popular
utilities meter free adjustments by the day or paywall the basics. Luma is a
small, free, open-source menu-bar app that just does the thing:

- **Per-display sliders + an "All Displays" master slider** in a menu-bar popover (no dock icon).
- **Keyboard brightness keys work on every display**: route them to *all displays* or *the display under your mouse pointer*; hold a modifier (**⌥** by default, configurable: ⌥/⌃/⇧/⌘) to temporarily use the other routing.
- **All display types**: built-in panels and Apple displays (Studio Display, Pro Display XDR, UltraFine) via Apple's native brightness path, everything else via DDC/CI on Apple Silicon.
- Works with **any keyboard**: standard brightness keys (HID consumer usages), Apple-style media keys (including rotary knobs on QMK/VIA boards), and optional F14/F15 legacy keys.
- **Notch-style HUD** (black pill, top of screen, or vertical from the left/right edge), scroll the menu bar icon to adjust, hotplug detection with brightness restore, launch at login, no telemetry, no accounts, no caps.

## Requirements

**Apple Silicon only** (M1 and later), macOS 13 Ventura or newer.

Intel Macs are not supported yet. macOS exposes a monitor's DDC channel through
an entirely different API there (`IOFramebuffer` + `IOI2CSendRequest` rather
than `IOAVService`), and that backend isn't written. It will ship when it can be
tested on real Intel hardware rather than before.

## Install

Homebrew:

```sh
brew tap heymykro/tap
brew trust heymykro/tap
brew install --cask --no-quarantine luma
```

`brew trust` is required: Homebrew 6 refuses casks from third-party taps until
you trust one, and fails rather than prompting.

Or grab the latest build from [Releases](../../releases) and drag Luma to
Applications.

The app is not notarized (it's ad-hoc signed), so on first launch macOS will
complain: right-click **Luma.app → Open → Open**, or clear quarantine with
`xattr -dr com.apple.quarantine /Applications/Luma.app`.

### Permissions

- **Accessibility**: required *only* for intercepting keyboard brightness keys. Sliders work without it. macOS prompts on first launch; you can also grant later from the popover.

## Repository layout

Two implementations live here:

| Path | What | Status |
|---|---|---|
| [`Luma/`](Luma/) | **Native Swift app** (AppKit + SwiftUI, Swift Package Manager) | The release. ~1.4 MB bundle, no webview. |
| [`poc/tauri/`](poc/tauri/) | Tauri v2 proof of concept (Rust + web UI) | Frozen. Where the engine was designed and verified; kept as reference. |

The Swift app is a faithful port of the POC's engine; the Rust sources are
the annotated spec for every constant and edge case (retry counts, write
spacing, race guards). If you change engine behavior in `Luma/`, check the
matching Rust file for the reasoning first.

### Swift app layout (`Luma/Sources/Luma/`)

| Directory | Contents |
|---|---|
| `Engine/` | `AppleBrightness` (DisplayServices, runtime-loaded) · `DDCService` (IOAVService I2C transport + display matching) · `DDCWorker` (single I2C thread, last-value-wins coalescing, self-healing) · `DisplayManager` (topology, classification, geometry) · `BrightnessController` (routing, rescan, restore-on-reconnect) |
| `Input/` | `KeyTap` (CGEventTap: both key event routes, scroll-over-tray, flip modifier, watchdog) · `Accessibility` |
| `State/` | `Settings` (Codable, POC-compatible JSON) · `Store` (thread-safe canonical state) |
| `UI/` | `StatusItemController` · `TrayMenu` · `PopoverPanel` (non-activating panel) · `PopoverView` (SwiftUI) · `HUDController` |
| `Support/` | `LaunchAtLogin` (SMAppService) · `Diagnostics` |

## How it works

| Display | Path |
|---|---|
| Built-in panel, Apple Studio Display, Pro Display XDR, LG UltraFine | `DisplayServices.framework` (private API, same path Control Center uses), loaded at runtime |
| Other external monitors | DDC/CI over I²C via `IOAVService` (Apple Silicon), resolved at runtime |

Keyboard interception is an active `CGEventTap` that consumes brightness key
events before macOS handles them, then fans the change out per your routing
mode. Two event routes are covered: plain keycodes 144/145 (most third-party
keyboards) and `NX_SYSDEFINED` media-key events (Apple keyboards and some
boards/knobs on recent macOS). DDC writes are coalesced last-value-wins on a
dedicated worker thread with retry/self-healing, because Apple Silicon I²C is
flaky by nature (~30% raw read failure is normal).

Because Luma uses private Apple frameworks, it can never ship in the Mac App
Store; that's why every serious brightness tool in this category is
distributed outside it too.

## Known limitations

- Apple Silicon only (the DDC path uses `IOAVService`; Intel would need an `IOFramebuffer` backend).
- DDC doesn't pass through DisplayLink docks and some USB hubs.
- Monitors must have DDC/CI enabled in their OSD menu.
- No dimming below the hardware minimum (gamma-table dimming); planned.
- HDMI ports on M1 / base M2 Macs have quirky DDC support.

## Building

### Swift app (the release)

Xcode Command Line Tools are the only requirement.

```sh
cd Luma
make app        # release build -> build/Luma.app (ad-hoc signed)
swift build     # compile check / debug binary
open Package.swift  # to work in Xcode
```

### Tauri POC

Requires Rust (stable), Node 20+, pnpm.

```sh
cd poc/tauri
pnpm install
pnpm tauri dev
```

Dev note (both versions): rebuilding an ad-hoc-signed binary resets its
Accessibility grant (`tccutil reset Accessibility <bundle id>` clears the
stale entry).

## Contributing

Issues and PRs welcome. Ground rules to keep the app what it is:

- **Small and single-purpose.** Brightness in, brightness out. Features that need their own settings window probably belong in another app.
- **Engine changes need the "why".** The DDC/tap code is full of deliberate timing and retry choices; each one has a comment (and a matching Rust source in the POC). Keep the comments truthful.
- **No new dependencies** without a very good reason; the app currently has zero.
- **No telemetry, ever.**

## License

[MIT](LICENSE)
