import SwiftUI
import AppKit

struct YouTubeView: View {
    @Environment(AppModel.self) private var model

    @State private var url = ""
    @State private var bitrate = Bitrate.b192
    @State private var embedThumbnail = true
    @State private var playlist = YouTubeService.PlaylistMode.single
    @State private var playlistN = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("YouTube → MP3") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            TextField("Paste a YouTube URL (video or playlist)…", text: $url)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(submit)
                            Button("Download", action: submit)
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.tools.hasYtDlp || url.isEmpty)
                        }
                        HStack(spacing: 20) {
                            Picker("Bitrate", selection: $bitrate) {
                                ForEach(Bitrate.allCases) { Text($0.label).tag($0) }
                            }.frame(width: 170)
                            Picker("Playlist", selection: $playlist) {
                                ForEach(YouTubeService.PlaylistMode.allCases) { Text($0.label).tag($0) }
                            }.frame(width: 220)
                            if playlist == .firstN {
                                Stepper("First \(playlistN)", value: $playlistN, in: 1...999)
                                    .frame(width: 120)
                            }
                            Toggle("Cover art", isOn: $embedThumbnail)
                        }
                        if !model.tools.hasYtDlp {
                            Label("yt-dlp and ffmpeg are required. Install them in Settings, or with Homebrew: brew install yt-dlp ffmpeg",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Queue") {
                    if model.youtube.jobs.isEmpty {
                        Text("Nothing queued yet. Downloads are saved to your library.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(model.youtube.jobs) { job in
                                jobRow(job)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("YouTube")
    }

    private func jobRow(_ job: YouTubeService.Job) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.url).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(job.status)
                    .font(.caption.bold())
                    .foregroundStyle(job.failed ? .red : (job.finished ? .green : .primary))
            }
            ProgressView(value: min(1, job.pct / 100))
                .tint(job.failed ? .red : (job.finished ? .green : .accentColor))
            if !job.detail.isEmpty {
                Text(job.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func submit() {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let ytdlp = model.tools.ytdlpURL else { return }
        guard trimmed.lowercased().hasPrefix("http") else {
            model.notify("That doesn't look like a URL", isError: true)
            return
        }
        if playlist == .all {
            let alert = NSAlert()
            alert.messageText = "Download the entire playlist?"
            alert.informativeText = "This can be a lot of files."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.youtube.enqueue(
            url: trimmed, ytdlp: ytdlp,
            ffmpegDir: model.tools.ffmpegURL?.deletingLastPathComponent(),
            bitrate: bitrate.rawValue, embedThumbnail: embedThumbnail,
            playlist: playlist, playlistN: playlistN)
        url = ""
    }
}
