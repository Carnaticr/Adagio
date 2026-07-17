import { listen } from "@tauri-apps/api/event";
import * as ipc from "./ipc";
import { el, fmtTimer, toast } from "./util";

type RecPhase = "idle" | "recording" | "paused";

let phase: RecPhase = "idle";
let mode = "mic";
let peaks: number[] = [];
const MAX_PEAKS = 600;

let timerEl: HTMLElement;
let waveCanvas: HTMLCanvasElement;
let statusDot: HTMLElement;
let micFill: HTMLElement;
let sysFill: HTMLElement;
let btnRecord: HTMLButtonElement;
let btnPause: HTMLButtonElement;
let btnStop: HTMLButtonElement;
let btnCancel: HTMLButtonElement;
let micSelect: HTMLSelectElement;
let modeButtons: HTMLButtonElement[] = [];

export function initRecord() {
  const page = document.getElementById("tab-record")!;

  const modeSeg = el("div", { class: "mode-seg" });
  const modes: [string, string][] = [
    ["mic", "🎙 Voice"],
    ["system", "🔊 System audio"],
    ["combined", "🎙+🔊 Both"],
  ];
  for (const [value, label] of modes) {
    const b = el("button", { text: label }) as HTMLButtonElement;
    if (value === mode) b.classList.add("active");
    b.addEventListener("click", () => {
      if (phase !== "idle") return;
      mode = value;
      modeButtons.forEach((x) => x.classList.remove("active"));
      b.classList.add("active");
      micSelect.disabled = value === "system";
    });
    modeButtons.push(b);
    modeSeg.appendChild(b);
  }

  micSelect = el("select", { title: "Microphone" }) as HTMLSelectElement;

  const setupCard = el(
    "div",
    { class: "card" },
    el("h3", { text: "Source" }),
    el("div", { class: "row" }, modeSeg, el("div", { class: "grow" }), micSelect),
  );

  timerEl = el("div", { id: "rec-timer", text: "00:00:00" });
  waveCanvas = el("canvas", { id: "rec-wave" }) as HTMLCanvasElement;
  statusDot = el("div", { id: "rec-status-dot" });
  const waveWrap = el("div", { id: "rec-wave-wrap" }, waveCanvas, statusDot);

  micFill = el("div", { class: "meter-fill" });
  sysFill = el("div", { class: "meter-fill" });
  const meters = el(
    "div",
    { class: "row", style: "flex-direction: column; align-items: stretch; gap: 6px; margin-top: 12px;" },
    el("div", { class: "meter" }, el("span", { text: "Mic" }), el("div", { class: "meter-bar" }, micFill)),
    el("div", { class: "meter" }, el("span", { text: "System" }), el("div", { class: "meter-bar" }, sysFill)),
  );

  btnRecord = el("button", { class: "btn accent big", text: "● Record" }) as HTMLButtonElement;
  btnPause = el("button", { class: "btn big", text: "⏸ Pause" }) as HTMLButtonElement;
  btnStop = el("button", { class: "btn big", text: "⏹ Stop & save" }) as HTMLButtonElement;
  btnCancel = el("button", { class: "btn big danger", text: "Discard" }) as HTMLButtonElement;

  btnRecord.addEventListener("click", startRecording);
  btnPause.addEventListener("click", togglePause);
  btnStop.addEventListener("click", () => stopRecording(false));
  btnCancel.addEventListener("click", () => stopRecording(true));

  const controls = el("div", { class: "rec-controls" }, btnRecord, btnPause, btnStop, btnCancel);

  const hint = el("div", { class: "hotkey-hint" });
  hint.innerHTML =
    "Global hotkeys: <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>R</kbd> start/stop &nbsp;·&nbsp; <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>P</kbd> pause/resume";

  const recCard = el("div", { class: "card" }, timerEl, waveWrap, meters, controls, hint);

  page.append(setupCard, recCard);

  void refreshMics();
  applyPhase();
  drawWave();

  void listen<{ elapsedMs: number; mic: number; sys: number; peak: number; paused: boolean }>(
    "rec:levels",
    (e) => {
      const d = e.payload;
      timerEl.textContent = fmtTimer(d.elapsedMs);
      micFill.style.width = `${Math.min(100, d.mic * 260)}%`;
      sysFill.style.width = `${Math.min(100, d.sys * 260)}%`;
      if (!d.paused) {
        peaks.push(Math.min(1, d.peak));
        if (peaks.length > MAX_PEAKS) peaks.shift();
        drawWave();
      }
    },
  );

  void listen<ipc.Entry>("rec:done", (e) => {
    phase = "idle";
    applyPhase();
    toast(`Saved: ${e.payload.title}`, "ok");
  });
  void listen("rec:canceled", () => {
    phase = "idle";
    applyPhase();
    toast("Recording discarded");
  });
  void listen<string>("rec:error", (e) => {
    phase = "idle";
    applyPhase();
    toast(`Recording error: ${e.payload}`, "error", 6000);
  });

  void listen<{ action: string }>("hotkey", (e) => {
    if (e.payload.action === "toggle") {
      if (phase === "idle") void startRecording();
      else void stopRecording(false);
    } else if (e.payload.action === "pause") {
      if (phase !== "idle") void togglePause();
    }
  });
}

async function refreshMics() {
  try {
    const mics = await ipc.listMics();
    micSelect.innerHTML = "";
    for (const m of mics) {
      const o = el("option", { value: m.name, text: (m.isDefault ? "★ " : "") + m.name });
      micSelect.appendChild(o);
      if (m.isDefault) micSelect.value = m.name;
    }
    if (mics.length === 0) {
      micSelect.appendChild(el("option", { value: "", text: "No microphone found" }));
    }
  } catch (e) {
    toast(String(e), "error");
  }
}

async function startRecording() {
  if (phase !== "idle") return;
  try {
    peaks = [];
    const mic = micSelect.value || undefined;
    await ipc.recStart(mode, mode === "system" ? undefined : mic);
    phase = "recording";
    applyPhase();
  } catch (e) {
    toast(String(e), "error", 6000);
  }
}

async function togglePause() {
  try {
    if (phase === "recording") {
      await ipc.recPause();
      phase = "paused";
    } else if (phase === "paused") {
      await ipc.recResume();
      phase = "recording";
    }
    applyPhase();
  } catch (e) {
    toast(String(e), "error");
  }
}

async function stopRecording(cancel: boolean) {
  if (phase === "idle") return;
  try {
    await ipc.recStop(cancel);
    // phase resets on rec:done / rec:canceled events
  } catch (e) {
    toast(String(e), "error");
  }
}

function applyPhase() {
  btnRecord.classList.toggle("hidden", phase !== "idle");
  btnPause.classList.toggle("hidden", phase === "idle");
  btnStop.classList.toggle("hidden", phase === "idle");
  btnCancel.classList.toggle("hidden", phase === "idle");
  btnPause.textContent = phase === "paused" ? "▶ Resume" : "⏸ Pause";
  micSelect.disabled = phase !== "idle" || mode === "system";
  modeButtons.forEach((b) => (b.disabled = phase !== "idle"));

  timerEl.className = phase === "paused" ? "paused" : phase === "recording" ? "live" : "";
  timerEl.id = "rec-timer";
  statusDot.className = phase === "recording" ? "live" : phase === "paused" ? "paused" : "";
  statusDot.id = "rec-status-dot";
  if (phase === "idle") {
    timerEl.textContent = "00:00:00";
    micFill.style.width = "0%";
    sysFill.style.width = "0%";
  }
}

function drawWave() {
  const dpr = window.devicePixelRatio || 1;
  const w = waveCanvas.clientWidth;
  const h = waveCanvas.clientHeight;
  if (w === 0 || h === 0) return;
  if (waveCanvas.width !== w * dpr) {
    waveCanvas.width = w * dpr;
    waveCanvas.height = h * dpr;
  }
  const ctx = waveCanvas.getContext("2d")!;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  const barW = 3;
  const gap = 1;
  const n = Math.floor(w / (barW + gap));
  const slice = peaks.slice(-n);
  ctx.fillStyle = getComputedStyle(document.documentElement).getPropertyValue("--accent").trim() || "#7c6fff";
  for (let i = 0; i < slice.length; i++) {
    const amp = Math.max(0.02, slice[i]);
    const bh = amp * (h - 16);
    const x = w - (slice.length - i) * (barW + gap);
    ctx.fillRect(x, (h - bh) / 2, barW, bh);
  }
}

export function isRecording(): boolean {
  return phase !== "idle";
}
