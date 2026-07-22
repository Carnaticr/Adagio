import SwiftUI

struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var player = model.player
        if player.currentURL != nil {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 22)
                    }
                    .buttonStyle(.borderless)

                    Text(player.title)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                        .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { player.duration > 0 ? player.currentTime / player.duration : 0 },
                            set: { player.seek(toFraction: $0) }),
                        in: 0...1)

                    Text("\(Format.time(Int(player.currentTime * 1000))) / \(Format.time(Int(player.duration * 1000)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 96)

                    Picker("", selection: $player.rate) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Text("\(r == 1.0 ? "1" : String(format: "%g", r))×").tag(Float(r))
                        }
                    }
                    .frame(width: 72)
                    .help("Playback speed")

                    Toggle("Skip silence", isOn: $player.skipSilence)
                        .toggleStyle(.checkbox)
                        .help("Jump over silent passages during playback")

                    Button {
                        player.closePlayer()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}
