import Foundation
import AVFoundation

enum AdagioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// Lightweight media probing that works without ffprobe (AVFoundation decodes m4a/wav/mp3/etc).
enum Probe {
    static func durationMs(_ url: URL) -> Int {
        if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
            return Int(Double(file.length) / file.fileFormat.sampleRate * 1000)
        }
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite ? Int(seconds * 1000) : 0
    }
}
