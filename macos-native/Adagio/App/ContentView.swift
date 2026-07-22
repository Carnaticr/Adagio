import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Tab.allCases, selection: Binding<Tab?>(
                get: { model.selectedTab },
                set: { model.selectedTab = $0 ?? .record })
            ) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { ToolStatusFooter() }
        } detail: {
            Group {
                switch model.selectedTab {
                case .record: RecordView()
                case .youtube: YouTubeView()
                case .library: LibraryView()
                case .split: SplitView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) { PlayerBar() }
        }
        .overlay(alignment: .top) { BannerView() }
    }
}

private struct BannerView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let banner = model.banner {
            Text(banner.text)
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(banner.isError ? Color.red : Color.accentColor, lineWidth: 1))
                .padding(.top, 10)
                .shadow(radius: 8, y: 3)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(banner.id)
        }
    }
}

private struct ToolStatusFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(model.tools.hasFFmpeg ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(model.tools.hasFFmpeg ? "ffmpeg ready" : "ffmpeg: for MP3")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Circle().fill(model.tools.hasYtDlp ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(model.tools.hasYtDlp ? "yt-dlp ready" : "yt-dlp: for YouTube")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}
