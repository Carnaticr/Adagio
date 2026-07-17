# Adagio — Sound Recorder

A lightweight, offline-first desktop app for **Windows and macOS**: record voice and
system audio, download YouTube audio as MP3, export/post-process MP3s, and split
long recordings at natural pauses.

Built with **Tauri 2** (Rust backend + native webview). No Electron, no bundled
Chromium.

## Download

Grab the latest installer from the **[Releases page](../../releases/latest)**:

| Platform | File |
|---|---|
| Windows 10/11 | `Adagio_x.y.z_x64-setup.exe` |
| macOS 10.15+ (Intel & Apple Silicon) | `Adagio_x.y.z_universal.dmg` |

macOS note: the app is not code-signed. On first launch, right-click
`Adagio.app` → **Open** (or run `xattr -cr /Applications/Adagio.app`).

## Features

- **Recording** — Voice (mic), System audio ("what you hear"), or Combined
  (mic + system mixed for commentary). Pause/resume, live waveform, level meters,
  timer. Global hotkeys: `Ctrl+Alt+R` start/stop, `Ctrl+Alt+P` pause/resume.
  Recordings are saved as WAV in your `Music/Adagio` folder and indexed in the library.
  - System audio uses WASAPI loopback on Windows (works out of the box). macOS has
    no OS loopback API — install [BlackHole](https://existential.audio/blackhole/)
    (free) and route output through it; Adagio picks it up automatically.
- **YouTube → MP3** — paste a URL, pick bitrate (128–320 kbps), embedded metadata +
  cover art, playlist support (single / first N / all with confirmation), queued
  downloads with progress. Powered by yt-dlp.
- **MP3 export** — any library item → MP3 with bitrate, ID3 metadata (title, artist,
  album, track, artwork), loudness normalization, fade in/out, and basic noise
  reduction (ffmpeg `afftdn`).
- **Smart split by silence** — configurable threshold (dB), minimum silence duration,
  and minimum segment length. Waveform preview with shaded silences; click to add
  cuts, drag to fine-tune, shift-click to remove, alt-click to audition. One-click
  "Split & export" produces `Name_01.mp3`, `Name_02.mp3`, …
- **Library** — SQLite-backed, searchable (title/artist/album/tags), folder/project
  grouping, playback with 0.5×–2× speed and skip-silence, bulk export / merge /
  delete, reveal in Explorer.

## First run

ffmpeg and yt-dlp are **not** bundled. The app offers an **Install tools** button
(top right) that downloads them (~90 MB total) into the app's data dir:

- yt-dlp from `github.com/yt-dlp/yt-dlp/releases/latest`
- ffmpeg + ffprobe: `gyan.dev/ffmpeg/builds` (Windows) or `evermeet.cx` static
  builds (macOS; Intel binaries, run via Rosetta 2 on Apple Silicon)

Without them you can still record and play WAV. MP3 export, YouTube downloads,
combined-mode mixdown, waveforms in the split editor, and silence detection need them.
If ffmpeg/yt-dlp are already on your `PATH`, they are picked up automatically.

## Development

Prerequisites: Node 20+ and Rust. On Windows: MSVC Build Tools + WebView2 runtime
(preinstalled on Windows 10/11). On macOS: Xcode Command Line Tools.

```
npm install
npm run tauri dev      # run with hot reload
npm run tauri build    # produce the platform installer in src-tauri/target/release/bundle
```

Releases are built by GitHub Actions (`.github/workflows/release.yml`): pushing a
`v*` tag builds the Windows NSIS installer and a universal macOS DMG and attaches
them to a GitHub Release.

## Data locations

| What | Windows | macOS |
|---|---|---|
| Recordings, downloads, exports | `%USERPROFILE%\Music\Adagio` | `~/Music/Adagio` |
| Library database | `%APPDATA%\com.adagio.recorder\adagio.db` | `~/Library/Application Support/com.adagio.recorder/adagio.db` |
| ffmpeg / yt-dlp binaries | `%APPDATA%\com.adagio.recorder\bin` | `~/Library/Application Support/com.adagio.recorder/bin` |

## Architecture

- `src-tauri/src/recorder.rs` — cpal capture on a dedicated thread (mic input +
  WASAPI loopback on the default output device), 16-bit WAV writing, pause/resume,
  level events. Combined mode records two WAVs and mixes them with ffmpeg `amix`
  on stop.
- `src-tauri/src/tools.rs` — ffmpeg/yt-dlp discovery (app bin dir, then PATH) and
  auto-download with progress events.
- `src-tauri/src/audio.rs` — probe, waveform peaks, `silencedetect` parsing, MP3
  export with filters, split & merge.
- `src-tauri/src/youtube.rs` — yt-dlp job queue (one worker thread), progress
  parsing, cancellation, library ingestion.
- `src-tauri/src/db.rs` — rusqlite (bundled) library store.
- `src/` — vanilla TypeScript frontend; one module per tab, typed IPC in `ipc.ts`.
