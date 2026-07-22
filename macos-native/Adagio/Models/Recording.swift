import Foundation
import SwiftData

/// A single item in the library — a recording, import, YouTube download, or split segment.
/// Stored via SwiftData in Application Support (always writable, no file-permission issues).
@Model
final class Recording {
    // SwiftData provides Identifiable via `persistentModelID`; we keep a separate
    // stable UUID for export/reference without shadowing that conformance.
    var uuid: UUID
    var title: String
    var artist: String
    var album: String
    var tags: String
    var folder: String
    /// Bookmark-free absolute path. Files live under the app's Recordings dir, so a
    /// plain path is safe and portable across launches for a non-sandboxed app.
    var relativePath: String
    var kindRaw: String
    var durationMs: Int
    var sizeBytes: Int
    var createdAt: Date

    init(
        title: String,
        artist: String = "",
        album: String = "",
        tags: String = "",
        folder: String = "",
        relativePath: String,
        kind: RecordingKind,
        durationMs: Int,
        sizeBytes: Int,
        createdAt: Date = .now
    ) {
        self.uuid = UUID()
        self.title = title
        self.artist = artist
        self.album = album
        self.tags = tags
        self.folder = folder
        self.relativePath = relativePath
        self.kindRaw = kind.rawValue
        self.durationMs = durationMs
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
    }

    var kind: RecordingKind {
        get { RecordingKind(rawValue: kindRaw) ?? .recording }
        set { kindRaw = newValue.rawValue }
    }

    /// Resolve the on-disk URL. Paths are stored relative to the Recordings dir when
    /// possible so the library survives the container moving; absolute paths (imports)
    /// are used as-is.
    var url: URL {
        if relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: relativePath)
        }
        return Storage.recordingsDir.appendingPathComponent(relativePath)
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

enum RecordingKind: String, CaseIterable {
    case recording
    case export
    case youtube
    case importedFile = "import"
    case segment
    case merge

    var label: String {
        switch self {
        case .recording: return "recording"
        case .export: return "export"
        case .youtube: return "youtube"
        case .importedFile: return "import"
        case .segment: return "segment"
        case .merge: return "merge"
        }
    }
}
