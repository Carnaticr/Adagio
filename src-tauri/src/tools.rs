use serde::Serialize;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use tauri::{AppHandle, Emitter, Manager};

#[cfg(windows)]
mod platform {
    pub const YTDLP_URL: &str =
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";
    pub const FFMPEG_EXE: &str = "ffmpeg.exe";
    pub const FFPROBE_EXE: &str = "ffprobe.exe";
    pub const YTDLP_EXE: &str = "yt-dlp.exe";
}

#[cfg(target_os = "macos")]
mod platform {
    pub const YTDLP_URL: &str =
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos";
    pub const FFMPEG_EXE: &str = "ffmpeg";
    pub const FFPROBE_EXE: &str = "ffprobe";
    pub const YTDLP_EXE: &str = "yt-dlp";
}

#[cfg(all(unix, not(target_os = "macos")))]
mod platform {
    pub const YTDLP_URL: &str =
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp";
    pub const FFMPEG_EXE: &str = "ffmpeg";
    pub const FFPROBE_EXE: &str = "ffprobe";
    pub const YTDLP_EXE: &str = "yt-dlp";
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ToolsStatus {
    pub ffmpeg: bool,
    pub ytdlp: bool,
    pub bin_dir: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct ToolsProgress {
    stage: String,
    pct: f64,
    done: bool,
    error: Option<String>,
}

/// Build a Command that never flashes a console window (Windows-only concern).
pub fn hidden_cmd(program: &Path) -> Command {
    let mut c = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    c
}

#[cfg(unix)]
fn make_executable(p: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = fs::metadata(p).map_err(|e| e.to_string())?.permissions();
    perms.set_mode(0o755);
    fs::set_permissions(p, perms).map_err(|e| e.to_string())
}

pub fn bin_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("bin");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

/// Directory where recordings and downloads are stored: <Music>/Adagio
pub fn music_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let base = app
        .path()
        .audio_dir()
        .or_else(|_| app.path().home_dir().map(|h| h.join("Music")))
        .map_err(|e| e.to_string())?;
    let dir = base.join("Adagio");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

fn find_in_path(exe: &str) -> Option<PathBuf> {
    if let Some(path_var) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path_var) {
            let candidate = dir.join(exe);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    // GUI apps on macOS/Linux launch with a minimal PATH that misses Homebrew
    // and /usr/local — check the usual install locations explicitly.
    #[cfg(unix)]
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        let candidate = Path::new(dir).join(exe);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn tool_path(app: &AppHandle, exe: &str) -> Option<PathBuf> {
    if let Ok(dir) = bin_dir(app) {
        let local = dir.join(exe);
        if local.is_file() {
            return Some(local);
        }
    }
    find_in_path(exe)
}

pub fn ffmpeg_path(app: &AppHandle) -> Option<PathBuf> {
    tool_path(app, platform::FFMPEG_EXE)
}

pub fn ffprobe_path(app: &AppHandle) -> Option<PathBuf> {
    tool_path(app, platform::FFPROBE_EXE)
}

pub fn ytdlp_path(app: &AppHandle) -> Option<PathBuf> {
    tool_path(app, platform::YTDLP_EXE)
}

pub fn status(app: &AppHandle) -> Result<ToolsStatus, String> {
    Ok(ToolsStatus {
        ffmpeg: ffmpeg_path(app).is_some() && ffprobe_path(app).is_some(),
        ytdlp: ytdlp_path(app).is_some(),
        bin_dir: bin_dir(app)?.to_string_lossy().into_owned(),
    })
}

fn emit_progress(app: &AppHandle, stage: &str, pct: f64, done: bool, error: Option<String>) {
    let _ = app.emit(
        "tools:progress",
        ToolsProgress { stage: stage.into(), pct, done, error },
    );
}

fn download(app: &AppHandle, stage: &str, url: &str, dest: &Path) -> Result<(), String> {
    let resp = ureq::get(url)
        .timeout(std::time::Duration::from_secs(1800))
        .call()
        .map_err(|e| format!("download failed: {e}"))?;
    let total: u64 = resp
        .header("Content-Length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let mut reader = resp.into_reader();
    let tmp = dest.with_extension("part");
    let mut file = fs::File::create(&tmp).map_err(|e| e.to_string())?;
    let mut buf = [0u8; 65536];
    let mut read_total: u64 = 0;
    let mut last_pct = -1.0f64;
    loop {
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        read_total += n as u64;
        if total > 0 {
            let pct = (read_total as f64 / total as f64) * 100.0;
            if pct - last_pct >= 1.0 {
                last_pct = pct;
                emit_progress(app, stage, pct, false, None);
            }
        }
    }
    drop(file);
    fs::rename(&tmp, dest).map_err(|e| e.to_string())?;
    Ok(())
}

/// Extract entries from a zip whose (slash-normalized) names end with the given
/// suffixes, writing each to dest_dir under its out name.
fn extract_from_zip(
    app: &AppHandle,
    zip_path: &Path,
    dest_dir: &Path,
    wanted: &[(&str, &str)],
) -> Result<usize, String> {
    let file = fs::File::open(zip_path).map_err(|e| e.to_string())?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
    let total = archive.len();
    let mut found = 0;
    for i in 0..total {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        if entry.is_dir() {
            continue;
        }
        let name = entry.name().replace('\\', "/");
        for (suffix, out_name) in wanted {
            if name.ends_with(suffix) {
                let out_path = dest_dir.join(out_name);
                let mut out = fs::File::create(&out_path).map_err(|e| e.to_string())?;
                std::io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
                drop(out);
                #[cfg(unix)]
                make_executable(&out_path)?;
                found += 1;
                break;
            }
        }
        emit_progress(app, "extract", (i as f64 / total as f64) * 100.0, false, None);
    }
    Ok(found)
}

#[cfg(windows)]
fn install_ffmpeg(app: &AppHandle, bin: &Path) -> Result<(), String> {
    const URL: &str = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip";
    emit_progress(app, "ffmpeg", 0.0, false, None);
    let zip_path = bin.join("ffmpeg.zip");
    download(app, "ffmpeg", URL, &zip_path)?;
    emit_progress(app, "extract", 0.0, false, None);
    let found = extract_from_zip(
        app,
        &zip_path,
        bin,
        &[("/bin/ffmpeg.exe", "ffmpeg.exe"), ("/bin/ffprobe.exe", "ffprobe.exe")],
    )?;
    let _ = fs::remove_file(&zip_path);
    if found < 2 {
        return Err("ffmpeg.exe / ffprobe.exe not found in archive".into());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn install_ffmpeg(app: &AppHandle, bin: &Path) -> Result<(), String> {
    // evermeet.cx ships one static binary per zip (Intel builds; they run on
    // Apple Silicon via Rosetta 2).
    for (tool, url) in [
        ("ffmpeg", "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"),
        ("ffprobe", "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"),
    ] {
        emit_progress(app, tool, 0.0, false, None);
        let zip_path = bin.join(format!("{tool}.zip"));
        download(app, tool, url, &zip_path)?;
        let found = extract_from_zip(app, &zip_path, bin, &[(tool, tool)])?;
        let _ = fs::remove_file(&zip_path);
        if found < 1 {
            return Err(format!("{tool} not found in archive"));
        }
    }
    Ok(())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn install_ffmpeg(_app: &AppHandle, _bin: &Path) -> Result<(), String> {
    Err("Automatic ffmpeg install is not supported on this OS — install ffmpeg with your package manager (e.g. apt install ffmpeg) and restart the app".into())
}

/// Download yt-dlp and ffmpeg into the app's bin dir. Runs on a background
/// thread; progress is reported via the `tools:progress` event.
pub fn install(app: AppHandle) {
    std::thread::spawn(move || {
        let result = (|| -> Result<(), String> {
            let bin = bin_dir(&app)?;

            if ytdlp_path(&app).is_none() {
                emit_progress(&app, "yt-dlp", 0.0, false, None);
                let dest = bin.join(platform::YTDLP_EXE);
                download(&app, "yt-dlp", platform::YTDLP_URL, &dest)?;
                #[cfg(unix)]
                make_executable(&dest)?;
            }

            if ffmpeg_path(&app).is_none() || ffprobe_path(&app).is_none() {
                install_ffmpeg(&app, &bin)?;
            }
            Ok(())
        })();

        match result {
            Ok(()) => emit_progress(&app, "done", 100.0, true, None),
            Err(e) => emit_progress(&app, "error", 0.0, true, Some(e)),
        }
    });
}
