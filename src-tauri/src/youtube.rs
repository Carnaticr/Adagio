use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::io::{BufRead, BufReader};
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

use crate::{audio, db, tools};

#[derive(Default)]
pub struct YtState {
    queue: Mutex<VecDeque<Job>>,
    worker_running: AtomicBool,
    next_id: AtomicU64,
    current: Mutex<Option<CurrentJob>>,
}

struct CurrentJob {
    id: u64,
    child: Option<Child>,
    canceled: bool,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct YtOpts {
    pub bitrate: u32,
    pub embed_thumbnail: bool,
    pub playlist_mode: String, // "single" | "first_n" | "all"
    pub playlist_n: u32,
}

#[derive(Clone)]
struct Job {
    id: u64,
    url: String,
    opts: YtOpts,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct YtUpdate {
    id: u64,
    status: String, // queued | running | done | error | canceled
    pct: f64,
    speed: String,
    eta: String,
    message: String,
}

fn emit(app: &AppHandle, u: YtUpdate) {
    let _ = app.emit("yt:update", u);
}

pub fn queue(app: AppHandle, url: String, opts: YtOpts) -> Result<u64, String> {
    if tools::ytdlp_path(&app).is_none() || tools::ffmpeg_path(&app).is_none() {
        return Err("yt-dlp and ffmpeg are required — use Install Tools first".into());
    }
    let state = app.state::<YtState>();
    let id = state.next_id.fetch_add(1, Ordering::SeqCst) + 1;
    state.queue.lock().unwrap().push_back(Job { id, url, opts });
    emit(
        &app,
        YtUpdate { id, status: "queued".into(), pct: 0.0, speed: String::new(), eta: String::new(), message: String::new() },
    );

    if !state.worker_running.swap(true, Ordering::SeqCst) {
        let app2 = app.clone();
        std::thread::spawn(move || {
            worker(app2);
        });
    }
    Ok(id)
}

pub fn cancel(app: &AppHandle, id: u64) -> Result<(), String> {
    let state = app.state::<YtState>();
    // Remove from queue if still pending
    {
        let mut q = state.queue.lock().unwrap();
        let before = q.len();
        q.retain(|j| j.id != id);
        if q.len() < before {
            emit(
                app,
                YtUpdate { id, status: "canceled".into(), pct: 0.0, speed: String::new(), eta: String::new(), message: String::new() },
            );
            return Ok(());
        }
    }
    // Kill if currently running
    let mut cur = state.current.lock().unwrap();
    if let Some(c) = cur.as_mut() {
        if c.id == id {
            c.canceled = true;
            if let Some(child) = c.child.as_mut() {
                let _ = child.kill();
            }
        }
    }
    Ok(())
}

fn worker(app: AppHandle) {
    loop {
        let job = {
            let state = app.state::<YtState>();
            let mut q = state.queue.lock().unwrap();
            match q.pop_front() {
                Some(j) => j,
                None => {
                    state.worker_running.store(false, Ordering::SeqCst);
                    return;
                }
            }
        };
        run_job(&app, job);
    }
}

fn run_job(app: &AppHandle, job: Job) {
    let id = job.id;
    emit(
        app,
        YtUpdate { id, status: "running".into(), pct: 0.0, speed: String::new(), eta: String::new(), message: "Starting…".into() },
    );

    let result = (|| -> Result<Vec<String>, String> {
        let ytdlp = tools::ytdlp_path(app).ok_or("yt-dlp missing")?;
        let bin = tools::bin_dir(app)?;
        let music = tools::music_dir(app)?;

        let mut cmd = tools::hidden_cmd(&ytdlp);
        cmd.args([
            "-x",
            "--audio-format",
            "mp3",
            "--audio-quality",
            &format!("{}K", job.opts.bitrate),
            "--embed-metadata",
            "--windows-filenames",
            "--newline",
            "--progress-template",
            "PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print",
            "after_move:filepath",
            "--no-simulate",
        ]);
        cmd.arg("--ffmpeg-location").arg(&bin);
        if job.opts.embed_thumbnail {
            cmd.arg("--embed-thumbnail");
        }
        match job.opts.playlist_mode.as_str() {
            "first_n" => {
                cmd.arg("--yes-playlist");
                cmd.arg("--playlist-items").arg(format!("1:{}", job.opts.playlist_n.max(1)));
            }
            "all" => {
                cmd.arg("--yes-playlist");
            }
            _ => {
                cmd.arg("--no-playlist");
            }
        }
        cmd.arg("-P").arg(&music);
        cmd.args(["-o", "%(title)s.%(ext)s"]);
        cmd.arg(&job.url);
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

        let mut child = cmd.spawn().map_err(|e| format!("failed to start yt-dlp: {e}"))?;
        let stdout = child.stdout.take().ok_or("no stdout")?;
        let stderr = child.stderr.take().ok_or("no stderr")?;

        {
            let state = app.state::<YtState>();
            *state.current.lock().unwrap() = Some(CurrentJob { id, child: Some(child), canceled: false });
        }

        // Collect stderr on a side thread (errors/warnings).
        let stderr_handle = std::thread::spawn(move || {
            let mut text = String::new();
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                if line.contains("ERROR") {
                    text.push_str(&line);
                    text.push('\n');
                }
            }
            text
        });

        let mut files: Vec<String> = Vec::new();
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Some(rest) = line.strip_prefix("PROG|") {
                let parts: Vec<&str> = rest.split('|').collect();
                let pct = parts
                    .first()
                    .and_then(|p| p.trim().trim_end_matches('%').parse::<f64>().ok())
                    .unwrap_or(0.0);
                emit(
                    app,
                    YtUpdate {
                        id,
                        status: "running".into(),
                        pct,
                        speed: parts.get(1).unwrap_or(&"").trim().to_string(),
                        eta: parts.get(2).unwrap_or(&"").trim().to_string(),
                        message: String::new(),
                    },
                );
            } else {
                let trimmed = line.trim();
                if !trimmed.is_empty() && std::path::Path::new(trimmed).exists() {
                    files.push(trimmed.to_string());
                    emit(
                        app,
                        YtUpdate {
                            id,
                            status: "running".into(),
                            pct: 100.0,
                            speed: String::new(),
                            eta: String::new(),
                            message: format!("Saved {}", std::path::Path::new(trimmed).file_name().unwrap_or_default().to_string_lossy()),
                        },
                    );
                }
            }
        }

        let (status, canceled) = {
            let state = app.state::<YtState>();
            let mut cur = state.current.lock().unwrap();
            let c = cur.as_mut().ok_or("job state lost")?;
            let status = c
                .child
                .as_mut()
                .ok_or("child lost")?
                .wait()
                .map_err(|e| e.to_string())?;
            let canceled = c.canceled;
            *cur = None;
            (status, canceled)
        };
        let err_text = stderr_handle.join().unwrap_or_default();

        if canceled {
            return Err("__canceled__".into());
        }
        if !status.success() && files.is_empty() {
            let msg = if err_text.trim().is_empty() {
                format!("yt-dlp exited with {status}")
            } else {
                err_text.trim().to_string()
            };
            return Err(msg);
        }
        Ok(files)
    })();

    match result {
        Ok(files) => {
            for f in &files {
                let info = audio::probe(app, f).unwrap_or_default();
                let title = if info.title.is_empty() {
                    std::path::Path::new(f)
                        .file_stem()
                        .map(|s| s.to_string_lossy().into_owned())
                        .unwrap_or_else(|| "download".into())
                } else {
                    info.title.clone()
                };
                let _ = db::insert(
                    app,
                    &title,
                    &info.artist,
                    &info.album,
                    f,
                    "youtube",
                    "",
                    info.duration_ms,
                    info.size_bytes,
                );
            }
            let _ = app.emit("lib:changed", ());
            emit(
                app,
                YtUpdate {
                    id,
                    status: "done".into(),
                    pct: 100.0,
                    speed: String::new(),
                    eta: String::new(),
                    message: format!("{} file(s) downloaded", files.len()),
                },
            );
        }
        Err(e) if e == "__canceled__" => {
            emit(
                app,
                YtUpdate { id, status: "canceled".into(), pct: 0.0, speed: String::new(), eta: String::new(), message: String::new() },
            );
        }
        Err(e) => {
            emit(
                app,
                YtUpdate { id, status: "error".into(), pct: 0.0, speed: String::new(), eta: String::new(), message: e },
            );
        }
    }
}
