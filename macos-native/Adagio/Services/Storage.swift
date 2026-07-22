import Foundation

/// Central place for all on-disk locations.
///
/// Fix for "unable to save recordings": everything defaults to the app's own
/// Application Support container, which is ALWAYS writable — even under the
/// hardened runtime and even if the user never grants access to ~/Music. The
/// Tauri build tried to write into ~/Music, which macOS blocks without an
/// explicit entitlement/consent, so recordings silently failed to save.
enum Storage {
    static let bundleID = "com.adagio.recorder"

    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        ensure(dir)
        return dir
    }

    /// Where new recordings, downloads, exports and segments are written.
    static var recordingsDir: URL {
        let dir = appSupportDir.appendingPathComponent("Recordings", isDirectory: true)
        ensure(dir)
        return dir
    }

    /// Where auto-downloaded ffmpeg / yt-dlp binaries live.
    static var binDir: URL {
        let dir = appSupportDir.appendingPathComponent("bin", isDirectory: true)
        ensure(dir)
        return dir
    }

    private static func ensure(_ dir: URL) {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Produce a unique URL inside `recordingsDir` for the given base name + extension,
    /// appending " (2)", " (3)"… on collision. Sanitizes path-hostile characters.
    static func uniqueURL(baseName: String, ext: String) -> URL {
        let sanitized = baseName.map { "/\\:*?\"<>|".contains($0) ? "_" : $0 }.reduce(into: "") { $0.append($1) }
        let trimmed = sanitized.isEmpty ? "Recording" : sanitized
        var candidate = recordingsDir.appendingPathComponent("\(trimmed).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = recordingsDir.appendingPathComponent("\(trimmed) (\(i)).\(ext)")
            i += 1
        }
        return candidate
    }

    /// A timestamped base name like `Recording_2026-07-17_14-30-05`.
    static func timestampName(prefix: String = "Recording") -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(prefix)_\(f.string(from: Date()))"
    }

    static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    /// Store a path relative to recordingsDir when the file lives there; otherwise absolute.
    static func storedPath(for url: URL) -> String {
        let recPath = recordingsDir.path
        if url.path.hasPrefix(recPath + "/") {
            return String(url.path.dropFirst(recPath.count + 1))
        }
        return url.path
    }
}
