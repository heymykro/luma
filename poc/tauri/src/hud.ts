import { listen } from "@tauri-apps/api/event";

const pill = document.querySelector<HTMLElement>("#pill")!;

listen<{ value: number; pos: "top" | "left" | "right" }>("hud-update", (e) => {
  document.body.className = `pos-${e.payload.pos}`;
  pill.style.setProperty("--v", String(Math.max(0.04, e.payload.value)));
  // Next frame so a position change applies before the slide-in transition.
  requestAnimationFrame(() => document.body.classList.add("show"));
});

listen("hud-hide", () => {
  document.body.classList.remove("show");
});
