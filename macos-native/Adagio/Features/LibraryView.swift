import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Recording.createdAt, order: .reverse) private var allRecordings: [Recording]

    @State private var search = ""
    @State private var folder = ""
    @State private var selection = Set<Recording.ID>()
    @State private var editing: Recording?
    @State private var exporting: Recording?
    @State private var importing = false

    private var folders: [String] {
        Array(Set(allRecordings.map(\.folder))).filter { !$0.isEmpty }.sorted()
    }

    private var filtered: [Recording] {
        allRecordings.filter { rec in
            (folder.isEmpty || rec.folder == folder) &&
            (search.isEmpty ||
             [rec.title, rec.artist, rec.album, rec.tags]
                .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    private var selectedRecordings: [Recording] {
        filtered.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            table
            if !selection.isEmpty { bulkBar }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Label("Import", systemImage: "plus") }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search title, artist, tags…")
        .safeAreaInset(edge: .top) { folderBar }
        .sheet(item: $editing) { EditSheet(recording: $0) }
        .sheet(item: $exporting) { ExportSheet(recording: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
    }

    private var folderBar: some View {
        HStack {
            Picker("Folder", selection: $folder) {
                Text("All folders").tag("")
                ForEach(folders, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 260)
            Spacer()
            Text("\(filtered.count) item(s)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Title") { rec in
                VStack(alignment: .leading, spacing: 1) {
                    Text(rec.title).lineLimit(1)
                    if !rec.artist.isEmpty || !rec.tags.isEmpty {
                        Text([rec.artist, rec.tags.isEmpty ? "" : "#\(rec.tags)"]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .opacity(rec.fileExists ? 1 : 0.4)
            }
            TableColumn("Kind") { rec in
                Text(rec.kind.label).font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .width(80)
            TableColumn("Duration") { rec in
                Text(Format.time(rec.durationMs)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Size") { rec in
                Text(Format.size(rec.sizeBytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Date") { rec in
                Text(rec.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            .width(120)
            TableColumn("Folder") { rec in
                Text(rec.folder).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: Recording.ID.self) { ids in
            let recs = filtered.filter { ids.contains($0.id) }
            if let rec = recs.first, recs.count == 1 {
                Button("Play") { model.play(rec) }
                Button("Edit Metadata…") { editing = rec }
                Button("Export…") { exporting = rec }
                Button("Split by Silence…") { model.openInSplit(rec) }
                Button("Reveal in Finder") { reveal(rec) }
                Divider()
            }
            Button("Delete…", role: .destructive) { deleteWithPrompt(recs) }
        } primaryAction: { ids in
            if let rec = filtered.first(where: { ids.contains($0.id) }) { model.play(rec) }
        }
        .onDeleteCommand { deleteWithPrompt(selectedRecordings) }
    }

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Merge") { Task { await mergeSelected() } }
                .disabled(selection.count < 2)
            Button("Delete", role: .destructive) { deleteWithPrompt(selectedRecordings) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Actions

    private func reveal(_ rec: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([rec.url])
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let title = url.deletingPathExtension().lastPathComponent
            model.insert(title: title, url: url, kind: .importedFile,
                         durationMs: Probe.durationMs(url), sizeBytes: Storage.fileSize(url))
        }
        model.notify("Imported \(urls.count) file(s)", isError: false)
    }

    private func deleteWithPrompt(_ recs: [Recording]) {
        guard !recs.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(recs.count) item(s) from the library?"
        alert.informativeText = "Choose whether to also delete the audio files from disk."
        alert.addButton(withTitle: "Remove Entries Only")
        alert.addButton(withTitle: "Delete Files Too")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: model.delete(recs, removeFiles: false)
        case .alertSecondButtonReturn: model.delete(recs, removeFiles: true)
        default: return
        }
        selection.removeAll()
    }

    private func mergeSelected() async {
        let recs = selectedRecordings
        guard recs.count >= 2 else { return }
        let title = "Merged_\(Date.now.formatted(.dateTime.year().month().day()))"
        do {
            let out = try await model.exporter.merge(
                sources: recs.map(\.url), title: title, asMP3: false, bitrate: 192)
            model.insert(out)
            selection.removeAll()
            model.notify("Merged \(recs.count) items", isError: false)
        } catch {
            model.notify(error.localizedDescription, isError: true)
        }
    }
}
