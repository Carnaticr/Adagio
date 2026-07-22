# Adagio for macOS — Native (SwiftUI)

A ground-up native rewrite of Adagio in **SwiftUI + AVFoundation + ScreenCaptureKit**,
built to fix the two problems in the cross-platform Tauri build on macOS:

### 1. "Tools not located" — fixed
The Tauri app relied on finding `ffmpeg`/`yt-dlp` on `PATH`, but a Finder-launched
macOS app inherits a minimal `PATH` that excludes Homebrew. This native app:
- **Needs no external tools for its core.** Recording, playback, silence detection,
  splitting, merging, and export to **M4A/AAC** are all done with AVFoundation.
- ffmpeg (for MP3) and yt-dlp (for YouTube) are **optional**. `ToolLocator` finds
  them by probing `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, … directly
  instead of trusting `PATH`, plus a user-set folder in **Settings ▸ Tools** and an
  optional one-click auto-download.

### 2. "Unable to save recordings" — fixed
The Tauri app tried to write into `~/Music`, which macOS blocks without explicit
consent, so files silently failed to save. This app writes everything to
`~/Library/Application Support/com.adagio.recorder/Recordings/`, which is **always
writable**, and requests microphone permission properly (`NSMicrophoneUsageDescription`
+ hardened-runtime audio-input entitlement). The library is stored with **SwiftData**
in the same container.

Bonus: **system-audio recording needs no BlackHole/virtual device** — it uses
ScreenCaptureKit (macOS 13+) to capture "what you hear" directly.

## Requirements
- macOS 14.0 (Sonoma) or later
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project:
  `brew install xcodegen`

## Build & run
```bash
cd macos-native
xcodegen generate          # creates Adagio.xcodeproj from project.yml
open Adagio.xcodeproj       # then press ⌘R in Xcode
```
Or from the command line:
```bash
xcodegen generate
xcodebuild -project Adagio.xcodeproj -scheme Adagio -configuration Release build
```

On first run macOS will prompt for **Microphone** (voice) and **Screen Recording**
(system audio) permission — both are expected. For signed distribution set
`DEVELOPMENT_TEAM` in `project.yml`.

> Prefer not to use XcodeGen? Create a new macOS App target in Xcode (SwiftUI,
> "Adagio", bundle id `com.adagio.recorder`), then drag the `Adagio/` folder in,
> set the Info.plist and entitlements files, and add the microphone usage string.

## Structure
```
Adagio/
├── App/         AdagioApp (scenes + menus), ContentView, AppModel (shared state)
├── Models/      Recording (SwiftData), Types
├── Services/    AudioRecorder, SystemAudioCapture (ScreenCaptureKit),
│                AudioPlayer, SilenceDetector, AudioMixer, AudioExporter,
│                ToolLocator, ToolInstaller, YouTubeService, Shell, Storage
├── Features/    RecordView, LiveWaveform, LibraryView, EditSheet, SplitView,
│                YouTubeView, SettingsView, PlayerBar
└── Resources/   Assets.xcassets
```

## Feature parity with the Tauri build
- ✅ Voice / System / Combined recording, pause-resume, live waveform + meters, timer
- ✅ Menu shortcuts ⌘R (start/stop), ⌘P (pause/resume)
- ✅ Library (SwiftData) with search, folders, playback (0.5–2×, skip-silence), bulk merge/delete, import
- ✅ Smart split by silence with an interactive waveform editor (native detection)
- ✅ Export to M4A (no tools) or MP3 with normalize/fade/denoise (ffmpeg)
- ✅ YouTube → MP3 queue (yt-dlp)

## Status
Written on a Windows workstation, so it has **not been compiled or run on a Mac**.
The audio pipeline (AVFoundation + ScreenCaptureKit) is the area most in need of
on-device verification — especially `SystemAudioCapture` (CMSampleBuffer handling)
and Combined-mode mixing/alignment. Everything is structured to build cleanly under
Xcode 15 targeting macOS 14; please report any compile issues and I'll resolve them.

Global (system-wide) hotkeys that work while the app is unfocused are not yet
implemented — the ⌘R/⌘P shortcuts work while Adagio is focused. That's a natural
next step (via a Carbon `RegisterEventHotKey` shim) if you want it.
