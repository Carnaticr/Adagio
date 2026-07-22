import Foundation
import SwiftUI
import SwiftData

enum Tab: String, CaseIterable, Identifiable {
    case record, youtube, library, split
    var id: String { rawValue }
    var title: String {
        switch self {
        case .record: return "Record"
        case .youtube: return "YouTube"
        case .library: return "Library"
        case .split: return "Split"
        }
    }
    var symbol: String {
        switch self {
        case .record: return "record.circle"
        case .youtube: return "arrow.down.circle"
        case .library: return "music.note.list"
        case .split: return "scissors"
        }
    }
}

/// App-wide shared state. One instance, injected into every scene.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let recorder = AudioRecorder()
    let player = AudioPlayer()
    let tools = ToolLocator()
    let installer = ToolInstaller()
    let youtube = YouTubeService()

    var selectedTab: Tab = .record
    var recordMode: RecordMode = .mic
    /// The item currently loaded into the Split editor.
    var splitTarget: Recording?

    struct Banner: Identifiable { let id = UUID(); let text: String; let isError: Bool }
    var banner: Banner?

    var exporter: AudioExporter {
        AudioExporter(ffmpeg: tools.ffmpegURL)
    }

    var context: ModelContext { container.mainContext }

    init() {
        let schema = Schema([Recording.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create the library database: \(error)")
        }
        youtube.onDownloaded = { [weak self] outputs in
            guard let self else { return }
            for o in outputs { self.insert(o) }
            self.notify("\(outputs.count) download(s) added to your library", isError: false)
        }
    }

    // MARK: - Library inserts

    @discardableResult
    func insert(
        title: String, artist: String = "", album: String = "", tags: String = "",
        folder: String = "", url: URL, kind: RecordingKind, durationMs: Int, sizeBytes: Int
    ) -> Recording {
        let rec = Recording(
            title: title, artist: artist, album: album, tags: tags, folder: folder,
            relativePath: Storage.storedPath(for: url), kind: kind,
            durationMs: durationMs, sizeBytes: sizeBytes)
        context.insert(rec)
        try? context.save()
        return rec
    }

    @discardableResult
    func insert(_ o: AudioExporter.Output) -> Recording {
        insert(title: o.title, folder: o.folder, url: o.url,
               kind: o.kind, durationMs: o.durationMs, sizeBytes: o.sizeBytes)
    }

    func delete(_ recordings: [Recording], removeFiles: Bool) {
        for rec in recordings {
            if removeFiles { try? FileManager.default.removeItem(at: rec.url) }
            context.delete(rec)
        }
        try? context.save()
    }

    // MARK: - UI helpers

    func notify(_ text: String, isError: Bool) {
        banner = Banner(text: text, isError: isError)
        let shown = banner?.id
        Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 3.5))
            if self.banner?.id == shown { self.banner = nil }
        }
    }

    func openInSplit(_ rec: Recording) {
        splitTarget = rec
        selectedTab = .split
    }

    /// Play a library item in the shared player.
    func play(_ rec: Recording, from time: Double = 0) {
        guard rec.fileExists else {
            notify("File is missing on disk", isError: true)
            return
        }
        player.play(url: rec.url, title: rec.title)
        if time > 0 { player.seek(toTime: time) }
    }

    // MARK: - Recording orchestration (shared by the Record view and the menu)

    func startRecording() async {
        guard recorder.phase == .idle else { return }
        do {
            try await recorder.start(mode: recordMode)
        } catch {
            notify(error.localizedDescription, isError: true)
        }
    }

    func stopRecording(cancel: Bool) async {
        guard recorder.isActive else { return }
        do {
            if let result = try await recorder.stop(cancel: cancel) {
                insert(title: result.baseName, url: result.url, kind: result.kind,
                       durationMs: result.durationMs, sizeBytes: result.sizeBytes)
                notify("Saved: \(result.baseName)", isError: false)
            } else if cancel {
                notify("Recording discarded", isError: false)
            }
        } catch {
            notify(error.localizedDescription, isError: true)
        }
    }

    func togglePauseResume() {
        switch recorder.phase {
        case .recording: recorder.pause()
        case .paused: recorder.resume()
        case .idle: break
        }
    }

    func menuToggleRecord() {
        Task {
            if recorder.isActive { await stopRecording(cancel: false) }
            else { await startRecording() }
        }
    }
}
