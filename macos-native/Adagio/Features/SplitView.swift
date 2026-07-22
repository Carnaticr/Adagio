import SwiftUI

struct SplitView: View {
    @Environment(AppModel.self) private var model

    @State private var peaks: [Float] = []
    @State private var silences: [SilenceDetector.Range] = []
    @State private var cuts: [Double] = []
    @State private var duration: Double = 0
    @State private var thresholdDb = -30.0
    @State private var minSilence = 1.5
    @State private var minSegment = 5.0
    @State private var baseName = ""
    @State private var asMP3 = false
    @State private var bitrate = Bitrate.b192
    @State private var status = ""
    @State private var loadedID: Recording.ID?
    @State private var busy = false

    var body: some View {
        Group {
            if let target = model.splitTarget {
                editor(target)
            } else {
                ContentUnavailableView(
                    "No recording selected",
                    systemImage: "scissors",
                    description: Text("Open the Library and choose “Split by Silence” on any item."))
            }
        }
        .navigationTitle("Split")
        .onChange(of: model.splitTarget?.id) { _, _ in loadIfNeeded() }
        .onAppear { loadIfNeeded() }
    }

    private func editor(_ target: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Smart split by silence") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(target.title) · \(Format.time(target.durationMs))").font(.headline)
                        HStack(spacing: 16) {
                            labeled("Silence threshold (dB)") {
                                TextField("", value: $thresholdDb, format: .number).frame(width: 70)
                            }
                            labeled("Min silence (s)") {
                                TextField("", value: $minSilence, format: .number).frame(width: 70)
                            }
                            labeled("Min segment (s)") {
                                TextField("", value: $minSegment, format: .number).frame(width: 70)
                            }
                            Spacer()
                            Button("Detect silences") { Task { await detect(target) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy)
                        }
                    }
                    .padding(8)
                }

                SplitWaveform(
                    peaks: peaks, silences: silences, cuts: cuts, duration: duration,
                    playhead: model.player.currentURL == target.url ? model.player.currentTime : -1,
                    onAddCut: { cuts.append($0); cuts.sort() },
                    onMoveCut: { idx, sec in if cuts.indices.contains(idx) { cuts[idx] = sec } },
                    onRemoveCut: { idx in if cuts.indices.contains(idx) { cuts.remove(at: idx) } })
                    .frame(height: 200)
                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))

                Text("Click to add a cut · click a marker to remove it · drag a marker to fine-tune · shaded areas are detected silence")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    labeled("Base name") {
                        TextField("", text: $baseName).frame(width: 220)
                    }
                    Picker("Format", selection: $asMP3) {
                        Text("M4A").tag(false)
                        Text(model.tools.hasFFmpeg ? "MP3" : "MP3 (needs ffmpeg)").tag(true)
                    }
                    .frame(width: 180)
                    if asMP3 {
                        Picker("", selection: $bitrate) {
                            ForEach(Bitrate.allCases) { Text($0.label).tag($0) }
                        }.frame(width: 110).labelsHidden()
                    }
                    Spacer()
                    Button("Split & Export") { Task { await doExport(target) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || (asMP3 && !model.tools.hasFFmpeg))
                }

                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }

                segmentList
            }
            .padding(20)
        }
    }

    private var segmentList: some View {
        let bounds = [0.0] + cuts.sorted() + [duration]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<max(0, bounds.count - 1), id: \.self) { i in
                let a = bounds[i], b = bounds[i + 1]
                HStack {
                    Button {
                        if let t = model.splitTarget { model.play(t, from: a) }
                    } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless)
                    Text("\(Format.time(Int(a * 1000))) → \(Format.time(Int(b * 1000)))")
                        .monospacedDigit()
                    Text("(\(Format.time(Int((b - a) * 1000))))")
                        .foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(String(format: "%@_%02d.%@", baseName, i + 1, asMP3 ? "mp3" : "m4a"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func labeled<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Logic

    private func loadIfNeeded() {
        guard let target = model.splitTarget, target.id != loadedID else { return }
        loadedID = target.id
        cuts = []
        silences = []
        peaks = []
        baseName = target.title
        duration = Double(target.durationMs) / 1000.0
        status = "Loading waveform…"
        let url = target.url
        Task.detached {
            let p = (try? AudioMixer.peaks(url, points: 1600)) ?? []
            await MainActor.run {
                self.peaks = p
                self.status = ""
            }
        }
    }

    private func detect(_ target: Recording) async {
        busy = true
        defer { busy = false }
        status = "Detecting silences…"
        let url = target.url
        let db = thresholdDb, ms = minSilence, seg = minSegment, dur = duration
        let result: (silences: [SilenceDetector.Range], cuts: [Double]) = await Task.detached {
            let s = (try? SilenceDetector.detect(url: url, thresholdDb: db, minSilence: ms)) ?? []
            let c = SilenceDetector.proposeCuts(from: s, duration: dur, minSegment: seg)
            return (s, c)
        }.value
        silences = result.silences
        cuts = result.cuts
        status = ""
        if cuts.isEmpty {
            model.notify("No suitable pauses found — try a higher threshold (e.g. -25) or shorter min silence", isError: false)
        } else {
            model.notify("\(cuts.count) cut(s) proposed → \(cuts.count + 1) segments", isError: false)
        }
    }

    private func doExport(_ target: Recording) async {
        busy = true
        defer { busy = false }
        status = "Exporting…"
        do {
            let outputs = try await model.exporter.splitExport(
                source: target.url, cuts: cuts,
                baseName: baseName.isEmpty ? target.title : baseName,
                folder: target.folder, asMP3: asMP3, bitrate: bitrate.rawValue,
                progress: { i, total in Task { @MainActor in status = "Exporting \(i)/\(total)…" } })
            for o in outputs { model.insert(o) }
            status = ""
            model.notify("Exported \(outputs.count) segment(s)", isError: false)
        } catch {
            status = ""
            model.notify(error.localizedDescription, isError: true)
        }
    }
}
