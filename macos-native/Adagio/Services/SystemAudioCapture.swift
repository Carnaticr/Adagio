import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Captures "what you hear" using ScreenCaptureKit (macOS 13+) and writes it
/// straight to an .m4a file via AVAssetWriter — no virtual loopback device
/// (BlackHole) required, unlike the Tauri build.
///
/// A tiny 2×2 video stream is configured because SCStream requires a display
/// filter; we ignore the video frames and only consume `.audio` sample buffers.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let queue = DispatchQueue(label: "com.adagio.sck.audio")

    /// Set false to drop samples (used for pause).
    var writing = true
    /// Latest linear level 0…1, updated on the capture queue; read on main.
    private(set) var level: Float = 0
    let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw AdagioError.message("No display available for system-audio capture.")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Minimal video — SCStream needs a display but we discard frames.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 6)

        try setupWriter()

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func setupWriter() throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw AdagioError.message("Could not configure the system-audio writer.")
        }
        writer.add(input)
        self.writer = writer
        self.audioInput = input
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let writer, let audioInput else { return }

        updateLevel(from: sampleBuffer)
        guard writing else { return }

        if writer.status == .unknown, !sessionStarted {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        if writer.status == .writing, audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SCStream stopped: \(error.localizedDescription)")
    }

    /// Stop capture and finalize the file. Returns true if a non-empty file was written.
    func stop() async -> Bool {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        guard let writer, let audioInput, sessionStarted else { return false }
        audioInput.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        return writer.status == .completed && Storage.fileSize(outputURL) > 0
    }

    private func updateLevel(from sampleBuffer: CMSampleBuffer) {
        var rms: Float = 0
        var count = 0
        try? sampleBuffer.withAudioBufferList { abl, _ in
            for buffer in abl {
                guard let data = buffer.mData else { continue }
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let ptr = data.assumingMemoryBound(to: Float.self)
                var sum: Float = 0
                for i in 0..<n { sum += ptr[i] * ptr[i] }
                rms += sum
                count += n
            }
        }
        level = count > 0 ? min(1, (rms / Float(count)).squareRoot() * 1.8) : 0
    }
}
