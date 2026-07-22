import SwiftUI

struct RecordView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let recorder = model.recorder
        let phase = recorder.phase

        ScrollView {
            VStack(spacing: 20) {
                // Source picker
                GroupBox("Source") {
                    Picker("", selection: $model.recordMode) {
                        ForEach(RecordMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(phase != .idle)
                    .padding(6)

                    if model.recordMode != .mic {
                        Text("System audio is captured with ScreenCaptureKit — the first time you record it, macOS asks for Screen Recording permission. No extra software needed.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6).padding(.bottom, 6)
                    }
                }

                // Timer + waveform
                VStack(spacing: 14) {
                    Text(Format.timer(recorder.elapsedMs))
                        .font(.system(size: 52, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(phase == .paused ? Color.orange : .primary)

                    LiveWaveform(peaks: recorder.peaks, active: phase == .recording)
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                                .padding(10)
                        }

                    LevelMeter(label: "Mic", level: recorder.micLevel)
                    LevelMeter(label: "System", level: recorder.sysLevel)
                }
                .padding(18)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                // Controls
                HStack(spacing: 12) {
                    if phase == .idle {
                        Button {
                            Task { await model.startRecording() }
                        } label: {
                            Label("Record", systemImage: "record.circle.fill")
                                .frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                    } else {
                        Button {
                            model.togglePauseResume()
                        } label: {
                            Label(phase == .paused ? "Resume" : "Pause",
                                  systemImage: phase == .paused ? "play.fill" : "pause.fill")
                        }
                        .controlSize(.large)

                        Button {
                            Task { await model.stopRecording(cancel: false) }
                        } label: {
                            Label("Stop & Save", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button(role: .destructive) {
                            Task { await model.stopRecording(cancel: true) }
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                        .controlSize(.large)
                    }
                }

                Text("Shortcuts: ⌘R start/stop · ⌘P pause/resume · recordings save to your library automatically")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Record")
    }

    private var statusColor: Color {
        switch model.recorder.phase {
        case .recording: return .red
        case .paused: return .orange
        case .idle: return .secondary
        }
    }
}

private struct LevelMeter: View {
    let label: String
    let level: Float
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .yellow, .red],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
                }
            }
            .frame(height: 8)
        }
    }
}
