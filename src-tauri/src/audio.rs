use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Emitter};

use crate::{db, tools};

fn ffmpeg(app: &AppHandle) -> Result<PathBuf, String> {
    tools::ffmpeg_path(app).ok_or_else(|| "ffmpeg is not installed — use Install Tools".to_string())
}

fn ffprobe(app: &AppHandle) -> Result<PathBuf, String> {
    tools::ffprobe_path(app).ok_or_else(|| "ffprobe is not installed — use Install Tools".to_string())
}

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct ProbeInfo {
    pub duration_ms: i64,
    pub size_bytes: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
}

pub fn probe(app: &AppHandle, path: &str) -> Result<ProbeInfo, String> {
    let size = std::fs::metadata(path).map(|m| m.len() as i64).unwrap_or(0);

    // WAV fallback that works without ffprobe (offline-first core).
    if ffprobe(app).is_err() {
        if path.to_lowercase().ends_with(".wav") {
            if let Ok(reader) = hound::WavReader::open(path) {
                let spec = reader.spec();
                let ms = (reader.duration() as f64 / spec.sample_rate as f64 * 1000.0) as i64;
                return Ok(ProbeInfo { duration_ms: ms, size_bytes: size, ..Default::default() });
            }
        }
        return Ok(ProbeInfo { size_bytes: size, ..Default::default() });
    }

    let out = tools::hidden_cmd(&ffprobe(app)?)
        .args(["-v", "quiet", "-print_format", "json", "-show_format"])
        .arg(path)
        .output()
        .map_err(|e| e.to_string())?;
    let json: serde_json::Value =
        serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())?;
    let fmt = &json["format"];
    let duration_ms = fmt["duration"]
        .as_str()
        .and_then(|s| s.parse::<f64>().ok())
        .map(|s| (s * 1000.0) as i64)
        .unwrap_or(0);
    let tag = |k: &str| -> String {
        fmt["tags"][k]
            .as_str()
            .or_else(|| fmt["tags"][k.to_uppercase()].as_str())
            .unwrap_or("")
            .to_string()
    };
    Ok(ProbeInfo {
        duration_ms,
        size_bytes: size,
        title: tag("title"),
        artist: tag("artist"),
        album: tag("album"),
    })
}

/// Decode to mono 8 kHz PCM and reduce to `points` peak values (0..1).
pub fn waveform(app: &AppHandle, path: &str, points: usize) -> Result<Vec<f32>, String> {
    let out = tools::hidden_cmd(&ffmpeg(app)?)
        .args(["-v", "error", "-i"])
        .arg(path)
        .args(["-ac", "1", "-ar", "8000", "-f", "s16le", "pipe:1"])
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!(
            "ffmpeg decode failed: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    let bytes = out.stdout;
    let n_samples = bytes.len() / 2;
    if n_samples == 0 || points == 0 {
        return Ok(vec![0.0; points]);
    }
    let per_bucket = (n_samples as f64 / points as f64).max(1.0);
    let mut peaks = vec![0.0f32; points];
    for i in 0..n_samples {
        let lo = bytes[i * 2] as u16;
        let hi = bytes[i * 2 + 1] as u16;
        let v = i16::from_le_bytes([lo as u8, (hi & 0xff) as u8]);
        let a = (v as f32 / 32768.0).abs();
        let bucket = ((i as f64 / per_bucket) as usize).min(points - 1);
        if a > peaks[bucket] {
            peaks[bucket] = a;
        }
    }
    Ok(peaks)
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SilenceRange {
    pub start: f64,
    pub end: f64,
}

/// Run ffmpeg silencedetect and parse silence ranges (seconds).
pub fn silences(app: &AppHandle, path: &str, noise_db: f64, min_dur: f64) -> Result<Vec<SilenceRange>, String> {
    let filter = format!("silencedetect=noise={noise_db}dB:d={min_dur}");
    let out = tools::hidden_cmd(&ffmpeg(app)?)
        .args(["-i"])
        .arg(path)
        .args(["-af", &filter, "-f", "null", "-"])
        .output()
        .map_err(|e| e.to_string())?;
    let stderr = String::from_utf8_lossy(&out.stderr);
    let mut ranges = Vec::new();
    let mut current_start: Option<f64> = None;
    for line in stderr.lines() {
        if let Some(idx) = line.find("silence_start: ") {
            let val = line[idx + 15..].trim().split_whitespace().next().unwrap_or("");
            current_start = val.parse::<f64>().ok();
        } else if let Some(idx) = line.find("silence_end: ") {
            let rest = &line[idx + 13..];
            let val = rest.trim().split_whitespace().next().unwrap_or("");
            if let (Some(start), Ok(end)) = (current_start.take(), val.parse::<f64>()) {
                ranges.push(SilenceRange { start, end });
            }
        }
    }
    Ok(ranges)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportOpts {
    pub src_path: String,
    pub out_name: Option<String>,
    pub bitrate: u32,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub track: Option<u32>,
    pub art_path: Option<String>,
    pub normalize: bool,
    pub fade_in: f64,
    pub fade_out: f64,
    pub denoise: bool,
}

fn unique_path(dir: &Path, stem: &str, ext: &str) -> PathBuf {
    let sanitized: String = stem
        .chars()
        .map(|c| if r#"<>:"/\|?*"#.contains(c) { '_' } else { c })
        .collect();
    let mut candidate = dir.join(format!("{sanitized}.{ext}"));
    let mut i = 2;
    while candidate.exists() {
        candidate = dir.join(format!("{sanitized} ({i}).{ext}"));
        i += 1;
    }
    candidate
}

pub fn export_mp3(app: &AppHandle, opts: ExportOpts) -> Result<db::Entry, String> {
    let ffmpeg_bin = ffmpeg(app)?;
    let music = tools::music_dir(app)?;
    let stem = opts
        .out_name
        .clone()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| {
            if opts.title.trim().is_empty() {
                Path::new(&opts.src_path)
                    .file_stem()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "export".into())
            } else {
                opts.title.clone()
            }
        });
    let out_path = unique_path(&music, &stem, "mp3");

    let mut filters: Vec<String> = Vec::new();
    if opts.denoise {
        filters.push("afftdn=nf=-25".into());
    }
    if opts.normalize {
        filters.push("loudnorm=I=-16:TP=-1.5:LRA=11".into());
    }
    if opts.fade_in > 0.0 {
        filters.push(format!("afade=t=in:st=0:d={}", opts.fade_in));
    }
    if opts.fade_out > 0.0 {
        let info = probe(app, &opts.src_path)?;
        let dur = info.duration_ms as f64 / 1000.0;
        let st = (dur - opts.fade_out).max(0.0);
        filters.push(format!("afade=t=out:st={st}:d={}", opts.fade_out));
    }

    let mut cmd = tools::hidden_cmd(&ffmpeg_bin);
    cmd.args(["-y", "-i"]).arg(&opts.src_path);
    let has_art = opts.art_path.as_deref().map(|p| !p.is_empty()).unwrap_or(false);
    if has_art {
        cmd.arg("-i").arg(opts.art_path.as_deref().unwrap());
        cmd.args(["-map", "0:a", "-map", "1:0", "-c:v", "mjpeg", "-disposition:v:0", "attached_pic"]);
    } else {
        cmd.args(["-map", "0:a"]);
    }
    if !filters.is_empty() {
        cmd.args(["-af", &filters.join(",")]);
    }
    cmd.args(["-c:a", "libmp3lame", "-b:a", &format!("{}k", opts.bitrate), "-id3v2_version", "3"]);
    if !opts.title.is_empty() {
        cmd.args(["-metadata", &format!("title={}", opts.title)]);
    }
    if !opts.artist.is_empty() {
        cmd.args(["-metadata", &format!("artist={}", opts.artist)]);
    }
    if !opts.album.is_empty() {
        cmd.args(["-metadata", &format!("album={}", opts.album)]);
    }
    if let Some(track) = opts.track {
        cmd.args(["-metadata", &format!("track={track}")]);
    }
    cmd.arg(&out_path);

    let out = cmd.output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("ffmpeg export failed: {}", String::from_utf8_lossy(&out.stderr)));
    }

    let info = probe(app, &out_path.to_string_lossy())?;
    let title = if opts.title.is_empty() {
        out_path.file_stem().unwrap_or_default().to_string_lossy().into_owned()
    } else {
        opts.title.clone()
    };
    let entry = db::insert(
        app,
        &title,
        &opts.artist,
        &opts.album,
        &out_path.to_string_lossy(),
        "export",
        "",
        info.duration_ms,
        info.size_bytes,
    )?;
    let _ = app.emit("lib:changed", ());
    Ok(entry)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SplitOpts {
    pub src_path: String,
    pub cuts: Vec<f64>,
    pub base_name: String,
    pub bitrate: u32,
    pub folder: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct SplitProgress {
    index: usize,
    total: usize,
}

pub fn split_export(app: &AppHandle, opts: SplitOpts) -> Result<Vec<db::Entry>, String> {
    let ffmpeg_bin = ffmpeg(app)?;
    let music = tools::music_dir(app)?;
    let info = probe(app, &opts.src_path)?;
    let duration = info.duration_ms as f64 / 1000.0;

    let mut cuts = opts.cuts.clone();
    cuts.retain(|c| *c > 0.05 && *c < duration - 0.05);
    cuts.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mut bounds = vec![0.0];
    bounds.extend(cuts);
    bounds.push(duration);

    let total = bounds.len() - 1;
    let mut entries = Vec::new();
    for i in 0..total {
        let (a, b) = (bounds[i], bounds[i + 1]);
        let name = format!("{}_{:02}", opts.base_name, i + 1);
        let out_path = unique_path(&music, &name, "mp3");
        let output = tools::hidden_cmd(&ffmpeg_bin)
            .args(["-y", "-ss", &format!("{a:.3}"), "-to", &format!("{b:.3}"), "-i"])
            .arg(&opts.src_path)
            .args([
                "-vn",
                "-c:a",
                "libmp3lame",
                "-b:a",
                &format!("{}k", opts.bitrate),
                "-metadata",
                &format!("title={name}"),
                "-metadata",
                &format!("track={}", i + 1),
                "-id3v2_version",
                "3",
            ])
            .arg(&out_path)
            .output()
            .map_err(|e| e.to_string())?;
        if !output.status.success() {
            return Err(format!(
                "ffmpeg split failed on segment {}: {}",
                i + 1,
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        let seg_info = probe(app, &out_path.to_string_lossy())?;
        entries.push(db::insert(
            app,
            &name,
            "",
            "",
            &out_path.to_string_lossy(),
            "segment",
            &opts.folder,
            seg_info.duration_ms,
            seg_info.size_bytes,
        )?);
        let _ = app.emit("split:progress", SplitProgress { index: i + 1, total });
    }
    let _ = app.emit("lib:changed", ());
    Ok(entries)
}

pub fn merge(app: &AppHandle, paths: Vec<String>, title: String, bitrate: u32) -> Result<db::Entry, String> {
    if paths.len() < 2 {
        return Err("Select at least two items to merge".into());
    }
    let ffmpeg_bin = ffmpeg(app)?;
    let music = tools::music_dir(app)?;
    let out_path = unique_path(&music, &title, "mp3");

    let mut cmd = tools::hidden_cmd(&ffmpeg_bin);
    cmd.arg("-y");
    for p in &paths {
        cmd.arg("-i").arg(p);
    }
    let inputs: String = (0..paths.len()).map(|i| format!("[{i}:a]")).collect();
    let filter = format!("{inputs}concat=n={}:v=0:a=1[a]", paths.len());
    cmd.args(["-filter_complex", &filter, "-map", "[a]"]);
    cmd.args(["-c:a", "libmp3lame", "-b:a", &format!("{bitrate}k"), "-id3v2_version", "3"]);
    cmd.args(["-metadata", &format!("title={title}")]);
    cmd.arg(&out_path);
    let out = cmd.output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("ffmpeg merge failed: {}", String::from_utf8_lossy(&out.stderr)));
    }

    let info = probe(app, &out_path.to_string_lossy())?;
    let entry = db::insert(
        app,
        &title,
        "",
        "",
        &out_path.to_string_lossy(),
        "merge",
        "",
        info.duration_ms,
        info.size_bytes,
    )?;
    let _ = app.emit("lib:changed", ());
    Ok(entry)
}
