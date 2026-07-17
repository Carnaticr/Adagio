import { convertFileSrc } from "@tauri-apps/api/core";
import { getSilences, SilenceRange } from "./ipc";
import { fmtTime, toast } from "./util";

const audio = new Audio();
let silenceRanges: SilenceRange[] = [];
let skipSilence = false;
let currentPath = "";

const bar = () => document.getElementById("playerbar")!;
const btnToggle = () => document.getElementById("pl-toggle") as HTMLButtonElement;
const title = () => document.getElementById("pl-title")!;
const seek = () => document.getElementById("pl-seek") as HTMLInputElement;
const time = () => document.getElementById("pl-time")!;

export function initPlayer() {
  btnToggle().addEventListener("click", () => {
    if (audio.paused) void audio.play();
    else audio.pause();
  });
  document.getElementById("pl-close")!.addEventListener("click", () => {
    audio.pause();
    bar().classList.add("hidden");
  });
  (document.getElementById("pl-speed") as HTMLSelectElement).addEventListener("change", (e) => {
    audio.playbackRate = parseFloat((e.target as HTMLSelectElement).value);
  });
  (document.getElementById("pl-skipsilence") as HTMLInputElement).addEventListener("change", async (e) => {
    skipSilence = (e.target as HTMLInputElement).checked;
    if (skipSilence && currentPath && silenceRanges.length === 0) {
      try {
        silenceRanges = await getSilences(currentPath, -35, 1.0);
        if (silenceRanges.length === 0) toast("No silent passages found");
      } catch (err) {
        toast(String(err), "error");
        skipSilence = false;
        (e.target as HTMLInputElement).checked = false;
      }
    }
  });
  seek().addEventListener("input", () => {
    if (audio.duration) audio.currentTime = (parseInt(seek().value) / 1000) * audio.duration;
  });
  audio.addEventListener("timeupdate", () => {
    if (skipSilence && !audio.paused) {
      const t = audio.currentTime;
      for (const r of silenceRanges) {
        // Jump when we're inside a silence (with a little lead-in kept)
        if (t > r.start + 0.25 && t < r.end - 0.25) {
          audio.currentTime = r.end - 0.15;
          break;
        }
      }
    }
    if (audio.duration) {
      seek().value = String(Math.floor((audio.currentTime / audio.duration) * 1000));
      time().textContent = `${fmtTime(audio.currentTime * 1000)} / ${fmtTime(audio.duration * 1000)}`;
    }
    onTimeUpdate?.(audio.currentTime);
  });
  audio.addEventListener("play", () => (btnToggle().textContent = "⏸"));
  audio.addEventListener("pause", () => (btnToggle().textContent = "▶"));
  audio.addEventListener("error", () => {
    if (currentPath) toast("Could not play this file", "error");
  });
}

export let onTimeUpdate: ((t: number) => void) | null = null;
export function setTimeCallback(cb: ((t: number) => void) | null) {
  onTimeUpdate = cb;
}

export function play(path: string, displayTitle: string, startAt = 0) {
  if (currentPath !== path) {
    audio.src = convertFileSrc(path);
    currentPath = path;
    silenceRanges = [];
    (document.getElementById("pl-skipsilence") as HTMLInputElement).checked = false;
    skipSilence = false;
  }
  bar().classList.remove("hidden");
  title().textContent = displayTitle;
  title().title = displayTitle;
  audio.currentTime = startAt;
  void audio.play();
}

export function pausePlayback() {
  audio.pause();
}

export function playingPath(): string {
  return currentPath;
}
