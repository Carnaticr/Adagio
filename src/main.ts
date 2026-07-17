import { listen } from "@tauri-apps/api/event";
import * as ipc from "./ipc";
import { toast } from "./util";
import { initRecord } from "./record";
import { initYoutube } from "./youtube";
import { initLibrary } from "./library";
import { initSplit } from "./split";
import { initPlayer } from "./player";

function initTabs() {
  const tabs = document.querySelectorAll<HTMLButtonElement>(".tab");
  tabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      tabs.forEach((t) => t.classList.remove("active"));
      tab.classList.add("active");
      document.querySelectorAll(".tab-page").forEach((p) => p.classList.remove("active"));
      document.getElementById(`tab-${tab.dataset.tab}`)!.classList.add("active");
    });
  });
}

async function initTools() {
  const btn = document.getElementById("btn-install-tools") as HTMLButtonElement;
  const progress = document.getElementById("tools-progress")!;

  const check = async () => {
    try {
      const st = await ipc.toolsStatus();
      const missing = !st.ffmpeg || !st.ytdlp;
      btn.classList.toggle("hidden", !missing);
      return st;
    } catch (e) {
      toast(String(e), "error");
      return null;
    }
  };

  const st = await check();
  if (st && (!st.ffmpeg || !st.ytdlp)) {
    toast(
      "ffmpeg + yt-dlp are not installed yet. Recording to WAV works now; MP3 export, YouTube downloads and splitting need them — click “Install tools” (~90 MB download).",
      "info",
      9000,
    );
  }

  btn.addEventListener("click", () => {
    btn.disabled = true;
    progress.classList.remove("hidden");
    progress.textContent = "Starting download…";
    void ipc.toolsInstall();
  });

  void listen<{ stage: string; pct: number; done: boolean; error: string | null }>(
    "tools:progress",
    (e) => {
      const d = e.payload;
      if (d.done) {
        progress.classList.add("hidden");
        btn.disabled = false;
        if (d.error) {
          toast(`Tool install failed: ${d.error}`, "error", 8000);
        } else {
          btn.classList.add("hidden");
          toast("Tools installed — everything is unlocked", "ok");
        }
        return;
      }
      const label =
        d.stage === "yt-dlp" ? "yt-dlp" : d.stage === "ffmpeg" ? "ffmpeg" : "extracting";
      progress.textContent = `${label} ${d.pct.toFixed(0)}%`;
    },
  );
}

initTabs();
initPlayer();
initRecord();
initYoutube();
initLibrary();
initSplit();
void initTools();
