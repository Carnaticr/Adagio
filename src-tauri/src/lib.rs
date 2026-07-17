mod audio;
mod db;
mod recorder;
mod tools;
mod youtube;

use serde::Serialize;
use tauri::{AppHandle, Emitter};

// ---------- tools ----------

#[tauri::command]
fn tools_status(app: AppHandle) -> Result<tools::ToolsStatus, String> {
    tools::status(&app)
}

#[tauri::command]
fn tools_install(app: AppHandle) {
    tools::install(app);
}

// ---------- recorder ----------

#[tauri::command]
fn list_mics() -> Result<Vec<recorder::MicInfo>, String> {
    recorder::list_mics()
}

#[tauri::command]
fn rec_start(
    app: AppHandle,
    state: tauri::State<'_, recorder::RecState>,
    mode: String,
    mic: Option<String>,
) -> Result<(), String> {
    recorder::start(app, &state, mode, mic)
}

#[tauri::command]
fn rec_pause(state: tauri::State<'_, recorder::RecState>) -> Result<(), String> {
    recorder::pause(&state)
}

#[tauri::command]
fn rec_resume(state: tauri::State<'_, recorder::RecState>) -> Result<(), String> {
    recorder::resume(&state)
}

#[tauri::command]
fn rec_stop(state: tauri::State<'_, recorder::RecState>, cancel: bool) -> Result<(), String> {
    recorder::stop(&state, cancel)
}

#[tauri::command]
fn rec_active(state: tauri::State<'_, recorder::RecState>) -> bool {
    recorder::is_active(&state)
}

// ---------- library ----------

#[tauri::command]
fn lib_list(app: AppHandle, query: String, folder: String) -> Result<Vec<db::Entry>, String> {
    db::list(&app, &query, &folder)
}

#[tauri::command]
fn lib_update(
    app: AppHandle,
    id: i64,
    title: String,
    artist: String,
    album: String,
    tags: String,
    folder: String,
) -> Result<db::Entry, String> {
    db::update(&app, id, &title, &artist, &album, &tags, &folder)
}

#[tauri::command]
fn lib_delete(app: AppHandle, ids: Vec<i64>, delete_files: bool) -> Result<(), String> {
    let r = db::delete(&app, &ids, delete_files);
    let _ = app.emit("lib:changed", ());
    r
}

#[tauri::command]
fn lib_folders(app: AppHandle) -> Result<Vec<String>, String> {
    db::folders(&app)
}

#[tauri::command]
async fn lib_import(app: AppHandle, paths: Vec<String>) -> Result<Vec<db::Entry>, String> {
    let out = tauri::async_runtime::spawn_blocking(move || {
        let mut entries = Vec::new();
        for p in paths {
            let info = audio::probe(&app, &p).unwrap_or_default();
            let title = if info.title.is_empty() {
                std::path::Path::new(&p)
                    .file_stem()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "import".into())
            } else {
                info.title.clone()
            };
            entries.push(db::insert(
                &app,
                &title,
                &info.artist,
                &info.album,
                &p,
                "import",
                "",
                info.duration_ms,
                info.size_bytes,
            )?);
        }
        let _ = app.emit("lib:changed", ());
        Ok::<_, String>(entries)
    })
    .await
    .map_err(|e| e.to_string())?;
    out
}

#[tauri::command]
async fn lib_merge(app: AppHandle, paths: Vec<String>, title: String, bitrate: u32) -> Result<db::Entry, String> {
    tauri::async_runtime::spawn_blocking(move || audio::merge(&app, paths, title, bitrate))
        .await
        .map_err(|e| e.to_string())?
}

// ---------- audio processing ----------

#[tauri::command]
async fn get_waveform(app: AppHandle, path: String, points: usize) -> Result<Vec<f32>, String> {
    tauri::async_runtime::spawn_blocking(move || audio::waveform(&app, &path, points))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn get_silences(
    app: AppHandle,
    path: String,
    noise_db: f64,
    min_dur: f64,
) -> Result<Vec<audio::SilenceRange>, String> {
    tauri::async_runtime::spawn_blocking(move || audio::silences(&app, &path, noise_db, min_dur))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn probe_file(app: AppHandle, path: String) -> Result<audio::ProbeInfo, String> {
    tauri::async_runtime::spawn_blocking(move || audio::probe(&app, &path))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn export_mp3(app: AppHandle, opts: audio::ExportOpts) -> Result<db::Entry, String> {
    tauri::async_runtime::spawn_blocking(move || audio::export_mp3(&app, opts))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn split_export(app: AppHandle, opts: audio::SplitOpts) -> Result<Vec<db::Entry>, String> {
    tauri::async_runtime::spawn_blocking(move || audio::split_export(&app, opts))
        .await
        .map_err(|e| e.to_string())?
}

// ---------- youtube ----------

#[tauri::command]
fn yt_queue(app: AppHandle, url: String, opts: youtube::YtOpts) -> Result<u64, String> {
    youtube::queue(app, url, opts)
}

#[tauri::command]
fn yt_cancel(app: AppHandle, id: u64) -> Result<(), String> {
    youtube::cancel(&app, id)
}

// ---------- hotkeys ----------

#[derive(Serialize, Clone)]
struct HotkeyEvent {
    action: String,
}

fn register_hotkeys(app: &AppHandle) {
    use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

    let toggle = Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyR);
    let pause = Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyP);

    let result = app.plugin(
        tauri_plugin_global_shortcut::Builder::new()
            .with_handler(move |app, shortcut, event| {
                if event.state() != ShortcutState::Pressed {
                    return;
                }
                let action = if *shortcut == toggle {
                    "toggle"
                } else if *shortcut == pause {
                    "pause"
                } else {
                    return;
                };
                let _ = app.emit("hotkey", HotkeyEvent { action: action.into() });
            })
            .build(),
    );
    if result.is_ok() {
        let gs = app.global_shortcut();
        if let Err(e) = gs.register(toggle) {
            eprintln!("hotkey Ctrl+Alt+R unavailable: {e}");
        }
        if let Err(e) = gs.register(pause) {
            eprintln!("hotkey Ctrl+Alt+P unavailable: {e}");
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(recorder::RecState::default())
        .manage(youtube::YtState::default())
        .setup(|app| {
            db::open(&app.handle())?;
            register_hotkeys(app.handle());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            tools_status,
            tools_install,
            list_mics,
            rec_start,
            rec_pause,
            rec_resume,
            rec_stop,
            rec_active,
            lib_list,
            lib_update,
            lib_delete,
            lib_folders,
            lib_import,
            lib_merge,
            get_waveform,
            get_silences,
            probe_file,
            export_mp3,
            split_export,
            yt_queue,
            yt_cancel
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
