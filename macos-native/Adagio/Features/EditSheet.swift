import SwiftUI

struct EditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Metadata").font(.title3.bold())
            Form {
                TextField("Title", text: $recording.title)
                TextField("Artist", text: $recording.artist)
                TextField("Album", text: $recording.album)
                TextField("Tags", text: $recording.tags, prompt: Text("comma, separated"))
                TextField("Folder / project", text: $recording.folder)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    try? model.context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let recording: Recording

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var asMP3 = false
    @State private var bitrate = Bitrate.b192
    @State private var normalize = false
    @State private var denoise = false
    @State private var fadeIn = 0.0
    @State private var fadeOut = 0.0
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.title3.bold())
            Form {
                TextField("Title", text: $title)
                TextField("Artist", text: $artist)
                TextField("Album", text: $album)

                Picker("Format", selection: $asMP3) {
                    Text("M4A / AAC (no tools needed)").tag(false)
                    Text(model.tools.hasFFmpeg ? "MP3 (ffmpeg)" : "MP3 (needs ffmpeg)").tag(true)
                }

                if asMP3 {
                    Picker("Bitrate", selection: $bitrate) {
                        ForEach(Bitrate.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Normalize loudness", isOn: $normalize)
                    Toggle("Reduce noise", isOn: $denoise)
                    HStack {
                        Text("Fade in"); TextField("", value: $fadeIn, format: .number).frame(width: 60)
                        Text("Fade out"); TextField("", value: $fadeOut, format: .number).frame(width: 60)
                        Text("sec").foregroundStyle(.secondary)
                    }
                    if !model.tools.hasFFmpeg {
                        Text("MP3 and its post-processing need ffmpeg. Install it in Settings, or export to M4A which works right now.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(busy ? "Exporting…" : "Export") { Task { await doExport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (asMP3 && !model.tools.hasFFmpeg))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            title = recording.title
            artist = recording.artist
            album = recording.album
        }
    }

    private func doExport() async {
        busy = true
        defer { busy = false }
        var req = AudioExporter.ExportRequest(source: recording.url, baseName: title.isEmpty ? recording.title : title)
        req.title = title; req.artist = artist; req.album = album
        req.asMP3 = asMP3; req.bitrate = bitrate.rawValue
        req.normalize = normalize; req.denoise = denoise
        req.fadeIn = fadeIn; req.fadeOut = fadeOut
        do {
            let out = try await model.exporter.export(req)
            model.insert(out)
            model.notify("Exported: \(out.title)", isError: false)
            dismiss()
        } catch {
            model.notify(error.localizedDescription, isError: true)
        }
    }
}
