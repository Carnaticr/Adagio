# Adagio — Build Summary

**Repo:** https://github.com/Carnaticr/Adagio (public)
**Release:** [v0.1.0](https://github.com/Carnaticr/Adagio/releases/tag/v0.1.0)
**Built:** 2026-07-16 → published 2026-07-17

## What it is
A lightweight, offline-first desktop sound recorder for **Windows and macOS**, built
with **Tauri 2** (Rust backend + native webview, vanilla TypeScript + Vite frontend —
no framework, no Electron).

## Features delivered
- **Recording** — Voice (mic), System audio ("what you hear"), and Combined
  (mic + system mixed). Pause/resume, live waveform, per-source level meters, timer.
  Global hotkeys `Ctrl+Alt+R` (start/stop) and `Ctrl+Alt+P` (pause).
- **YouTube → MP3** — URL to MP3 via yt-dlp; bitrate 128–320, embedded metadata +
  cover art, playlist modes (single / first N / whole), queued downloads with progress.
- **MP3 export** — bitrate, ID3 metadata (title/artist/album/track/artwork), loudness
  normalization, fade in/out, basic noise reduction (ffmpeg `afftdn`).
- **Smart split by silence** — configurable threshold (dB) / min silence / min segment;
  waveform preview with shaded silences; click to add cuts, drag to fine-tune,
  shift-click remove, alt-click audition; exports `Name_01.mp3`, `Name_02.mp3`, …
- **Library** — SQLite (rusqlite), searchable, folder/project grouping, playback with
  0.5×–2× speed + skip-silence, bulk export/merge/delete, reveal in file manager.

## Architecture
| File | Responsibility |
|---|---|
| `src-tauri/src/recorder.rs` | cpal capture thread (mic + WASAPI loopback / BlackHole), WAV writing, pause/resume, level events, combined-mode ffmpeg mixdown |
| `src-tauri/src/tools.rs` | ffmpeg/yt-dlp discovery + per-platform auto-download |
| `src-tauri/src/audio.rs` | probe, waveform peaks, silencedetect parsing, MP3 export, split & merge |
| `src-tauri/src/youtube.rs` | yt-dlp job queue (worker thread), progress, cancel, library ingest |
| `src-tauri/src/db.rs` | SQLite library store |
| `src/*.ts` | one module per tab; typed IPC in `ipc.ts` |

## Cross-platform notes
- **Tools**: Windows pulls ffmpeg from gyan.dev; macOS uses `yt-dlp_macos` +
  evermeet.cx static ffmpeg (Intel, runs via Rosetta 2 on Apple Silicon).
- **System audio**: WASAPI loopback on Windows (works out of the box); macOS has no
  OS loopback API, so it detects a virtual device (BlackHole/Soundflower/Loopback).
- **macOS app is unsigned** — first launch needs right-click → Open.

## CI / distribution
`.github/workflows/release.yml` (tauri-action): pushing a `v*` tag builds the Windows
NSIS installer and a universal macOS DMG and attaches them to a GitHub Release.
The v0.1.0 run took **13 min** end-to-end.

## Verification done
- Windows: recorded via global hotkey → valid mono 16-bit WAV + matching DB row;
  TypeScript + Rust compile with zero warnings; local release NSIS installer built.
- Tools installed & verified (ffmpeg 8.1.2, yt-dlp 2026.07.04, libmp3lame encode OK).
- macOS: builds & bundles cleanly in CI, but **not runtime-tested** (no Mac available).

## Release assets
| File | Size | Platform |
|---|---|---|
| `Adagio_0.1.0_x64-setup.exe` | 3.4 MB | Windows 10/11 |
| `Adagio_0.1.0_universal.dmg` | 8.3 MB | macOS 10.15+ (Intel + Apple Silicon) |

## Known follow-ups
- macOS runtime testing (mic-permission flow, BlackHole device pickup).
- Spec's "tie Folders/Projects into Kinezys Base templates" — not implemented
  (library has a plain `folder` field); needs clarification on what Kinezys Base is.
