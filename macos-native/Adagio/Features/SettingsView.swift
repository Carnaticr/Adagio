import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ToolsPane().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            AboutPane().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 380)
    }
}

private struct ToolsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var tools = model.tools
        Form {
            Section {
                Text("Adagio records, plays, splits and exports to M4A with no external tools. ffmpeg unlocks MP3 export; yt-dlp enables YouTube downloads.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Status") {
                statusRow("ffmpeg", ok: tools.hasFFmpeg, url: tools.ffmpegURL)
                statusRow("ffprobe", ok: tools.ffprobeURL != nil, url: tools.ffprobeURL)
                statusRow("yt-dlp", ok: tools.hasYtDlp, url: tools.ytdlpURL)
            }

            Section("Custom tools folder") {
                HStack {
                    TextField("Folder containing ffmpeg / yt-dlp", text: $tools.customBinDir)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFolder() }
                }
                Text("Also searched automatically: /opt/homebrew/bin, /usr/local/bin, /opt/local/bin.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Auto-download") {
                HStack {
                    Button(model.installer.installing ? "Installing…" : "Download missing tools") {
                        Task { await model.installer.install(locator: tools) }
                    }
                    .disabled(model.installer.installing || (tools.hasFFmpeg && tools.hasYtDlp))
                    Button("Recheck") { tools.refresh() }
                    Spacer()
                    if !model.installer.status.isEmpty {
                        Text(model.installer.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.installer.installing {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func statusRow(_ name: String, ok: Bool, url: URL?) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
            Text(name)
            Spacer()
            Text(url?.path ?? "not found").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.tools.customBinDir = url.path
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 46)).foregroundStyle(.tint)
            Text("Adagio").font(.title.bold())
            Text("Version 0.1.0").foregroundStyle(.secondary)
            Text("Offline-first sound recorder for macOS.\nVoice & system-audio recording, YouTube → MP3, silence-based splitting.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            Button("Open Recordings Folder") {
                NSWorkspace.shared.open(Storage.recordingsDir)
            }
            .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
