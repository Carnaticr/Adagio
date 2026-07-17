use rusqlite::Connection;
use serde::Serialize;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub path: String,
    pub kind: String,
    pub folder: String,
    pub tags: String,
    pub duration_ms: i64,
    pub size_bytes: i64,
    pub created_at: String,
}

fn db_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join("adagio.db"))
}

pub fn open(app: &AppHandle) -> Result<Connection, String> {
    let conn = Connection::open(db_path(app)?).map_err(|e| e.to_string())?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS recordings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            artist TEXT NOT NULL DEFAULT '',
            album TEXT NOT NULL DEFAULT '',
            path TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'recording',
            folder TEXT NOT NULL DEFAULT '',
            tags TEXT NOT NULL DEFAULT '',
            duration_ms INTEGER NOT NULL DEFAULT 0,
            size_bytes INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        );",
    )
    .map_err(|e| e.to_string())?;
    Ok(conn)
}

fn row_to_entry(row: &rusqlite::Row) -> rusqlite::Result<Entry> {
    Ok(Entry {
        id: row.get(0)?,
        title: row.get(1)?,
        artist: row.get(2)?,
        album: row.get(3)?,
        path: row.get(4)?,
        kind: row.get(5)?,
        folder: row.get(6)?,
        tags: row.get(7)?,
        duration_ms: row.get(8)?,
        size_bytes: row.get(9)?,
        created_at: row.get(10)?,
    })
}

const COLS: &str = "id, title, artist, album, path, kind, folder, tags, duration_ms, size_bytes, created_at";

pub fn insert(
    app: &AppHandle,
    title: &str,
    artist: &str,
    album: &str,
    path: &str,
    kind: &str,
    folder: &str,
    duration_ms: i64,
    size_bytes: i64,
) -> Result<Entry, String> {
    let conn = open(app)?;
    let created = chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
    conn.execute(
        "INSERT INTO recordings (title, artist, album, path, kind, folder, tags, duration_ms, size_bytes, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, '', ?7, ?8, ?9)",
        rusqlite::params![title, artist, album, path, kind, folder, duration_ms, size_bytes, created],
    )
    .map_err(|e| e.to_string())?;
    let id = conn.last_insert_rowid();
    get(app, id)
}

pub fn get(app: &AppHandle, id: i64) -> Result<Entry, String> {
    let conn = open(app)?;
    conn.query_row(
        &format!("SELECT {COLS} FROM recordings WHERE id = ?1"),
        [id],
        row_to_entry,
    )
    .map_err(|e| e.to_string())
}

pub fn list(app: &AppHandle, query: &str, folder: &str) -> Result<Vec<Entry>, String> {
    let conn = open(app)?;
    let like = format!("%{}%", query);
    let folder_like = if folder.is_empty() { "%".to_string() } else { folder.to_string() };
    let mut stmt = conn
        .prepare(&format!(
            "SELECT {COLS} FROM recordings
             WHERE (title LIKE ?1 OR artist LIKE ?1 OR album LIKE ?1 OR tags LIKE ?1)
               AND folder LIKE ?2
             ORDER BY created_at DESC, id DESC"
        ))
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(rusqlite::params![like, folder_like], row_to_entry)
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}

pub fn update(
    app: &AppHandle,
    id: i64,
    title: &str,
    artist: &str,
    album: &str,
    tags: &str,
    folder: &str,
) -> Result<Entry, String> {
    let conn = open(app)?;
    conn.execute(
        "UPDATE recordings SET title=?1, artist=?2, album=?3, tags=?4, folder=?5 WHERE id=?6",
        rusqlite::params![title, artist, album, tags, folder, id],
    )
    .map_err(|e| e.to_string())?;
    get(app, id)
}

pub fn delete(app: &AppHandle, ids: &[i64], delete_files: bool) -> Result<(), String> {
    let conn = open(app)?;
    for id in ids {
        if delete_files {
            if let Ok(entry) = get(app, *id) {
                let _ = std::fs::remove_file(&entry.path);
            }
        }
        conn.execute("DELETE FROM recordings WHERE id=?1", [id])
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn folders(app: &AppHandle) -> Result<Vec<String>, String> {
    let conn = open(app)?;
    let mut stmt = conn
        .prepare("SELECT DISTINCT folder FROM recordings WHERE folder != '' ORDER BY folder")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}
