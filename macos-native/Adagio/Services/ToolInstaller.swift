import Foundation

/// Optional convenience: download yt-dlp + a static ffmpeg build into the app's
/// bin dir. Users who have Homebrew ffmpeg/yt-dlp don't need this — ToolLocator
/// already finds those. This is only for people with neither.
@MainActor
@Observable
final class ToolInstaller {
    private(set) var installing = false
    private(set) var status = ""
    private(set) var progress = 0.0

    private let ytdlpURL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    // evermeet.cx serves static ffmpeg/ffprobe zips for macOS.
    private let ffmpegZip = "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
    private let ffprobeZip = "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"

    func install(locator: ToolLocator) async {
        guard !installing else { return }
        installing = true
        status = "Starting…"
        progress = 0
        defer { installing = false }

        do {
            let bin = Storage.binDir
            if !locator.hasYtDlp {
                status = "Downloading yt-dlp…"
                let dest = bin.appendingPathComponent("yt-dlp")
                try await download(ytdlpURL, to: dest)
                try makeExecutable(dest)
            }
            if !locator.hasFFmpeg {
                status = "Downloading ffmpeg…"
                try await downloadAndUnzip(ffmpegZip, exeName: "ffmpeg", into: bin)
                status = "Downloading ffprobe…"
                try await downloadAndUnzip(ffprobeZip, exeName: "ffprobe", into: bin)
            }
            status = "Done"
            progress = 1
            locator.refresh()
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func download(_ urlString: String, to dest: URL) async throws {
        guard let url = URL(string: urlString) else { throw AdagioError.message("Bad URL") }
        let (tmp, _) = try await URLSession.shared.download(from: url)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    private func downloadAndUnzip(_ urlString: String, exeName: String, into bin: URL) async throws {
        guard let url = URL(string: urlString) else { throw AdagioError.message("Bad URL") }
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let zipPath = bin.appendingPathComponent("\(exeName).zip")
        if FileManager.default.fileExists(atPath: zipPath.path) { try FileManager.default.removeItem(at: zipPath) }
        try FileManager.default.moveItem(at: tmp, to: zipPath)

        // Use the system unzip via ditto (always present on macOS).
        let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
        let result = try await Shell.run(ditto, ["-x", "-k", zipPath.path, bin.path])
        try? FileManager.default.removeItem(at: zipPath)
        guard result.ok else { throw AdagioError.message("Unzip failed for \(exeName).") }

        let dest = bin.appendingPathComponent(exeName)
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw AdagioError.message("\(exeName) not found in archive.")
        }
        try makeExecutable(dest)
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
