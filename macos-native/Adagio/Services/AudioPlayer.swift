import Foundation
import AVFoundation

/// Simple library player with variable speed (0.5×–2×) and optional skip-silence.
@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var currentURL: URL?
    private(set) var title = ""
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    var rate: Float = 1.0 {
        didSet { player?.rate = rate }
    }
    var skipSilence = false {
        didSet { if skipSilence, silences.isEmpty { loadSilences() } }
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var silences: [(start: Double, end: Double)] = []

    func play(url: URL, title: String) {
        if currentURL != url {
            stopTimer()
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.enableRate = true
                p.rate = rate
                p.prepareToPlay()
                player = p
                currentURL = url
                self.title = title
                duration = p.duration
                silences = []
            } catch {
                NSLog("play failed: \(error.localizedDescription)")
                return
            }
        }
        player?.play()
        isPlaying = true
        startTimer()
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true; startTimer() }
    }

    func seek(toFraction f: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(duration, f * duration))
        currentTime = player.currentTime
    }

    func seek(toTime t: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(duration, t))
        currentTime = player.currentTime
        if !player.isPlaying { player.play(); isPlaying = true; startTimer() }
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopTimer()
    }

    func closePlayer() {
        stop()
        player = nil
        currentURL = nil
        title = ""
    }

    private func loadSilences() {
        guard let url = currentURL else { return }
        Task.detached {
            let ranges = (try? SilenceDetector.detect(url: url, thresholdDb: -35, minSilence: 1.0)) ?? []
            await MainActor.run { self.silences = ranges.map { ($0.start, $0.end) } }
        }
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let player, player.isPlaying else { return }
        currentTime = player.currentTime
        if skipSilence {
            let t = player.currentTime
            for r in silences where t > r.start + 0.25 && t < r.end - 0.25 {
                player.currentTime = r.end - 0.15
                currentTime = player.currentTime
                break
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
        }
    }
}
