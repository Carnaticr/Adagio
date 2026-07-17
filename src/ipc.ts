import { invoke } from "@tauri-apps/api/core";

export interface Entry {
  id: number;
  title: string;
  artist: string;
  album: string;
  path: string;
  kind: string;
  folder: string;
  tags: string;
  durationMs: number;
  sizeBytes: number;
  createdAt: string;
}

export interface ToolsStatus {
  ffmpeg: boolean;
  ytdlp: boolean;
  binDir: string;
}

export interface MicInfo {
  name: string;
  isDefault: boolean;
}

export interface ProbeInfo {
  durationMs: number;
  sizeBytes: number;
  title: string;
  artist: string;
  album: string;
}

export interface SilenceRange {
  start: number;
  end: number;
}

export interface ExportOpts {
  srcPath: string;
  outName?: string;
  bitrate: number;
  title: string;
  artist: string;
  album: string;
  track?: number;
  artPath?: string;
  normalize: boolean;
  fadeIn: number;
  fadeOut: number;
  denoise: boolean;
}

export interface SplitOpts {
  srcPath: string;
  cuts: number[];
  baseName: string;
  bitrate: number;
  folder: string;
}

export interface YtOpts {
  bitrate: number;
  embedThumbnail: boolean;
  playlistMode: "single" | "first_n" | "all";
  playlistN: number;
}

export const toolsStatus = () => invoke<ToolsStatus>("tools_status");
export const toolsInstall = () => invoke<void>("tools_install");

export const listMics = () => invoke<MicInfo[]>("list_mics");
export const recStart = (mode: string, mic?: string) =>
  invoke<void>("rec_start", { mode, mic: mic ?? null });
export const recPause = () => invoke<void>("rec_pause");
export const recResume = () => invoke<void>("rec_resume");
export const recStop = (cancel: boolean) => invoke<void>("rec_stop", { cancel });
export const recActive = () => invoke<boolean>("rec_active");

export const libList = (query = "", folder = "") =>
  invoke<Entry[]>("lib_list", { query, folder });
export const libUpdate = (e: {
  id: number; title: string; artist: string; album: string; tags: string; folder: string;
}) => invoke<Entry>("lib_update", { ...e });
export const libDelete = (ids: number[], deleteFiles: boolean) =>
  invoke<void>("lib_delete", { ids, deleteFiles });
export const libFolders = () => invoke<string[]>("lib_folders");
export const libImport = (paths: string[]) => invoke<Entry[]>("lib_import", { paths });
export const libMerge = (paths: string[], title: string, bitrate: number) =>
  invoke<Entry>("lib_merge", { paths, title, bitrate });

export const getWaveform = (path: string, points: number) =>
  invoke<number[]>("get_waveform", { path, points });
export const getSilences = (path: string, noiseDb: number, minDur: number) =>
  invoke<SilenceRange[]>("get_silences", { path, noiseDb, minDur });
export const probeFile = (path: string) => invoke<ProbeInfo>("probe_file", { path });
export const exportMp3 = (opts: ExportOpts) => invoke<Entry>("export_mp3", { opts });
export const splitExport = (opts: SplitOpts) => invoke<Entry[]>("split_export", { opts });

export const ytQueue = (url: string, opts: YtOpts) => invoke<number>("yt_queue", { url, opts });
export const ytCancel = (id: number) => invoke<void>("yt_cancel", { id });
