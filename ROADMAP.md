# Roadmap

Where Luma is going, and what's deliberately parked. Nothing here is a promise
with a date on it. It is a working list, kept honest about what's actually been
verified.

Suggestions welcome: [open an issue](https://github.com/heymykro/luma/issues/new).

## Next up

**Night Shift / warmth control.** macOS already ships this, and it's drivable:
`CBBlueLightClient` in the private CoreBrightness framework exposes
`setStrength:commit:`, `setEnabled:`, `setMode:` and `setSchedule:`. Verified
present and working. Worth doing through the OS rather than as our own
gamma layer, because Luma already owns the gamma table for sub-zero dimming, so
two gamma stages would fight, and whichever wrote last would win. Night Shift is
a separate stage, so warmth and dimming compose. It also survives sleep/wake and
display reconfiguration for free, which our gamma layer does not.

**Schedules.** Natural companion to the above, and `setSchedule:` gives sunset
and sunrise without reimplementing solar maths. Open question worth settling
first: should a schedule drive brightness, warmth, or a whole profile? Profiles
is probably the most flexible and the least new machinery, since that already
exists.

**Intel support.** Blocked on hardware, not effort. The DDC transport is
`IOAVService`, which only exists on Apple Silicon; Intel needs a second backend
over `IOFramebuffer` + `IOI2CSendRequest`. The protocol layer above it
(VCP codes, packet framing, checksums) is already correct and verified, so it's
maybe 150 lines. It ships when someone with an Intel Mac and a couple of
external displays can test it the same day, not before. Four separate bugs hid
in this exact subsystem before it worked; shipping a blind rewrite of it would
be asking for a fifth.

## Ideas

Unscheduled, roughly in order of how often they come up.

- **Per-display response curves.** Some panels are perceptually wrong in the
  bottom third; a per-display gamma/curve setting would fix it without touching
  the others.
- **Shortcuts / App Intents.** The `luma://` URL scheme already drives Shortcuts,
  but real App Intents would show up natively with proper parameters.
- **Ambient follow.** Track the built-in light sensor and move externals with it,
  so a third-party monitor behaves like the laptop panel does.
- **Global hotkeys.** For people whose keyboards have no brightness keys at all.
- **Input switching (KVM).** VCP 0x60 over the same transport that already works.
  Cheap to add, genuinely useful on a shared monitor.
- **Contrast and volume.** Same story: VCP 0x12 and 0x62.
- **XDR headroom.** Unlock the full brightness range on Pro Display XDR and
  built-in XDR panels beyond the standard slider ceiling.
- **CLI.** Deliberately deferred. The URL scheme covers most scripting today.

## Known gaps

Things that are wrong or unverified right now, written down so they don't get
quietly forgotten.

- **Two identical monitors reporting no EDID serial** can pair to the wrong
  port. Displays are matched by the panel identity their framebuffer publishes;
  when two are indistinguishable, the fallback is iteration order. Scoring the
  framebuffer's `IODisplayLocation` against the display's would settle it.
- **DDC over docks and hubs** frequently doesn't work, and macOS exposes no way
  to detect it: the monitor simply never answers. Nothing to fix on our side;
  documented in the FAQ so the bug reports have an answer.
- **The DDC reply path has only ever been exercised on one monitor.** Reads,
  writes and read-back are verified, but on a single non-Apple panel. More
  hardware coverage is the main thing that would raise confidence.
- **Sleep/wake healing** waits a fixed 5s before touching DDC after wake. That
  window is a guess informed by how long the channel stays dead; it may want to
  be adaptive.

## Done

- Brightness for Apple displays, DDC externals, and a software fallback for
  everything else
- Brightness keys, media keys and rotary knobs, routed to all displays or the
  one under the pointer
- Sub-zero dimming below the hardware floor
- Menu bar gauge, notch-style HUD, profiles and presets
- `luma://` URL scheme
- In-app update checks with release notes
- Homebrew cask: `brew install --cask heymykro/tap/luma`
