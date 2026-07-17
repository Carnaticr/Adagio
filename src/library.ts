import { listen } from "@tauri-apps/api/event";
import { ask, open as openDialog } from "@tauri-apps/plugin-dialog";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import * as ipc from "./ipc";
import { el, fmtTime, fmtSize, toast } from "./util";
import { play } from "./player";
import { openInSplit } from "./split";

let entries: ipc.Entry[] = [];
const selected = new Set<number>();

let tbody: HTMLTableSectionElement;
let searchInput: HTMLInputElement;
let folderSelect: HTMLSelectElement;
let bulkBar: HTMLElement;
let emptyNote: HTMLElement;

export function initLibrary() {
  const page = document.getElementById("tab-library")!;

  searchInput = el("input", { type: "text", placeholder: "Search title, artist, album, tags…", class: "grow" }) as HTMLInputElement;
  searchInput.addEventListener("input", debounce(() => void refresh(), 250));

  folderSelect = el("select", { title: "Project / folder filter" }) as HTMLSelectElement;
  folderSelect.addEventListener("change", () => void refresh());

  const importBtn = el("button", { class: "btn", text: "＋ Import audio" }) as HTMLButtonElement;
  importBtn.addEventListener("click", () => void importFiles());

  bulkBar = el("div", { class: "row hidden" });
  const bulkExport = el("button", { class: "btn", text: "Export MP3" });
  const bulkMerge = el("button", { class: "btn", text: "Merge" });
  const bulkDelete = el("button", { class: "btn danger", text: "Delete" });
  const bulkCount = el("span", { class: "muted", id: "bulk-count" });
  bulkBar.append(bulkCount, bulkExport, bulkMerge, bulkDelete);

  bulkDelete.addEventListener("click", () => void bulkDeleteAction());
  bulkMerge.addEventListener("click", () => void bulkMergeAction());
  bulkExport.addEventListener("click", () => void bulkExportAction());

  const controls = el("div", { class: "card" }, el("div", { class: "row" }, searchInput, folderSelect, importBtn), bulkBar);

  const table = el("table", { id: "lib-table" });
  const thead = el("thead");
  thead.innerHTML =
    "<tr><th style='width:28px'></th><th>Title</th><th>Kind</th><th>Duration</th><th>Size</th><th>Date</th><th>Folder</th><th style='width:220px'></th></tr>";
  tbody = el("tbody") as HTMLTableSectionElement;
  table.append(thead, tbody);
  emptyNote = el("div", { class: "empty-note", text: "No recordings yet — record something or import audio files." });

  const listCard = el("div", { class: "card", style: "padding: 0 0 6px 0; overflow: auto; max-height: calc(100vh - 240px);" }, table, emptyNote);
  page.append(controls, listCard);

  void listen("lib:changed", () => void refresh());
  void refresh();
}

export async function refresh() {
  try {
    entries = await ipc.libList(searchInput.value.trim(), folderSelect.value || "");
    const folders = await ipc.libFolders();
    const current = folderSelect.value;
    folderSelect.innerHTML = "";
    folderSelect.appendChild(el("option", { value: "", text: "All folders" }));
    for (const f of folders) folderSelect.appendChild(el("option", { value: f, text: f }));
    folderSelect.value = folders.includes(current) ? current : "";
    render();
  } catch (e) {
    toast(String(e), "error");
  }
}

function render() {
  tbody.innerHTML = "";
  for (const id of [...selected]) {
    if (!entries.some((e) => e.id === id)) selected.delete(id);
  }
  emptyNote.classList.toggle("hidden", entries.length > 0);

  for (const entry of entries) {
    const tr = el("tr");
    if (selected.has(entry.id)) tr.classList.add("selected");

    const cb = el("input", { type: "checkbox" }) as HTMLInputElement;
    cb.checked = selected.has(entry.id);
    cb.addEventListener("change", () => {
      if (cb.checked) selected.add(entry.id);
      else selected.delete(entry.id);
      tr.classList.toggle("selected", cb.checked);
      updateBulkBar();
    });

    const titleCell = el("td");
    const titleDiv = el("div", { text: entry.title });
    titleDiv.title = entry.path;
    if (entry.artist || entry.tags) {
      titleCell.append(
        titleDiv,
        el("div", { class: "muted", style: "font-size: 11.5px", text: [entry.artist, entry.tags && `#${entry.tags}`].filter(Boolean).join(" · ") }),
      );
    } else {
      titleCell.append(titleDiv);
    }

    const playBtn = el("button", { class: "btn", text: "▶", title: "Play" });
    playBtn.addEventListener("click", () => play(entry.path, entry.title));
    const editBtn = el("button", { class: "btn", text: "Edit", title: "Edit metadata" });
    editBtn.addEventListener("click", () => openEditModal(entry));
    const exportBtn = el("button", { class: "btn", text: "MP3", title: "Export as MP3 with processing" });
    exportBtn.addEventListener("click", () => openExportModal(entry));
    const splitBtn = el("button", { class: "btn", text: "Split", title: "Split by silence" });
    splitBtn.addEventListener("click", () => openInSplit(entry));
    const revealBtn = el("button", { class: "btn", text: "📂", title: "Show in folder" });
    revealBtn.addEventListener("click", () => void revealItemInDir(entry.path).catch((e) => toast(String(e), "error")));

    tr.append(
      el("td", {}, cb),
      titleCell,
      el("td", {}, el("span", { class: "kind-badge", text: entry.kind })),
      el("td", { class: "mono", text: fmtTime(entry.durationMs) }),
      el("td", { class: "mono", text: fmtSize(entry.sizeBytes) }),
      el("td", { class: "muted", text: entry.createdAt.slice(0, 16) }),
      el("td", { class: "muted", text: entry.folder }),
      el("td", {}, el("div", { class: "rowbtns" }, playBtn, editBtn, exportBtn, splitBtn, revealBtn)),
    );
    tbody.appendChild(tr);
  }
  updateBulkBar();
}

function updateBulkBar() {
  bulkBar.classList.toggle("hidden", selected.size === 0);
  const count = document.getElementById("bulk-count");
  if (count) count.textContent = `${selected.size} selected`;
}

async function importFiles() {
  const picked = await openDialog({
    multiple: true,
    filters: [{ name: "Audio", extensions: ["mp3", "wav", "m4a", "flac", "ogg", "opus", "aac", "wma"] }],
  });
  if (!picked) return;
  const paths = Array.isArray(picked) ? picked : [picked];
  try {
    const added = await ipc.libImport(paths);
    toast(`Imported ${added.length} file(s)`, "ok");
  } catch (e) {
    toast(String(e), "error");
  }
}

async function bulkDeleteAction() {
  const ids = [...selected];
  if (ids.length === 0) return;
  const removeOk = await ask(`Remove ${ids.length} item(s) from the library?`, {
    title: "Delete",
    kind: "warning",
  });
  if (!removeOk) return;
  const filesToo = await ask(
    "Also delete the audio files from disk?\n\nYes = delete the files too · No = keep the files, remove only the library entries",
    { title: "Delete files", kind: "warning" },
  );
  try {
    await ipc.libDelete(ids, filesToo);
    selected.clear();
    toast("Deleted", "ok");
  } catch (e) {
    toast(String(e), "error");
  }
}

async function bulkMergeAction() {
  const ids = [...selected];
  if (ids.length < 2) {
    toast("Select at least two items to merge");
    return;
  }
  const list = entries.filter((e) => ids.includes(e.id));
  const title = await textPrompt(
    "Merge recordings",
    "Title for the merged file",
    `Merged_${new Date().toISOString().slice(0, 10)}`,
  );
  if (!title) return;
  try {
    toast("Merging…");
    await ipc.libMerge(list.map((e) => e.path), title, 192);
    selected.clear();
    toast("Merged", "ok");
  } catch (e) {
    toast(String(e), "error", 6000);
  }
}

async function bulkExportAction() {
  const list = entries.filter((e) => selected.has(e.id));
  let done = 0;
  toast(`Exporting ${list.length} file(s) to MP3…`);
  for (const entry of list) {
    try {
      await ipc.exportMp3({
        srcPath: entry.path,
        bitrate: 192,
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        normalize: false,
        fadeIn: 0,
        fadeOut: 0,
        denoise: false,
      });
      done++;
    } catch (e) {
      toast(`${entry.title}: ${e}`, "error");
    }
  }
  selected.clear();
  toast(`Exported ${done}/${list.length}`, "ok");
}

// ---------- modals ----------

function modal(title: string, body: HTMLElement, actions: HTMLElement[]): HTMLElement {
  const backdrop = el("div", { class: "modal-backdrop" });
  const box = el("div", { class: "modal" }, el("h2", { text: title }), body, el("div", { class: "actions" }, ...actions));
  backdrop.appendChild(box);
  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop) backdrop.remove();
  });
  document.body.appendChild(backdrop);
  return backdrop;
}

function field(label: string, input: HTMLElement): HTMLElement {
  return el("div", { class: "field", style: "margin-bottom: 10px" }, el("span", { text: label }), input);
}

function textPrompt(title: string, label: string, initial: string): Promise<string | null> {
  return new Promise((resolve) => {
    const input = el("input", { type: "text", value: initial, style: "width: 100%" }) as HTMLInputElement;
    const cancel = el("button", { class: "btn", text: "Cancel" });
    const ok = el("button", { class: "btn accent", text: "OK" });
    const backdrop = modal(title, field(label, input), [cancel, ok]);
    const done = (v: string | null) => {
      backdrop.remove();
      resolve(v);
    };
    backdrop.addEventListener("click", (e) => {
      if (e.target === backdrop) resolve(null);
    });
    cancel.addEventListener("click", () => done(null));
    ok.addEventListener("click", () => done(input.value.trim() || null));
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") done(input.value.trim() || null);
      if (e.key === "Escape") done(null);
    });
    input.focus();
    input.select();
  });
}

function openEditModal(entry: ipc.Entry) {
  const title = el("input", { type: "text", value: entry.title }) as HTMLInputElement;
  const artist = el("input", { type: "text", value: entry.artist }) as HTMLInputElement;
  const album = el("input", { type: "text", value: entry.album }) as HTMLInputElement;
  const tags = el("input", { type: "text", value: entry.tags, placeholder: "comma, separated" }) as HTMLInputElement;
  const folder = el("input", { type: "text", value: entry.folder, placeholder: "e.g. Podcast S2" }) as HTMLInputElement;

  const body = el("div", {},
    field("Title", title), field("Artist", artist), field("Album", album),
    field("Tags", tags), field("Folder / project", folder),
  );

  const cancel = el("button", { class: "btn", text: "Cancel" });
  const save = el("button", { class: "btn accent", text: "Save" });
  const backdrop = modal("Edit metadata", body, [cancel, save]);
  cancel.addEventListener("click", () => backdrop.remove());
  save.addEventListener("click", async () => {
    try {
      await ipc.libUpdate({
        id: entry.id,
        title: title.value.trim() || entry.title,
        artist: artist.value.trim(),
        album: album.value.trim(),
        tags: tags.value.trim(),
        folder: folder.value.trim(),
      });
      backdrop.remove();
      void refresh();
      toast("Saved", "ok");
    } catch (e) {
      toast(String(e), "error");
    }
  });
}

function openExportModal(entry: ipc.Entry) {
  const title = el("input", { type: "text", value: entry.title }) as HTMLInputElement;
  const artist = el("input", { type: "text", value: entry.artist }) as HTMLInputElement;
  const album = el("input", { type: "text", value: entry.album }) as HTMLInputElement;
  const track = el("input", { type: "number", min: "0", placeholder: "—", style: "width: 90px" }) as HTMLInputElement;

  const bitrate = el("select") as HTMLSelectElement;
  for (const b of [128, 192, 256, 320]) bitrate.appendChild(el("option", { value: String(b), text: `${b} kbps` }));
  bitrate.value = "192";

  const normalize = el("input", { type: "checkbox" }) as HTMLInputElement;
  const denoise = el("input", { type: "checkbox" }) as HTMLInputElement;
  const fadeIn = el("input", { type: "number", value: "0", min: "0", step: "0.5", style: "width: 90px" }) as HTMLInputElement;
  const fadeOut = el("input", { type: "number", value: "0", min: "0", step: "0.5", style: "width: 90px" }) as HTMLInputElement;

  let artPath = "";
  const artBtn = el("button", { class: "btn", text: "Choose artwork…" }) as HTMLButtonElement;
  const artLabel = el("span", { class: "muted", text: "none" });
  artBtn.addEventListener("click", async () => {
    const picked = await openDialog({ multiple: false, filters: [{ name: "Image", extensions: ["jpg", "jpeg", "png"] }] });
    if (typeof picked === "string") {
      artPath = picked;
      artLabel.textContent = picked.split("\\").pop() ?? picked;
    }
  });

  const body = el("div", {},
    field("Title", title), field("Artist", artist), field("Album", album),
    el("div", { class: "row" }, field("Track #", track), field("Bitrate", bitrate)),
    el("div", { class: "row", style: "margin: 10px 0" },
      el("label", { class: "chk" }, normalize, "normalize loudness"),
      el("label", { class: "chk" }, denoise, "reduce noise"),
    ),
    el("div", { class: "row" }, field("Fade in (s)", fadeIn), field("Fade out (s)", fadeOut)),
    el("div", { class: "row", style: "margin-top: 10px" }, artBtn, artLabel),
  );

  const cancel = el("button", { class: "btn", text: "Cancel" });
  const doExport = el("button", { class: "btn accent", text: "Export MP3" }) as HTMLButtonElement;
  const backdrop = modal("Export as MP3", body, [cancel, doExport]);
  cancel.addEventListener("click", () => backdrop.remove());
  doExport.addEventListener("click", async () => {
    doExport.disabled = true;
    doExport.textContent = "Exporting…";
    try {
      const result = await ipc.exportMp3({
        srcPath: entry.path,
        bitrate: parseInt(bitrate.value),
        title: title.value.trim(),
        artist: artist.value.trim(),
        album: album.value.trim(),
        track: track.value ? parseInt(track.value) : undefined,
        artPath: artPath || undefined,
        normalize: normalize.checked,
        fadeIn: parseFloat(fadeIn.value) || 0,
        fadeOut: parseFloat(fadeOut.value) || 0,
        denoise: denoise.checked,
      });
      backdrop.remove();
      toast(`Exported: ${result.title}.mp3`, "ok");
    } catch (e) {
      doExport.disabled = false;
      doExport.textContent = "Export MP3";
      toast(String(e), "error", 7000);
    }
  });
}

function debounce<T extends (...a: never[]) => void>(fn: T, ms: number): T {
  let t: ReturnType<typeof setTimeout>;
  return ((...a: never[]) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...a), ms);
  }) as T;
}
