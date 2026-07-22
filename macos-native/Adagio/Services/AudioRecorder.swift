import Foundation
import AVFoundation

/// Coordinates the three recording modes. Mic uses AVAudioRecorder (rock-solid,
/// built-in metering). System audio uses ScreenCaptureKit. Combined records both
/// to temp files and mixes them natively on stop. Everything writes to the app's
/// Recordings dir, so saving never depends on ~/Music permissions.
@MainActor
@Observable
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var phase: RecordPhase = .idle
    private(set) var elapsedMs = 0
    private(set) var micLevel: Float = 0
    private(set) var sysLevel: Float = 0
    private(set) var peaks: [Float] = []
    static let maxPeaks = 600

    private var mode: RecordMode = .mic
    private var baseName = ""
    private var micRecorder: AVAudioRecorder?
    private var micURL: URL?
    private var sysCapture: SystemAudioCapture?
    private var sysURL: URL?

    private var timer: Timer?
    private var startDate: Date?
    private var pausedAccum: TimeInterval = 0
    private var pauseStart: Date?

    struct RecordingResult {
        let url: URL
        let durationMs: Int
        let sizeBytes: Int
        let kind: RecordingKind
        let baseName: String
    }

    func requestMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(mode: RecordMode) async throws {
        guard phase == .idle else { return }
        self.mode = mode
        baseName = Storage.timestampName()
        peaks = []
        elapsedMs = 0
        pausedAccum = 0
        pauseStart = nil

        let wantMic = mode == .mic || mode == .combined
        let wantSys = mode == .system || mode == .combined

        if wantMic {
            guard await requestMicPermission() else {
                throw AdagioError.message("Microphone access was denied. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
            }
            let suffix = wantSys ? "_mic" : ""
            let url = Storage.uniqueURL(baseName: baseName + suffix, ext: "m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw AdagioError.message("Could not start the microphone recorder.")
            }
            micRecorder = recorder
            micURL = url
        }

        if wantSys {
            let suffix = wantMic ? "_sys" : ""
            let url = Storage.uniqueURL(baseName: baseName + suffix, ext: "m4a")
            let capture = SystemAudioCapture(outputURL: url)
            do {
                try await capture.start()
            } catch {
                // If system capture fails, don't leave a half-started mic session.
                micRecorder?.stop()
                micRecorder = nil
                throw AdagioError.message("System-audio capture failed: \(error.localizedDescription). Grant Screen Recording permission in System Settings ▸ Privacy & Security.")
            }
            sysCapture = capture
            sysURL = url
        }

        startDate = Date()
        phase = .recording
        startTimer()
    }

    func pause() {
        guard phase == .recording else { return }
        phase = .paused
        micRecorder?.pause()
        sysCapture?.writing = false
        pauseStart = Date()
    }

    func resume() {
        guard phase == .paused else { return }
        if let pauseStart { pausedAccum += Date().timeIntervalSince(pauseStart) }
        pauseStart = nil
        micRecorder?.record()
        sysCapture?.writing = true
        phase = .recording
    }

    /// Stop, finalize, and (for combined) mix. Returns nil if canceled.
    func stop(cancel: Bool) async throws -> RecordingResult? {
        guard phase != .idle else { return nil }
        stopTimer()
        let capturedElapsed = elapsedMs

        micRecorder?.stop()
        let sysOK = await sysCapture?.stop() ?? false

        let mic = micURL
        let sys = (sysOK ? sysURL : nil)
        // Reset live state now; file work happens below.
        micRecorder = nil
        sysCapture = nil
        micURL = nil
        sysURL = nil
        phase = .idle
        micLevel = 0
        sysLevel = 0

        if cancel {
            [mic, sys].compactMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) }
            return nil
        }

        let finalURL: URL
        let kind: RecordingKind = .recording
        if mode == .combined, let mic, let sys {
            let out = Storage.uniqueURL(baseName: baseName, ext: "m4a")
            try AudioMixer.mix(mic, sys, into: out)
            try? FileManager.default.removeItem(at: mic)
            try? FileManager.default.removeItem(at: sys)
            finalURL = out
        } else if let only = mic ?? sys {
            finalURL = only
        } else {
            throw AdagioError.message("Nothing was recorded.")
        }

        guard Storage.fileSize(finalURL) > 0 else {
            throw AdagioError.message("The recording file was empty — check microphone / screen-recording permissions.")
        }

        var duration = Probe.durationMs(finalURL)
        if duration == 0 { duration = capturedElapsed }
        return RecordingResult(
            url: finalURL,
            durationMs: duration,
            sizeBytes: Storage.fileSize(finalURL),
            kind: kind,
            baseName: baseName
        )
    }

    var isActive: Bool { phase != .idle }

    // MARK: - Metering timer

    private func startTimer() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let startDate else { return }
        let now = Date()
        var e = now.timeIntervalSince(startDate) - pausedAccum
        if let pauseStart { e -= now.timeIntervalSince(pauseStart) }
        elapsedMs = max(0, Int(e * 1000))

        if let r = micRecorder {
            r.updateMeters()
            let db = r.averagePower(forChannel: 0)
            micLevel = db <= -80 ? 0 : min(1, powf(10, db / 20) * 1.6)
        }
        if let c = sysCapture {
            sysLevel = c.level
        }

        if phase == .recording {
            let peak = max(micLevel, sysLevel)
            peaks.append(peak)
            if peaks.count > Self.maxPeaks { peaks.removeFirst(peaks.count - Self.maxPeaks) }
        }
    }

    /// List available input devices for the picker.
    static func inputDevices() -> [String] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified)
        return session.devices.map { $0.localizedName }
    }
}
