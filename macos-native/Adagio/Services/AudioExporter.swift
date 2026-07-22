import Foundation
import AVFoundation

/// Export, split, and merge. The default output is .m4a (AAC) via AVFoundation,
/// which needs no external tools. If ffmpeg is available and the user wants MP3,
/// the ffmpeg path is used and unlocks loudness-normalize / fade / denoise.
struct AudioExporter {
    let ffmpeg: URL?

    struct Output {
        let url: URL
        let title: String
        let durationMs: Int
        let sizeBytes: Int
        let kind: RecordingKind
        let folder: String
    }

    struct ExportRequest {
        var source: URL
        var baseName: String
        var title: String = ""
        var artist: String = ""
        var album: String = ""
        var bitrate: Int = 192
        var normalize = false
        var denoise = false
        var fadeIn: Double = 0
        var fadeOut: Double = 0
        var asMP3 = false
    }

    // MARK: - Single export (with metadata / optional post-processing)

    func export(_ req: ExportRequest) async throws -> Output {
        let title = req.title.isEmpty ? req.source.deletingPathExtension().lastPathComponent : req.title
        if req.asMP3 {
            guard let ffmpeg else {
                throw AdagioError.message("MP3 export needs ffmpeg. Install it (Settings ▸ Tools) or export to .m4a instead.")
            }
            let out = Storage.uniqueURL(baseName: req.baseName, ext: "mp3")
            try await ffmpegExport(ffmpeg, req: req, out: out)
            return output(out, title: title, kind: .export, folder: "")
        } else {
            let out = Storage.uniqueURL(baseName: req.baseName, ext: "m4a")
            let meta = metadataItems(title: title, artist: req.artist, album: req.album)
            try await exportM4A(source: req.source, out: out, timeRange: nil, metadata: meta)
            return output(out, title: title, kind: .export, folder: "")
        }
    }

    private func ffmpegExport(_ ffmpeg: URL, req: ExportRequest, out: URL) async throws {
        var filters: [String] = []
        if req.denoise { filters.append("afftdn=nf=-25") }
        if req.normalize { filters.append("loudnorm=I=-16:TP=-1.5:LRA=11") }
        if req.fadeIn > 0 { filters.append("afade=t=in:st=0:d=\(req.fadeIn)") }
        if req.fadeOut > 0 {
            let dur = Double(Probe.durationMs(req.source)) / 1000.0
            let st = max(0, dur - req.fadeOut)
            filters.append("afade=t=out:st=\(st):d=\(req.fadeOut)")
        }
        var args = ["-y", "-i", req.source.path, "-map", "0:a"]
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }
        args += ["-c:a", "libmp3lame", "-b:a", "\(req.bitrate)k", "-id3v2_version", "3"]
        if !req.title.isEmpty { args += ["-metadata", "title=\(req.title)"] }
        if !req.artist.isEmpty { args += ["-metadata", "artist=\(req.artist)"] }
        if !req.album.isEmpty { args += ["-metadata", "album=\(req.album)"] }
        args.append(out.path)
        let result = try await Shell.run(ffmpeg, args)
        guard result.ok else { throw AdagioError.message("ffmpeg export failed: \(result.stderr.suffix(300))") }
    }

    // MARK: - Split

    func splitExport(
        source: URL,
        cuts: [Double],
        baseName: String,
        folder: String,
        asMP3: Bool,
        bitrate: Int,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> [Output] {
        let duration = Double(Probe.durationMs(source)) / 1000.0
        var bounds = [0.0]
        bounds += cuts.filter { $0 > 0.05 && $0 < duration - 0.05 }.sorted()
        bounds.append(duration)

        let total = bounds.count - 1
        var outputs: [Output] = []
        for i in 0..<total {
            let a = bounds[i]
            let b = bounds[i + 1]
            let name = String(format: "%@_%02d", baseName, i + 1)
            let ext = asMP3 ? "mp3" : "m4a"
            let out = Storage.uniqueURL(baseName: name, ext: ext)

            if asMP3, let ffmpeg {
                let args = ["-y", "-ss", String(format: "%.3f", a), "-to", String(format: "%.3f", b),
                            "-i", source.path, "-vn", "-c:a", "libmp3lame", "-b:a", "\(bitrate)k",
                            "-metadata", "title=\(name)", "-metadata", "track=\(i + 1)",
                            "-id3v2_version", "3", out.path]
                let r = try await Shell.run(ffmpeg, args)
                guard r.ok else { throw AdagioError.message("ffmpeg split failed on segment \(i + 1).") }
            } else {
                let range = CMTimeRange(
                    start: CMTime(seconds: a, preferredTimescale: 44_100),
                    end: CMTime(seconds: b, preferredTimescale: 44_100))
                let meta = metadataItems(title: name, artist: "", album: "")
                try await exportM4A(source: source, out: out, timeRange: range, metadata: meta)
            }
            outputs.append(output(out, title: name, kind: .segment, folder: folder))
            progress(i + 1, total)
        }
        return outputs
    }

    // MARK: - Merge

    func merge(sources: [URL], title: String, asMP3: Bool, bitrate: Int) async throws -> Output {
        guard sources.count >= 2 else { throw AdagioError.message("Select at least two items to merge.") }

        if asMP3, let ffmpeg {
            let out = Storage.uniqueURL(baseName: title, ext: "mp3")
            var args = ["-y"]
            for s in sources { args += ["-i", s.path] }
            let inputs = (0..<sources.count).map { "[\($0):a]" }.joined()
            args += ["-filter_complex", "\(inputs)concat=n=\(sources.count):v=0:a=1[a]",
                     "-map", "[a]", "-c:a", "libmp3lame", "-b:a", "\(bitrate)k", out.path]
            let r = try await Shell.run(ffmpeg, args)
            guard r.ok else { throw AdagioError.message("ffmpeg merge failed.") }
            return output(out, title: title, kind: .merge, folder: "")
        }

        // Native concat via composition.
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AdagioError.message("Could not create merge composition.")
        }
        var cursor = CMTime.zero
        for url in sources {
            let asset = AVURLAsset(url: url)
            guard let src = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let dur = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: cursor)
            cursor = cursor + dur
        }
        let out = Storage.uniqueURL(baseName: title, ext: "m4a")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AdagioError.message("Could not create export session.")
        }
        session.outputURL = out
        session.outputFileType = .m4a
        session.metadata = metadataItems(title: title, artist: "", album: "")
        try await runSession(session)
        return output(out, title: title, kind: .merge, folder: "")
    }

    // MARK: - Helpers

    private func exportM4A(source: URL, out: URL, timeRange: CMTimeRange?, metadata: [AVMetadataItem]) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AdagioError.message("Could not create export session for \(source.lastPathComponent).")
        }
        session.outputURL = out
        session.outputFileType = .m4a
        session.metadata = metadata
        if let timeRange { session.timeRange = timeRange }
        try await runSession(session)
    }

    private func runSession(_ session: AVAssetExportSession) async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else {
            throw session.error ?? AdagioError.message("Export did not complete.")
        }
    }

    private func metadataItems(title: String, artist: String, album: String) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func item(_ key: AVMetadataIdentifier, _ value: String) -> AVMetadataItem? {
            guard !value.isEmpty else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = key
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        if let t = item(.commonIdentifierTitle, title) { items.append(t) }
        if let a = item(.commonIdentifierArtist, artist) { items.append(a) }
        if let al = item(.commonIdentifierAlbumName, album) { items.append(al) }
        return items
    }

    private func output(_ url: URL, title: String, kind: RecordingKind, folder: String) -> Output {
        Output(url: url, title: title, durationMs: Probe.durationMs(url),
               sizeBytes: Storage.fileSize(url), kind: kind, folder: folder)
    }
}
