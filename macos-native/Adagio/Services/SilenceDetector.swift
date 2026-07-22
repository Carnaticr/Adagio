import Foundation
import AVFoundation

/// Native silence detection: decodes the file to mono PCM and scans RMS over short
/// windows to find pauses. No ffmpeg required — this is the analysis the "Smart
/// split by silence" feature runs on.
enum SilenceDetector {
    struct Range { let start: Double; let end: Double }

    /// - Parameters:
    ///   - thresholdDb: level below which audio counts as silence (e.g. -30).
    ///   - minSilence: minimum silence duration in seconds to report.
    static func detect(url: URL, thresholdDb: Double, minSilence: Double) throws -> [Range] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return [] }

        let total = AVAudioFrameCount(file.length)
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
            return []
        }
        try file.read(into: buffer)
        guard let chData = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)

        // 20 ms analysis windows.
        let windowSize = max(1, Int(sampleRate * 0.02))
        let threshold = Float(pow(10.0, thresholdDb / 20.0))

        var ranges: [Range] = []
        var silentStart: Double?
        var i = 0
        while i < frames {
            let end = min(frames, i + windowSize)
            var sum: Float = 0
            var count = 0
            var j = i
            while j < end {
                for ch in 0..<channels {
                    let v = chData[ch][j]
                    sum += v * v
                }
                count += channels
                j += 1
            }
            let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
            let t = Double(i) / sampleRate

            if rms < threshold {
                if silentStart == nil { silentStart = t }
            } else if let s = silentStart {
                let dur = t - s
                if dur >= minSilence { ranges.append(Range(start: s, end: t)) }
                silentStart = nil
            }
            i += windowSize
        }
        if let s = silentStart {
            let endT = Double(frames) / sampleRate
            if endT - s >= minSilence { ranges.append(Range(start: s, end: endT)) }
        }
        return ranges
    }

    /// Propose cut points (seconds) at the centre of each qualifying silence,
    /// respecting a minimum segment length.
    static func proposeCuts(from silences: [Range], duration: Double, minSegment: Double) -> [Double] {
        var cuts: [Double] = []
        var last = 0.0
        for s in silences {
            let mid = (s.start + s.end) / 2
            if mid - last >= minSegment && duration - mid >= minSegment {
                cuts.append(mid)
                last = mid
            }
        }
        return cuts
    }
}
