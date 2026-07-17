import { listen } from "@tauri-apps/api/event";
import { ask } from "@tauri-apps/plugin-dialog";
import * as ipc from "./ipc";
import { el, toast } from "./util";

interface JobView {
  root: HTMLElement;
  progFill: HTMLElement;
  statusEl: HTMLElement;
  cancelBtn: HTMLButtonElement;
}

const jobs = new Map<number, JobView>();

export function initYoutube() {
  const page = document.getElementById("tab-youtube")!;

  const urlInput = el("input", {
    type: "url",
    placeholder: "Paste a YouTube URL (video or playlist)…",
    class: "grow",
  }) as HTMLInputElement;

  const bitrate = el("select", { title: "MP3 bitrate" }) as HTMLSelectElement;
  for (const b of [128, 192, 256, 320]) {
    bitrate.appendChild(el("option", { value: String(b), text: `${b} kbps` }));
  }
  bitrate.value = "192";

  const thumb = el("input", { type: "checkbox" }) as HTMLInputElement;
  thumb.checked = true;
  const thumbLabel = el("label", { class: "chk" }, thumb, "embed cover art");

  const playlistMode = el("select", { title: "Playlist handling" }) as HTMLSelectElement;
  playlistMode.append(
    el("option", { value: "single", text: "Single video only" }),
    el("option", { value: "first_n", text: "First N of playlist" }),
    el("option", { value: "all", text: "Whole playlist" }),
  );
  const playlistN = el("input", {
    type: "number", value: "5", min: "1", max: "999", style: "width: 70px",
    title: "How many playlist items",
  }) as HTMLInputElement;
  playlistN.classList.add("hidden");
  playlistMode.addEventListener("change", () => {
    playlistN.classList.toggle("hidden", playlistMode.value !== "first_n");
  });

  const addBtn = el("button", { class: "btn accent", text: "Download MP3" }) as HTMLButtonElement;

  const card = el(
    "div",
    { class: "card" },
    el("h3", { text: "YouTube → MP3" }),
    el("div", { class: "row" }, urlInput, addBtn),
    el(
      "div",
      { class: "row" },
      el("div", { class: "field" }, el("span", { text: "Bitrate" }), bitrate),
      el("div", { class: "field" }, el("span", { text: "Playlist" }), el("div", { class: "row" }, playlistMode, playlistN)),
      el("div", { class: "field" }, el("span", { text: "Metadata" }), thumbLabel),
    ),
  );

  const queueCard = el("div", { class: "card" }, el("h3", { text: "Queue" }));
  const queueBox = el("div", { id: "yt-queue" });
  const emptyNote = el("div", { class: "empty-note", text: "Nothing queued yet. Downloads land in Music\\Adagio and appear in your Library." });
  queueCard.append(queueBox, emptyNote);

  page.append(card, queueCard);

  const submit = async () => {
    const url = urlInput.value.trim();
    if (!url) return;
    if (!/^https?:\/\//i.test(url)) {
      toast("That doesn't look like a URL", "error");
      return;
    }
    const mode = playlistMode.value as ipc.YtOpts["playlistMode"];
    const n = Math.max(1, parseInt(playlistN.value) || 5);
    if (mode === "all") {
      const ok = await ask("Download the entire playlist? This can be a lot of files.", {
        title: "Whole playlist",
      });
      if (!ok) return;
    }
    try {
      const id = await ipc.ytQueue(url, {
        bitrate: parseInt(bitrate.value),
        embedThumbnail: thumb.checked,
        playlistMode: mode,
        playlistN: n,
      });
      urlInput.value = "";
      emptyNote.classList.add("hidden");
      addJobView(queueBox, id, url);
    } catch (e) {
      toast(String(e), "error", 6000);
    }
  };
  addBtn.addEventListener("click", () => void submit());
  urlInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") void submit();
  });

  void listen<{ id: number; status: string; pct: number; speed: string; eta: string; message: string }>(
    "yt:update",
    (e) => {
      const d = e.payload;
      const view = jobs.get(d.id);
      if (!view) return;
      view.progFill.style.width = `${Math.max(0, Math.min(100, d.pct))}%`;
      view.root.classList.toggle("done", d.status === "done");
      view.root.classList.toggle("error", d.status === "error");
      let text = d.status;
      if (d.status === "running") {
        text = d.message || `${d.pct.toFixed(1)}%${d.speed ? " · " + d.speed : ""}${d.eta ? " · ETA " + d.eta : ""}`;
      } else if (d.status === "done") {
        text = `✓ ${d.message}`;
      } else if (d.status === "error") {
        text = `✗ ${d.message.slice(0, 160)}`;
        view.statusEl.title = d.message;
      } else if (d.status === "canceled") {
        text = "canceled";
      }
      view.statusEl.textContent = text;
      if (d.status !== "queued" && d.status !== "running") {
        view.cancelBtn.disabled = true;
      }
    },
  );
}

function addJobView(container: HTMLElement, id: number, url: string) {
  const progFill = el("div");
  const prog = el("div", { class: "prog" }, progFill);
  const statusEl = el("span", { class: "status muted", text: "queued" });
  const cancelBtn = el("button", { class: "btn icon", text: "✕", title: "Cancel" }) as HTMLButtonElement;
  cancelBtn.addEventListener("click", () => void ipc.ytCancel(id));
  const label = el("span", { class: "muted", text: shortUrl(url), style: "max-width: 240px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;" });
  label.title = url;
  const root = el("div", { class: "yt-job" }, label, prog, statusEl, cancelBtn);
  container.prepend(root);
  jobs.set(id, { root, progFill, statusEl, cancelBtn });
}

function shortUrl(url: string): string {
  try {
    const u = new URL(url);
    return (u.searchParams.get("v") ? "▶ " + u.searchParams.get("v") : u.pathname.slice(1)) || url;
  } catch {
    return url;
  }
}
