import { listen } from "@tauri-apps/api/event";
import * as ipc from "./ipc";
import { el, fmtTime, toast } from "./util";
import { play, setTimeCallback, playingPath } from "./player";

let current: ipc.Entry | null = null;
let peaks: number[] = [];
let silences: ipc.SilenceRange[] = [];
let cuts: number[] = [];
let durationSec = 0;
let playheadSec = -1;
let draggingCut = -1;

let canvas: HTMLCanvasElement;
let titleEl: HTMLElement;
let segListEl: HTMLElement;
let baseNameInput: HTMLInputElement;
let noiseInput: HTMLInputElement;
let minSilInput: HTMLInputElement;
let minSegInput: HTMLInputElement;
let bitrateSel: HTMLSelectElement;
let detectBtn: HTMLButtonElement;
let exportBtn: HTMLButtonElement;
let statusEl: HTMLElement;
let placeholder: HTMLElement;
let editorBox: HTMLElement;

export function initSplit() {
  const page = document.getElementById("tab-split")!;

  placeholder = el("div", { class: "empty-note" },
    "Pick a recording to split: go to the ", el("b", { text: "Library" }), " tab and press ", el("b", { text: "Split" }), " on any item.");

  titleEl = el("div", { style: "font-weight: 600; font-size: 15px" });

  noiseInput = el("input", { type: "number", value: "-30", step: "1", style: "width: 90px", title: "Anything quieter than this counts as silence" }) as HTMLInputElement;
  minSilInput = el("input", { type: "number", value: "1.5", step: "0.1", min: "0.2", style: "width: 90px", title: "How long a pause must last" }) as HTMLInputElement;
  minSegInput = el("input", { type: "number", value: "5", step: "1", min: "1", style: "width: 90px", title: "Segments shorter than this get merged into their neighbor" }) as HTMLInputElement;
  detectBtn = el("button", { class: "btn accent", text: "Detect silences" }) as HTMLButtonElement;
  detectBtn.addEventListener("click", () => void detect());

  const paramsCard = el("div", { class: "card" },
    el("h3", { text: "Smart split by silence" }),
    titleEl,
    el("div", { class: "row", style: "margin-top: 12px" },
      el("div", { class: "field" }, el("span", { text: "Silence threshold (dB)" }), noiseInput),
      el("div", { class: "field" }, el("span", { text: "Min silence (s)" }), minSilInput),
      el("div", { class: "field" }, el("span", { text: "Min segment (s)" }), minSegInput),
      el("div", { class: "grow" }),
      detectBtn,
    ),
  );

  canvas = el("canvas", { id: "split-canvas" }) as HTMLCanvasElement;
  const canvasWrap = el("div", { id: "split-canvas-wrap" }, canvas);
  canvas.addEventListener("mousedown", onCanvasDown);
  canvas.addEventListener("mousemove", onCanvasMove);
  window.addEventListener("mouseup", () => {
    if (draggingCut >= 0) {
      draggingCut = -1;
      rebuildSegments();
    }
  });

  const hint = el("div", { class: "muted", style: "font-size: 12px; margin-top: 8px" });
  hint.textContent = "Click to add a cut · click a marker to remove it · drag a marker to fine-tune · shaded areas are detected silence";

  baseNameInput = el("input", { type: "text", placeholder: "Base name", class: "grow" }) as HTMLInputElement;
  bitrateSel = el("select") as HTMLSelectElement;
  for (const b of [128, 192, 256, 320]) bitrateSel.appendChild(el("option", { value: String(b), text: `${b} kbps` }));
  bitrateSel.value = "192";
  exportBtn = el("button", { class: "btn accent", text: "Split & export MP3s" }) as HTMLButtonElement;
  exportBtn.addEventListener("click", () => void doExport());
  statusEl = el("span", { class: "muted" });

  segListEl = el("div", { class: "seg-list" });

  const waveCard = el("div", { class: "card" },
    canvasWrap, hint,
    el("div", { class: "row", style: "margin-top: 14px" },
      el("div", { class: "field grow" }, el("span", { text: "Base name (files become name_01.mp3, name_02.mp3, …)" }), baseNameInput),
      el("div", { class: "field" }, el("span", { text: "Bitrate" }), bitrateSel),
      exportBtn, statusEl,
    ),
    segListEl,
  );

  editorBox = el("div", { class: "hidden" }, paramsCard, waveCard);
  page.append(placeholder, editorBox);

  void listen<{ index: number; total: number }>("split:progress", (e) => {
    statusEl.textContent = `Exporting ${e.payload.index}/${e.payload.total}…`;
  });

  setTimeCallback((t) => {
    if (current && playingPath() === current.path) {
      playheadSec = t;
      draw();
    }
  });

  new ResizeObserver(() => draw()).observe(canvasWrap);
}

export function openInSplit(entry: ipc.Entry) {
  current = entry;
  cuts = [];
  silences = [];
  peaks = [];
  playheadSec = -1;
  placeholder.classList.add("hidden");
  editorBox.classList.remove("hidden");
  titleEl.textContent = `${entry.title} · ${fmtTime(entry.durationMs)}`;
  baseNameInput.value = entry.title;
  durationSec = entry.durationMs / 1000;
  segListEl.innerHTML = "";
  statusEl.textContent = "";

  // switch to the split tab
  (document.querySelector('.tab[data-tab="split"]') as HTMLButtonElement).click();

  void (async () => {
    try {
      statusEl.textContent = "Loading waveform…";
      peaks = await ipc.getWaveform(entry.path, 1600);
      const info = await ipc.probeFile(entry.path);
      if (info.durationMs > 0) durationSec = info.durationMs / 1000;
      statusEl.textContent = "";
      draw();
      rebuildSegments();
    } catch (e) {
      statusEl.textContent = "";
      toast(String(e), "error", 6000);
    }
  })();
}

async function detect() {
  if (!current) return;
  detectBtn.disabled = true;
  detectBtn.textContent = "Detecting…";
  try {
    const noise = parseFloat(noiseInput.value) || -30;
    const minSil = Math.max(0.2, parseFloat(minSilInput.value) || 1.5);
    silences = await ipc.getSilences(current.path, noise, minSil);
    // Propose cuts at the center of each silence, respecting min segment length.
    const minSeg = Math.max(1, parseFloat(minSegInput.value) || 5);
    const proposed: number[] = [];
    let lastCut = 0;
    for (const s of silences) {
      const mid = (s.start + s.end) / 2;
      if (mid - lastCut >= minSeg && durationSec - mid >= minSeg) {
        proposed.push(mid);
        lastCut = mid;
      }
    }
    cuts = proposed;
    draw();
    rebuildSegments();
    if (cuts.length === 0) {
      toast("No suitable pauses found — try a higher threshold (e.g. -25 dB) or shorter min silence");
    } else {
      toast(`${cuts.length} cut(s) proposed → ${cuts.length + 1} segments`, "ok");
    }
  } catch (e) {
    toast(String(e), "error", 6000);
  } finally {
    detectBtn.disabled = false;
    detectBtn.textContent = "Detect silences";
  }
}

function xToSec(x: number): number {
  return (x / canvas.clientWidth) * durationSec;
}
function secToX(s: number): number {
  return (s / durationSec) * canvas.clientWidth;
}

function onCanvasDown(e: MouseEvent) {
  if (!current || durationSec === 0) return;
  const rect = canvas.getBoundingClientRect();
  const x = e.clientX - rect.left;
  // near an existing cut?
  for (let i = 0; i < cuts.length; i++) {
    if (Math.abs(secToX(cuts[i]) - x) < 6) {
      if (e.shiftKey || e.button === 2) {
        cuts.splice(i, 1);
        draw();
        rebuildSegments();
      } else {
        draggingCut = i;
      }
      return;
    }
  }
  if (e.altKey) {
    // alt-click: play from here
    play(current.path, current.title, xToSec(x));
    return;
  }
  cuts.push(xToSec(x));
  cuts.sort((a, b) => a - b);
  draw();
  rebuildSegments();
}

function onCanvasMove(e: MouseEvent) {
  if (draggingCut < 0) {
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const near = cuts.some((c) => Math.abs(secToX(c) - x) < 6);
    canvas.parentElement!.style.cursor = near ? "ew-resize" : "crosshair";
    return;
  }
  const rect = canvas.getBoundingClientRect();
  const x = Math.max(0, Math.min(canvas.clientWidth, e.clientX - rect.left));
  cuts[draggingCut] = xToSec(x);
  draw();
}

function draw() {
  if (!current) return;
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  if (w === 0) return;
  if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
    canvas.width = w * dpr;
    canvas.height = h * dpr;
  }
  const ctx = canvas.getContext("2d")!;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);

  // silence shading
  ctx.fillStyle = "rgba(251, 191, 36, 0.10)";
  for (const s of silences) {
    const x1 = secToX(s.start);
    const x2 = secToX(s.end);
    ctx.fillRect(x1, 0, Math.max(1, x2 - x1), h);
  }

  // waveform
  ctx.fillStyle = "#7c6fff";
  const n = peaks.length;
  if (n > 0) {
    const step = w / n;
    for (let i = 0; i < n; i++) {
      const amp = Math.max(0.015, peaks[i]);
      const bh = amp * (h - 24);
      ctx.fillRect(i * step, (h - bh) / 2, Math.max(1, step - 0.4), bh);
    }
  }

  // cut markers
  for (const c of cuts) {
    const x = secToX(c);
    ctx.strokeStyle = "#ff5d73";
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, h);
    ctx.stroke();
    ctx.fillStyle = "#ff5d73";
    ctx.beginPath();
    ctx.moveTo(x - 5, 0);
    ctx.lineTo(x + 5, 0);
    ctx.lineTo(x, 8);
    ctx.closePath();
    ctx.fill();
  }

  // playhead
  if (playheadSec >= 0 && playheadSec <= durationSec) {
    const x = secToX(playheadSec);
    ctx.strokeStyle = "#4ade80";
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, h);
    ctx.stroke();
  }
}

function rebuildSegments() {
  segListEl.innerHTML = "";
  if (!current) return;
  cuts.sort((a, b) => a - b);
  const bounds = [0, ...cuts, durationSec];
  for (let i = 0; i < bounds.length - 1; i++) {
    const a = bounds[i];
    const b = bounds[i + 1];
    const name = `${baseNameInput.value || "Segment"}_${String(i + 1).padStart(2, "0")}.mp3`;
    const playBtn = el("button", { class: "btn icon", text: "▶", title: "Preview this segment" });
    playBtn.addEventListener("click", () => {
      if (current) play(current.path, name, a);
    });
    segListEl.appendChild(
      el("div", { class: "seg-item" },
        playBtn,
        el("span", { class: "mono", text: `${fmtTime(a * 1000)} → ${fmtTime(b * 1000)}` }),
        el("span", { class: "muted mono", text: `(${fmtTime((b - a) * 1000)})` }),
        el("span", { class: "grow" }),
        el("span", { class: "muted", text: name }),
      ),
    );
  }
  exportBtn.disabled = false;
}

async function doExport() {
  if (!current) return;
  exportBtn.disabled = true;
  statusEl.textContent = "Exporting…";
  try {
    const result = await ipc.splitExport({
      srcPath: current.path,
      cuts,
      baseName: baseNameInput.value.trim() || current.title,
      bitrate: parseInt(bitrateSel.value),
      folder: current.folder,
    });
    statusEl.textContent = "";
    toast(`Exported ${result.length} segment(s) to your Music/Adagio folder`, "ok", 5000);
  } catch (e) {
    statusEl.textContent = "";
    toast(String(e), "error", 7000);
  } finally {
    exportBtn.disabled = false;
  }
}
