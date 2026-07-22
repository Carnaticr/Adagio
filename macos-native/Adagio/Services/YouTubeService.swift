import Foundation

@MainActor
@Observable
final class YouTubeService {
    struct Job: Identifiable {
        let id = UUID()
        var url: String
        var status: String = "queued"
        var pct: Double = 0
        var detail: String = ""
        var finished = false
        var failed = false
    }

    enum PlaylistMode: String, CaseIterable, Identifiable {
        case single, firstN = "first_n", all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .single: return "Single video"
            case .firstN: return "First N of playlist"
            case .all: return "Whole playlist"
            }
        }
    }

    private(set) var jobs: [Job] = []
    private var running = false

    /// Called with new library outputs when a download completes.
    var onDownloaded: (([AudioExporter.Output]) -> Void)?

    func enqueue(url: String, ytdlp: URL, ffmpegDir: URL?, bitrate: Int,
                 embedThumbnail: Bool, playlist: PlaylistMode, playlistN: Int) {
        jobs.insert(Job(url: url), at: 0)
        Task { await runLoop(ytdlp: ytdlp, ffmpegDir: ffmpegDir, bitrate: bitrate,
                             embedThumbnail: embedThumbnail, playlist: playlist, playlistN: playlistN) }
    }

    private func runLoop(ytdlp: URL, ffmpegDir: URL?, bitrate: Int,
                         embedThumbnail: Bool, playlist: PlaylistMode, playlistN: Int) async {
        if running { return }
        running = true
        defer { running = false }

        while let idx = jobs.firstIndex(where: { !$0.finished && !$0.failed && $0.status == "queued" }) {
            let jobID = jobs[idx].id
            update(jobID) { $0.status = "running"; $0.detail = "Starting…" }

            let url = jobs[idx].url
            var args = ["-x", "--audio-format", "mp3", "--audio-quality", "\(bitrate)K",
                        "--embed-metadata", "--newline",
                        "--progress-template", "PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
                        "--print", "after_move:filepath", "--no-simulate"]
            if let ffmpegDir { args += ["--ffmpeg-location", ffmpegDir.path] }
            if embedThumbnail { args.append("--embed-thumbnail") }
            switch playlist {
            case .single: args.append("--no-playlist")
            case .firstN: args += ["--yes-playlist", "--playlist-items", "1:\(max(1, playlistN))"]
            case .all: args.append("--yes-playlist")
            }
            args += ["-P", Storage.recordingsDir.path, "-o", "%(title)s.%(ext)s", url]

            var files: [String] = []
            let code: Int32
            do {
                code = try await Shell.stream(ytdlp, args) { line in
                    if line.hasPrefix("PROG|") {
                        let parts = line.dropFirst(5).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                        let pct = Double(parts.first?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "") ?? "") ?? 0
                        let speed = parts.count > 1 ? parts[1] : ""
                        let eta = parts.count > 2 ? parts[2] : ""
                        Task { @MainActor in
                            self.update(jobID) {
                                $0.pct = pct
                                $0.detail = "\(String(format: "%.1f", pct))%  \(speed)  ETA \(eta)"
                            }
                        }
                    } else if FileManager.default.fileExists(atPath: line) {
                        files.append(line)
                    }
                }
            } catch {
                update(jobID) { $0.failed = true; $0.status = "error"; $0.detail = error.localizedDescription }
                continue
            }

            if code != 0 && files.isEmpty {
                update(jobID) { $0.failed = true; $0.status = "error"; $0.detail = "yt-dlp exited with code \(code)" }
                continue
            }

            let outputs = files.map { path -> AudioExporter.Output in
                let url = URL(fileURLWithPath: path)
                return AudioExporter.Output(
                    url: url,
                    title: url.deletingPathExtension().lastPathComponent,
                    durationMs: Probe.durationMs(url),
                    sizeBytes: Storage.fileSize(url),
                    kind: .youtube, folder: "")
            }
            onDownloaded?(outputs)
            update(jobID) { $0.finished = true; $0.status = "done"; $0.pct = 100; $0.detail = "\(files.count) file(s) saved" }
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[idx])
    }
}
