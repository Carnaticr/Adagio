use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};

use crate::{db, tools};

const SRC_MIC: u8 = 0;
const SRC_SYS: u8 = 1;

pub struct RecState {
    inner: Mutex<Option<ActiveRec>>,
}

impl Default for RecState {
    fn default() -> Self {
        Self { inner: Mutex::new(None) }
    }
}

struct ActiveRec {
    ctl_tx: mpsc::Sender<Ctl>,
    paused: Arc<AtomicBool>,
}

enum Ctl {
    Pause,
    Resume,
    Stop { cancel: bool },
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Levels {
    elapsed_ms: u64,
    mic: f32,
    sys: f32,
    peak: f32,
    paused: bool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct MicInfo {
    pub name: String,
    pub is_default: bool,
}

pub fn list_mics() -> Result<Vec<MicInfo>, String> {
    let host = cpal::default_host();
    let default_name = host
        .default_input_device()
        .and_then(|d| d.name().ok())
        .unwrap_or_default();
    let mut out = Vec::new();
    let devices = host.input_devices().map_err(|e| e.to_string())?;
    for dev in devices {
        if let Ok(name) = dev.name() {
            out.push(MicInfo { is_default: name == default_name, name });
        }
    }
    Ok(out)
}

pub fn start(app: AppHandle, state: &RecState, mode: String, mic_name: Option<String>) -> Result<(), String> {
    let mut guard = state.inner.lock().unwrap();
    if guard.is_some() {
        return Err("A recording is already in progress".into());
    }
    if mode == "combined" && tools::ffmpeg_path(&app).is_none() {
        return Err("Combined mode needs ffmpeg to mix the two sources — install tools first".into());
    }

    let (ctl_tx, ctl_rx) = mpsc::channel::<Ctl>();
    let paused = Arc::new(AtomicBool::new(false));
    let paused_clone = paused.clone();
    let app_clone = app.clone();
    let mode_clone = mode.clone();

    std::thread::spawn(move || {
        if let Err(e) = run_session(app_clone.clone(), mode_clone, mic_name, ctl_rx, paused_clone) {
            let _ = app_clone.emit("rec:error", e);
        }
    });

    *guard = Some(ActiveRec { ctl_tx, paused });
    Ok(())
}

pub fn pause(state: &RecState) -> Result<(), String> {
    let guard = state.inner.lock().unwrap();
    if let Some(rec) = guard.as_ref() {
        rec.paused.store(true, Ordering::SeqCst);
        rec.ctl_tx.send(Ctl::Pause).map_err(|e| e.to_string())?;
        Ok(())
    } else {
        Err("Not recording".into())
    }
}

pub fn resume(state: &RecState) -> Result<(), String> {
    let guard = state.inner.lock().unwrap();
    if let Some(rec) = guard.as_ref() {
        rec.paused.store(false, Ordering::SeqCst);
        rec.ctl_tx.send(Ctl::Resume).map_err(|e| e.to_string())?;
        Ok(())
    } else {
        Err("Not recording".into())
    }
}

pub fn stop(state: &RecState, cancel: bool) -> Result<(), String> {
    let mut guard = state.inner.lock().unwrap();
    if let Some(rec) = guard.take() {
        let _ = rec.ctl_tx.send(Ctl::Stop { cancel });
        Ok(())
    } else {
        Err("Not recording".into())
    }
}

pub fn is_active(state: &RecState) -> bool {
    state.inner.lock().unwrap().is_some()
}

struct SourceWriter {
    writer: hound::WavWriter<std::io::BufWriter<std::fs::File>>,
    path: PathBuf,
    channels: u16,
    sample_rate: u32,
    frames: u64,
}

fn build_stream(
    device: &cpal::Device,
    supported: &cpal::SupportedStreamConfig,
    src: u8,
    tx: mpsc::Sender<(u8, Vec<f32>)>,
) -> Result<cpal::Stream, String> {
    let config: cpal::StreamConfig = supported.config();
    let stream = match supported.sample_format() {
        cpal::SampleFormat::F32 => device.build_input_stream(
            &config,
            move |data: &[f32], _| {
                let _ = tx.send((src, data.to_vec()));
            },
            |e| eprintln!("stream error: {e}"),
            None,
        ),
        cpal::SampleFormat::I16 => device.build_input_stream(
            &config,
            move |data: &[i16], _| {
                let v: Vec<f32> = data.iter().map(|s| *s as f32 / 32768.0).collect();
                let _ = tx.send((src, v));
            },
            |e| eprintln!("stream error: {e}"),
            None,
        ),
        cpal::SampleFormat::U16 => device.build_input_stream(
            &config,
            move |data: &[u16], _| {
                let v: Vec<f32> = data.iter().map(|s| (*s as f32 - 32768.0) / 32768.0).collect();
                let _ = tx.send((src, v));
            },
            |e| eprintln!("stream error: {e}"),
            None,
        ),
        f => return Err(format!("Unsupported sample format: {f:?}")),
    }
    .map_err(|e| e.to_string())?;
    stream.play().map_err(|e| e.to_string())?;
    Ok(stream)
}

/// Device + config used to capture "what you hear".
/// Windows: WASAPI loopback — an input stream built on the default output device.
/// macOS: no OS loopback API; look for a virtual loopback input device.
#[cfg(not(target_os = "macos"))]
fn sys_capture_device(host: &cpal::Host) -> Result<(cpal::Device, cpal::SupportedStreamConfig), String> {
    let device = host
        .default_output_device()
        .ok_or("No output device found for system-audio capture")?;
    let cfg = device.default_output_config().map_err(|e| e.to_string())?;
    Ok((device, cfg))
}

#[cfg(target_os = "macos")]
fn sys_capture_device(host: &cpal::Host) -> Result<(cpal::Device, cpal::SupportedStreamConfig), String> {
    let devices = host.input_devices().map_err(|e| e.to_string())?;
    for dev in devices {
        if let Ok(name) = dev.name() {
            let n = name.to_lowercase();
            if n.contains("blackhole") || n.contains("soundflower") || n.contains("loopback") {
                let cfg = dev.default_input_config().map_err(|e| e.to_string())?;
                return Ok((dev, cfg));
            }
        }
    }
    Err("System-audio capture on macOS needs a virtual loopback device. Install BlackHole (free — existential.audio/blackhole), set your output to a Multi-Output Device that includes it, then try again.".into())
}

fn make_writer(path: PathBuf, channels: u16, sample_rate: u32) -> Result<SourceWriter, String> {
    let spec = hound::WavSpec {
        channels,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let writer = hound::WavWriter::create(&path, spec).map_err(|e| e.to_string())?;
    Ok(SourceWriter { writer, path, channels, sample_rate, frames: 0 })
}

fn run_session(
    app: AppHandle,
    mode: String,
    mic_name: Option<String>,
    ctl_rx: mpsc::Receiver<Ctl>,
    paused: Arc<AtomicBool>,
) -> Result<(), String> {
    let host = cpal::default_host();
    let want_mic = mode == "mic" || mode == "combined";
    let want_sys = mode == "system" || mode == "combined";

    let music = tools::music_dir(&app)?;
    let stamp = chrono::Local::now().format("%Y-%m-%d_%H-%M-%S").to_string();
    let base_name = format!("Recording_{stamp}");

    let (data_tx, data_rx) = mpsc::channel::<(u8, Vec<f32>)>();

    // Streams must stay alive (and on this thread) for the whole session.
    let mut streams: Vec<cpal::Stream> = Vec::new();
    let mut mic_writer: Option<SourceWriter> = None;
    let mut sys_writer: Option<SourceWriter> = None;

    if want_mic {
        let device = match &mic_name {
            Some(name) => host
                .input_devices()
                .map_err(|e| e.to_string())?
                .find(|d| d.name().map(|n| &n == name).unwrap_or(false))
                .ok_or_else(|| format!("Microphone '{name}' not found"))?,
            None => host
                .default_input_device()
                .ok_or("No microphone found")?,
        };
        let cfg = device.default_input_config().map_err(|e| e.to_string())?;
        let suffix = if want_sys { "_mic" } else { "" };
        let path = music.join(format!("{base_name}{suffix}.wav"));
        mic_writer = Some(make_writer(path, cfg.channels(), cfg.sample_rate().0)?);
        streams.push(build_stream(&device, &cfg, SRC_MIC, data_tx.clone())?);
    }

    if want_sys {
        let (device, cfg) = sys_capture_device(&host)?;
        let suffix = if want_mic { "_sys" } else { "" };
        let path = music.join(format!("{base_name}{suffix}.wav"));
        sys_writer = Some(make_writer(path, cfg.channels(), cfg.sample_rate().0)?);
        streams.push(build_stream(&device, &cfg, SRC_SYS, data_tx.clone())?);
    }

    drop(data_tx);

    let started = Instant::now();
    let mut paused_total = Duration::ZERO;
    let mut paused_since: Option<Instant> = None;
    let mut last_emit = Instant::now();
    let mut mic_acc: f32 = 0.0;
    let mut mic_n: u32 = 0;
    let mut sys_acc: f32 = 0.0;
    let mut sys_n: u32 = 0;
    let mut peak: f32 = 0.0;
    let mut cancel = false;

    'outer: loop {
        // Control messages
        match ctl_rx.recv_timeout(Duration::from_millis(30)) {
            Ok(Ctl::Pause) => {
                if paused_since.is_none() {
                    paused_since = Some(Instant::now());
                }
            }
            Ok(Ctl::Resume) => {
                if let Some(t) = paused_since.take() {
                    paused_total += t.elapsed();
                }
            }
            Ok(Ctl::Stop { cancel: c }) => {
                cancel = c;
                break 'outer;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break 'outer,
        }

        let is_paused = paused.load(Ordering::SeqCst);

        // Drain audio data
        while let Ok((src, samples)) = data_rx.try_recv() {
            if is_paused {
                continue;
            }
            let (acc, n, writer) = if src == SRC_MIC {
                (&mut mic_acc, &mut mic_n, mic_writer.as_mut())
            } else {
                (&mut sys_acc, &mut sys_n, sys_writer.as_mut())
            };
            for s in &samples {
                let a = s.abs();
                *acc += a * a;
                if a > peak {
                    peak = a;
                }
            }
            *n += samples.len() as u32;
            if let Some(w) = writer {
                for s in &samples {
                    let v = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
                    let _ = w.writer.write_sample(v);
                }
                w.frames += samples.len() as u64 / w.channels.max(1) as u64;
            }
        }

        // Emit levels ~10x/sec
        if last_emit.elapsed() >= Duration::from_millis(100) {
            let elapsed = if let Some(t) = paused_since {
                started.elapsed() - paused_total - t.elapsed()
            } else {
                started.elapsed() - paused_total
            };
            let mic_rms = if mic_n > 0 { (mic_acc / mic_n as f32).sqrt() } else { 0.0 };
            let sys_rms = if sys_n > 0 { (sys_acc / sys_n as f32).sqrt() } else { 0.0 };
            let _ = app.emit(
                "rec:levels",
                Levels {
                    elapsed_ms: elapsed.as_millis() as u64,
                    mic: mic_rms,
                    sys: sys_rms,
                    peak,
                    paused: is_paused,
                },
            );
            mic_acc = 0.0;
            mic_n = 0;
            sys_acc = 0.0;
            sys_n = 0;
            peak = 0.0;
            last_emit = Instant::now();
        }
    }

    // Stop capture before finalizing files.
    drop(streams);
    // Drain whatever is left in the channel.
    while data_rx.try_recv().is_ok() {}

    let elapsed = if let Some(t) = paused_since {
        started.elapsed() - paused_total - t.elapsed()
    } else {
        started.elapsed() - paused_total
    };

    let mut paths: Vec<PathBuf> = Vec::new();
    let mut duration_ms: i64 = elapsed.as_millis() as i64;
    if let Some(w) = mic_writer {
        if w.frames > 0 {
            duration_ms = ((w.frames as f64 / w.sample_rate as f64) * 1000.0) as i64;
        }
        let p = w.path.clone();
        w.writer.finalize().map_err(|e| e.to_string())?;
        paths.push(p);
    }
    if let Some(w) = sys_writer {
        let p = w.path.clone();
        w.writer.finalize().map_err(|e| e.to_string())?;
        paths.push(p);
    }

    if cancel {
        for p in &paths {
            let _ = std::fs::remove_file(p);
        }
        let _ = app.emit("rec:canceled", ());
        return Ok(());
    }

    // Combined: mix the two WAVs into one with ffmpeg, then remove the parts.
    let final_path = if paths.len() == 2 {
        let ffmpeg = tools::ffmpeg_path(&app).ok_or("ffmpeg missing for mixdown")?;
        let out = music.join(format!("{base_name}.wav"));
        let status = tools::hidden_cmd(&ffmpeg)
            .args(["-y", "-i"])
            .arg(&paths[0])
            .arg("-i")
            .arg(&paths[1])
            .args([
                "-filter_complex",
                "[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[a]",
                "-map",
                "[a]",
                "-ac",
                "2",
            ])
            .arg(&out)
            .status()
            .map_err(|e| e.to_string())?;
        if !status.success() {
            return Err("ffmpeg mixdown failed".into());
        }
        for p in &paths {
            let _ = std::fs::remove_file(p);
        }
        out
    } else {
        paths.into_iter().next().ok_or("Nothing was recorded")?
    };

    let size = std::fs::metadata(&final_path).map(|m| m.len() as i64).unwrap_or(0);
    let entry = db::insert(
        &app,
        &base_name,
        "",
        "",
        &final_path.to_string_lossy(),
        "recording",
        "",
        duration_ms,
        size,
    )?;
    let _ = app.emit("rec:done", entry);
    let _ = app.emit("lib:changed", ());
    Ok(())
}
