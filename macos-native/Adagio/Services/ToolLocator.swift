import Foundation

/// Locates external helper tools (ffmpeg, ffprobe, yt-dlp).
///
/// Fix for "tools not located": a macOS GUI app launched from Finder inherits a
/// minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) that excludes Homebrew, so the
/// Tauri build's PATH lookup found nothing. Here we (1) check a user-configured
/// path, (2) check our own downloaded copies, then (3) probe the well-known
/// install locations explicitly instead of trusting PATH. The core app never
/// needs these — only MP3 export and YouTube do.
@Observable
final class ToolLocator {
    enum Tool: String {
        case ffmpeg
        case ffprobe
        case ytdlp = "yt-dlp"
    }

    /// User-picked directory that contains the tools (set from Settings). Persisted.
    var customBinDir: String {
        didSet { UserDefaults.standard.set(customBinDir, forKey: "customBinDir"); refresh() }
    }

    private(set) var ffmpegURL: URL?
    private(set) var ffprobeURL: URL?
    private(set) var ytdlpURL: URL?

    var hasFFmpeg: Bool { ffmpegURL != nil && ffprobeURL != nil }
    var hasYtDlp: Bool { ytdlpURL != nil }

    private static let searchDirs = [
        "/opt/homebrew/bin",   // Apple Silicon Homebrew
        "/usr/local/bin",      // Intel Homebrew
        "/opt/local/bin",      // MacPorts
        "/usr/bin",
        "/bin",
    ]

    init() {
        customBinDir = UserDefaults.standard.string(forKey: "customBinDir") ?? ""
        refresh()
    }

    func refresh() {
        ffmpegURL = locate(.ffmpeg)
        ffprobeURL = locate(.ffprobe)
        ytdlpURL = locate(.ytdlp)
    }

    private func locate(_ tool: Tool) -> URL? {
        let name = tool.rawValue

        // 1. User-configured directory.
        if !customBinDir.isEmpty {
            let u = URL(fileURLWithPath: customBinDir).appendingPathComponent(name)
            if isExecutable(u) { return u }
        }
        // 2. Our own downloaded copy.
        let downloaded = Storage.binDir.appendingPathComponent(name)
        if isExecutable(downloaded) { return downloaded }

        // 3. Well-known install locations (not PATH, which Finder-launched apps lack).
        for dir in Self.searchDirs {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if isExecutable(u) { return u }
        }
        // 4. Last resort: honor PATH if the app happened to inherit one.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let u = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
                if isExecutable(u) { return u }
            }
        }
        return nil
    }

    private func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}
