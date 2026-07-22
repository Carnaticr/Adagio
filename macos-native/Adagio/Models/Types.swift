import Foundation

enum RecordMode: String, CaseIterable, Identifiable {
    case mic
    case system
    case combined

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mic: return "Voice"
        case .system: return "System audio"
        case .combined: return "Both"
        }
    }

    var symbol: String {
        switch self {
        case .mic: return "mic.fill"
        case .system: return "speaker.wave.2.fill"
        case .combined: return "person.wave.2.fill"
        }
    }
}

enum RecordPhase: Equatable {
    case idle
    case recording
    case paused
}

enum Bitrate: Int, CaseIterable, Identifiable {
    case b128 = 128
    case b192 = 192
    case b256 = 256
    case b320 = 320
    var id: Int { rawValue }
    var label: String { "\(rawValue) kbps" }
}

/// Formatting helpers shared across views.
enum Format {
    static func timer(_ ms: Int) -> String {
        let totalSec = ms / 1000
        return String(format: "%02d:%02d:%02d", totalSec / 3600, (totalSec % 3600) / 60, totalSec % 60)
    }

    static func time(_ ms: Int) -> String {
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func size(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b >= 1 << 30 { return String(format: "%.2f GB", b / Double(1 << 30)) }
        if b >= 1 << 20 { return String(format: "%.1f MB", b / Double(1 << 20)) }
        if b >= 1 << 10 { return String(format: "%.0f KB", b / Double(1 << 10)) }
        return "\(bytes) B"
    }
}
