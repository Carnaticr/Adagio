import Foundation
import AVFoundation

/// Native audio utilities: mixing two files (for Combined mode) and reading peak
/// data for waveforms — all via AVFoundation, no ffmpeg.
enum AudioMixer {
    /// Sum two audio files sample-by-sample into a new .m4a. Both are decoded to a
    /// common 44.1 kHz stereo float format, added with headroom, and re-encoded.
    static func mix(_ a: URL, _ b: URL, into output: URL) throws {
        let fileA = try AVAudioFile(forReading: a)
        let fileB = try AVAudioFile(forReading: b)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44_100, channels: 2, interleaved: false)!

        let pcmA = try readResampled(fileA, to: format)
        let pcmB = try readResampled(fileB, to: format)
        let frames = max(pcmA.frameLength, pcmB.frameLength)

        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AdagioError.message("Could not allocate mix buffer.")
        }
        out.frameLength = frames
        let channels = Int(format.channelCount)
        for ch in 0..<channels {
            guard let dst = out.floatChannelData?[ch] else { continue }
            let srcA = pcmA.floatChannelData?[min(ch, Int(pcmA.format.channelCount) - 1)]
            let srcB = pcmB.floatChannelData?[min(ch, Int(pcmB.format.channelCount) - 1)]
            for i in 0..<Int(frames) {
                let va = i < Int(pcmA.frameLength) ? (srcA?[i] ?? 0) : 0
                let vb = i < Int(pcmB.frameLength) ? (srcB?[i] ?? 0) : 0
                dst[i] = max(-1, min(1, (va + vb) * 0.8))
            }
        }

        try writeM4A(out, to: output)
    }

    /// Decode a whole file into a single PCM buffer in the target format.
    private static func readResampled(_ file: AVAudioFile, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let srcFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: srcFormat, to: format) else {
            throw AdagioError.message("Unsupported audio format in mix input.")
        }
        // Read the entire source into a buffer first.
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AdagioError.message("Could not allocate read buffer.")
        }
        try file.read(into: srcBuffer)

        let ratio = format.sampleRate / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(srcBuffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else {
            throw AdagioError.message("Could not allocate convert buffer.")
        }

        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return srcBuffer
        }
        if let error { throw error }
        return outBuffer
    }

    private static func writeM4A(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: Int(buffer.format.channelCount),
            AVEncoderBitRateKey: 192_000,
        ]
        let outFile = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        try outFile.write(from: buffer)
    }

    /// Downsample a file to `points` peak magnitudes (0…1) for waveform drawing.
    static func peaks(_ url: URL, points: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        guard total > 0, points > 0 else { return Array(repeating: 0, count: points) }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
            return Array(repeating: 0, count: points)
        }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard let chData = buffer.floatChannelData, frames > 0 else {
            return Array(repeating: 0, count: points)
        }

        var result = [Float](repeating: 0, count: points)
        let perBucket = max(1, frames / points)
        for p in 0..<points {
            let start = p * perBucket
            if start >= frames { break }
            let end = min(frames, start + perBucket)
            var peak: Float = 0
            for i in start..<end {
                for ch in 0..<channels {
                    let v = abs(chData[ch][i])
                    if v > peak { peak = v }
                }
            }
            result[p] = min(1, peak)
        }
        return result
    }
}
