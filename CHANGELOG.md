# Changelog

All notable changes to Luma are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Luma uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0-beta.1] - 2026-07-21

_First public beta — native Swift, 1.2 MB, zero dependencies._

### Added

- **Brightness keys for every display.** Your keyboard's brightness keys — and third-party keyboards, media keys, and QMK/VIA rotary knobs — now adjust every screen, not just the built-in panel. Apple displays (built-in, Studio Display, Pro Display XDR, UltraFine) go through Apple's native path; everything else over DDC/CI, including on Apple Silicon.
- **Route keys where you mean.** Adjust all displays at once, or just the one under your pointer. Hold a modifier (⌥ by default, configurable) to flip to the other routing for a single press.
- **Sub-zero dimming.** A "Dim below minimum" toggle takes any slider below the hardware floor with a software gamma stage — a too-bright panel can finally go dark at night. Displays with no hardware control path (DisplayLink, mirrored, DDC disabled) become software-dimmable too, instead of uncontrollable.
- **A menu bar icon that's a gauge.** A half-sun on a horizon whose rays track brightness — 3 dim, 7 full, a moon when a screen is blacked out. It animates as you adjust.
- **Notch-style HUD.** A pill that shows the level on the display you're looking at — top, or vertical from the left/right edge. On notched MacBooks it becomes the notch, sliding out from behind it.
- **Menu bar control deck.** Right-click for presets, per-display levels, pause, and exclusions. Left-click for sliders. Scroll over the icon to adjust. Save named profiles ("Day", "Movie", "Present") and apply them anywhere.
- **Automation, no CLI needed.** A `luma://` URL scheme (`set`, `up`/`down`, `profile`, `pause`) drives Luma from Shortcuts, Raycast, or any script. Hand-edit `settings.json` and it applies live.
- **Stays out of your way.** No dock icon, launch at login, restore-on-reconnect for DDC monitors that reset on power-cycle, and a flight-recorder log in Copy Diagnostics for bug reports.

- **A settings menu in the panel.** The gear beside the Luma wordmark opens profiles, display refresh, diagnostics, update checks, and quit — everything that doesn't earn a permanent row, without hunting for a right-click.
- **Updates that explain themselves.** Luma checks GitHub once a day and, when there's something newer, shows the release notes inline with a Download button. No Sparkle, no background daemon, no telemetry — and you can skip a version.
- **The build you're on, in plain sight.** The panel footer shows the version and links to the changelog.
- **Switches you can read at a glance.** A toggle that's on carries the same warm fill as the buttons beside it, instead of the system switch's near-identical on and off states.

### Fixed

- **DDC reads never worked.** The I2C read passed the write sub-address instead of `0`, so every monitor returned garbage.
- **DDC went to the wrong monitor.** External ports were paired to displays by enumeration order; they're matched by the panel's own EDID identity now.
- **Read requests carried a bad checksum**, which stricter monitors reject. Packets are sent twice now, as every other implementation does.
- **Mirrored displays were unreachable.** Every member of a mirror set is controllable now.
- **Sliders that did nothing.** Displays that refuse a gamma table (AirPlay, Sidecar, DisplayLink) were still given a software-dimming slider.
- **Waking from sleep lost the restore.** The DDC bus is unresponsive for seconds after wake; the restore now waits.
- **The menu bar icon froze while dragging a slider.**

### Notes

- Apple Silicon, macOS 13+. Free forever, MIT-licensed, no telemetry, no accounts, no caps.
- Ships unsigned (no paid Apple Developer program between you and a brightness slider). First launch: right-click → Open → Open, or `xattr -dr com.apple.quarantine /Applications/Luma.app`.
