import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow, LogicalSize } from "@tauri-apps/api/window";

type Backend = "apple" | "ddc" | "none";
interface Display {
  id: number;
  name: string;
  backend: Backend;
  brightness: number;
  excluded: boolean;
}
type FlipModifier = "option" | "control" | "shift" | "command";
interface Settings {
  keyMode: "all" | "under-mouse";
  legacyFKeys: boolean;
  hudPosition: "top" | "left" | "right";
  flipModifier: FlipModifier;
}

const MOD_SYMBOL: Record<FlipModifier, string> = {
  option: "⌥",
  control: "⌃",
  shift: "⇧",
  command: "⌘",
};

const displaysEl = document.querySelector<HTMLElement>("#displays")!;
const settingsEl = document.querySelector<HTMLElement>("#settings")!;
const appWindow = getCurrentWindow();

let displays: Display[] = [];
let settings: Settings = {
  keyMode: "all",
  legacyFKeys: false,
  hudPosition: "top",
  flipModifier: "option",
};
let axGranted = true;

// setter(v) updates a slider's fill + readout without re-rendering.
const sliders = new Map<number, (v: number) => void>();
let masterSet: ((v: number) => void) | null = null;

function controllable(): Display[] {
  return displays.filter((d) => d.backend !== "none" && !d.excluded);
}

function updateMaster() {
  if (!masterSet) return;
  const c = controllable();
  if (c.length < 2) return;
  masterSet(c.reduce((s, d) => s + d.brightness, 0) / c.length);
}

// Throttle brightness IPC to ~30/s per target; trailing call always fires.
function throttle<A extends unknown[]>(fn: (...args: A) => void, ms: number) {
  let last = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  return (...args: A) => {
    const now = Date.now();
    clearTimeout(timer);
    if (now - last >= ms) {
      last = now;
      fn(...args);
    } else {
      timer = setTimeout(() => {
        last = Date.now();
        fn(...args);
      }, ms - (now - last));
    }
  };
}

const sendBrightness = new Map<number, (value: number) => void>();
function senderFor(id: number): (value: number) => void {
  let s = sendBrightness.get(id);
  if (!s) {
    s = throttle((value: number) => invoke("set_brightness", { id, value }), 33);
    sendBrightness.set(id, s);
  }
  return s;
}
const sendAll = throttle((value: number) => invoke("set_all_brightness", { value }), 33);

function pct(v: number): string {
  return `${Math.round(v * 100)}%`;
}

// Static markup, same pattern tile() uses for its icons.
const SUN_SVG = `<svg class="sun" width="16" height="16" viewBox="0 0 16 16"><circle cx="8" cy="8" r="3.1" fill="currentColor"/><g stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><line x1="8" y1="1.2" x2="8" y2="2.8"/><line x1="8" y1="13.2" x2="8" y2="14.8"/><line x1="1.2" y1="8" x2="2.8" y2="8"/><line x1="13.2" y1="8" x2="14.8" y2="8"/><line x1="3.19" y1="3.19" x2="4.32" y2="4.32"/><line x1="11.68" y1="11.68" x2="12.81" y2="12.81"/><line x1="12.81" y1="3.19" x2="11.68" y2="4.32"/><line x1="3.19" y1="12.81" x2="4.32" y2="11.68"/></g></svg>`;

/** Control-Center-style slider group. Returns [element, setValue]. */
function ccSlider(opts: {
  title: string;
  value: number;
  master?: boolean;
  disabled?: boolean;
  subtitle?: string;
  onInput: (v: number) => void;
}): [HTMLElement, (v: number) => void] {
  const group = document.createElement("div");
  group.className =
    "group" + (opts.master ? " master" : "") + (opts.disabled ? " disabled" : "");

  const labelrow = document.createElement("div");
  labelrow.className = "labelrow";
  const name = document.createElement("span");
  name.className = "name";
  name.textContent = opts.title;
  const readout = document.createElement("span");
  readout.className = "readout";
  readout.textContent = opts.disabled ? "—" : pct(opts.value);
  labelrow.append(name, readout);

  const slider = document.createElement("div");
  slider.className = "slider";
  slider.tabIndex = opts.disabled ? -1 : 0;
  slider.setAttribute("role", "slider");
  slider.setAttribute("aria-label", `${opts.title} brightness`);
  slider.setAttribute("aria-valuemin", "0");
  slider.setAttribute("aria-valuemax", "100");
  const track = document.createElement("div");
  track.className = "track";
  const fill = document.createElement("div");
  fill.className = "fill";
  track.append(fill);
  slider.append(track);
  slider.insertAdjacentHTML("beforeend", SUN_SVG);

  let value = opts.value;
  const paint = (v: number) => {
    value = Math.min(1, Math.max(0, v));
    fill.style.setProperty("--v", String(value));
    readout.textContent = pct(value);
    slider.setAttribute("aria-valuenow", String(Math.round(value * 100)));
  };
  paint(value);

  if (!opts.disabled) {
    const KNOB = 28;
    const valueAt = (clientX: number) => {
      const r = track.getBoundingClientRect();
      return (clientX - r.left - KNOB / 2) / (r.width - KNOB);
    };
    slider.addEventListener("pointerdown", (e) => {
      slider.setPointerCapture(e.pointerId);
      slider.classList.add("dragging");
      readout.classList.add("live");
      paint(valueAt(e.clientX));
      opts.onInput(value);
    });
    slider.addEventListener("pointermove", (e) => {
      if (!slider.classList.contains("dragging")) return;
      paint(valueAt(e.clientX));
      opts.onInput(value);
    });
    const end = () => {
      slider.classList.remove("dragging");
      readout.classList.remove("live");
    };
    slider.addEventListener("pointerup", end);
    slider.addEventListener("pointercancel", end);
    slider.addEventListener("keydown", (e) => {
      const step =
        e.key === "ArrowRight" || e.key === "ArrowUp" ? 0.05
        : e.key === "ArrowLeft" || e.key === "ArrowDown" ? -0.05
        : 0;
      if (step) {
        e.preventDefault();
        paint(value + step);
        opts.onInput(value);
      }
    });
  }

  group.append(labelrow, slider);
  if (opts.subtitle) {
    const sub = document.createElement("div");
    sub.className = "subtitle";
    sub.textContent = opts.subtitle;
    group.append(sub);
  }
  return [group, paint];
}

function render() {
  displaysEl.replaceChildren();
  sliders.clear();
  masterSet = null;

  if (displays.length === 0) {
    const p = document.createElement("p");
    p.className = "empty";
    p.textContent = "No displays found";
    displaysEl.append(p);
    fitWindow();
    return;
  }

  const ctrl = controllable();

  if (ctrl.length > 1) {
    const avg = ctrl.reduce((s, d) => s + d.brightness, 0) / ctrl.length;
    const [master, setMaster] = ccSlider({
      title: "All Displays",
      value: avg,
      master: true,
      onInput: (v) => {
        for (const d of controllable()) {
          d.brightness = v;
          sliders.get(d.id)?.(v);
        }
        sendAll(v);
      },
    });
    masterSet = setMaster;
    displaysEl.append(master, document.createElement("hr"));
  }

  for (const d of displays) {
    if (d.excluded) continue; // hidden here; managed via the tray menu
    const [group, set] = ccSlider({
      title: d.name,
      value: d.brightness,
      disabled: d.backend === "none",
      subtitle: d.backend === "none" ? "No brightness control available" : undefined,
      onInput: (v) => {
        d.brightness = v;
        updateMaster();
        senderFor(d.id)(v);
      },
    });
    if (d.backend !== "none") sliders.set(d.id, set);
    displaysEl.append(group);
  }

  fitWindow();
}

function tile(opts: {
  name: string;
  value: () => string;
  on?: () => boolean;
  icon: string; // inline svg path data
  onClick: () => void;
}): HTMLElement {
  const b = document.createElement("button");
  b.className = "tile" + (opts.on?.() ? " on" : "");
  const disc = document.createElement("span");
  disc.className = "disc";
  disc.innerHTML = `<svg width="13" height="13" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">${opts.icon}</svg>`;
  const label = document.createElement("span");
  label.className = "t-label";
  const n = document.createElement("span");
  n.className = "t-name";
  n.textContent = opts.name;
  const v = document.createElement("span");
  v.className = "t-value";
  v.textContent = opts.value();
  label.append(n, v);
  b.append(disc, label);
  b.addEventListener("click", () => {
    opts.onClick();
    v.textContent = opts.value();
    b.classList.toggle("on", opts.on?.() ?? false);
  });
  return b;
}

/** Labeled segmented switch with a sliding thumb. */
function segmented<T extends string>(opts: {
  label: string;
  options: [T, string][];
  value: () => T;
  onChange: (v: T) => void;
}): HTMLElement {
  const group = document.createElement("div");
  group.className = "seg-group";
  const label = document.createElement("span");
  label.className = "seg-label";
  label.textContent = opts.label;

  const seg = document.createElement("div");
  seg.className = "seg";
  seg.setAttribute("role", "radiogroup");
  seg.setAttribute("aria-label", opts.label);
  const thumb = document.createElement("div");
  thumb.className = "seg-thumb";
  seg.append(thumb);

  const n = opts.options.length;
  thumb.style.width = `calc((100% - 4px) / ${n})`;
  const buttons: HTMLButtonElement[] = [];

  const paint = () => {
    const idx = Math.max(0, opts.options.findIndex(([v]) => v === opts.value()));
    thumb.style.transform = `translateX(${idx * 100}%)`;
    buttons.forEach((b, i) => {
      b.classList.toggle("active", i === idx);
      b.setAttribute("aria-checked", String(i === idx));
    });
  };

  for (const [value, text] of opts.options) {
    const b = document.createElement("button");
    b.setAttribute("role", "radio");
    b.textContent = text;
    b.addEventListener("click", () => {
      opts.onChange(value);
      paint();
    });
    buttons.push(b);
    seg.append(b);
  }
  paint();
  group.append(label, seg);
  return group;
}

const ICONS = {
  login:
    '<path d="M8 1.5a3.2 3.2 0 0 1 3.2 3.2v1.6h.6A1.7 1.7 0 0 1 13.5 8v4.3a1.7 1.7 0 0 1-1.7 1.7H4.2a1.7 1.7 0 0 1-1.7-1.7V8a1.7 1.7 0 0 1 1.7-1.7h.6V4.7A3.2 3.2 0 0 1 8 1.5Zm0 1.4a1.8 1.8 0 0 0-1.8 1.8v1.6h3.6V4.7A1.8 1.8 0 0 0 8 2.9Z"/>',
  fkeys:
    '<path d="M2.5 3h11a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1Zm2 3.2v1h2v3.6h1.2V7.2h.1c.6 0 1-.4 1-.9V6.2c0-.6-.5-1-1-1H5.6c-.6 0-1.1.4-1.1 1Zm5.5-.9v5.5h1.2V8.6h1.6V7.5h-1.6V6.4h2V5.3h-3.2Z"/>',
};

function renderSettings() {
  settingsEl.replaceChildren();

  if (!axGranted) {
    const axRow = document.createElement("div");
    axRow.className = "ax-warning";
    const axLabel = document.createElement("span");
    axLabel.textContent = "Keyboard keys need Accessibility access";
    const axBtn = document.createElement("button");
    axBtn.textContent = "Grant…";
    axBtn.addEventListener("click", () => invoke("open_accessibility_settings"));
    axRow.append(axLabel, axBtn);
    settingsEl.append(axRow);
  }

  const keysSeg = segmented({
    label: "Brightness keys adjust",
    options: [
      ["all", "All Displays"],
      ["under-mouse", "Under Pointer"],
    ],
    value: () => settings.keyMode,
    onChange: (v) => {
      settings.keyMode = v;
      invoke("set_settings", { settings });
    },
  });
  const hint = document.createElement("span");
  hint.className = "seg-hint";
  hint.textContent = `Hold ${MOD_SYMBOL[settings.flipModifier]} while pressing to temporarily use the other`;
  keysSeg.append(hint);

  settingsEl.append(
    keysSeg,
    segmented({
      label: "Flip modifier",
      options: (Object.keys(MOD_SYMBOL) as FlipModifier[]).map((m) => [m, MOD_SYMBOL[m]]),
      value: () => settings.flipModifier,
      onChange: (v) => {
        settings.flipModifier = v;
        invoke("set_settings", { settings });
        hint.textContent = `Hold ${MOD_SYMBOL[v]} while pressing to temporarily use the other`;
      },
    }),
    segmented({
      label: "HUD position",
      options: [
        ["top", "Top"],
        ["left", "Left"],
        ["right", "Right"],
      ],
      value: () => settings.hudPosition,
      onChange: (v) => {
        settings.hudPosition = v;
        invoke("set_settings", { settings });
      },
    }),
  );

  const tiles = document.createElement("div");
  tiles.className = "tiles";

  tiles.append(
    tile({
      name: "Launch at Login",
      icon: ICONS.login,
      value: () => (autostartOn ? "On" : "Off"),
      on: () => autostartOn,
      onClick: () => {
        autostartOn = !autostartOn;
        invoke("set_autostart", { enabled: autostartOn });
      },
    }),
    tile({
      name: "F14 / F15 Keys",
      icon: ICONS.fkeys,
      value: () => (settings.legacyFKeys ? "Brightness" : "Ignored"),
      on: () => settings.legacyFKeys,
      onClick: () => {
        settings.legacyFKeys = !settings.legacyFKeys;
        invoke("set_settings", { settings });
      },
    }),
  );

  settingsEl.append(tiles);
  fitWindow();
}

let autostartOn = false;

let fitQueued = false;
function fitWindow() {
  if (fitQueued) return;
  fitQueued = true;
  requestAnimationFrame(() => {
    fitQueued = false;
    // #app is capped at 100vh, so its scrollHeight alone reports the current
    // window height once #displays starts scrolling — add the hidden content
    // so the window grows to fit everything (up to the 640 ceiling).
    const app = document.querySelector<HTMLElement>("#app")!;
    const h = app.scrollHeight + (displaysEl.scrollHeight - displaysEl.clientHeight);
    appWindow.setSize(new LogicalSize(340, Math.min(h, 640)));
  });
}

async function reload() {
  // Settings can change from the tray menu while the popover is closed.
  settings = await invoke<Settings>("get_settings");
  autostartOn = await invoke<boolean>("get_autostart");
  displays = await invoke<Display[]>("list_displays");
  renderSettings();
  render();
}

document.addEventListener("DOMContentLoaded", async () => {
  axGranted = await invoke<boolean>("ax_status");
  await reload();

  await listen<boolean>("ax-changed", (e) => {
    axGranted = e.payload;
    renderSettings();
  });

  await listen<Display[]>("displays-changed", (e) => {
    displays = e.payload;
    render();
  });

  // Keys / tray / external changes: update sliders in place.
  await listen<{ id: number; value: number }>("brightness-changed", (e) => {
    const d = displays.find((x) => x.id === e.payload.id);
    if (d) d.brightness = e.payload.value;
    sliders.get(e.payload.id)?.(e.payload.value);
    updateMaster();
  });

  // Re-sync every time the popover is opened.
  await appWindow.onFocusChanged(({ payload: focused }) => {
    if (focused) reload();
  });
});
