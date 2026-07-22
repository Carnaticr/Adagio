import SwiftUI

@main
struct AdagioApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .modelContainer(model.container)
                .frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Record") {
                Button(model.recorder.isActive ? "Stop Recording" : "Start Recording") {
                    model.menuToggleRecord()
                }
                .keyboardShortcut("r")

                Button(model.recorder.phase == .paused ? "Resume" : "Pause") {
                    model.togglePauseResume()
                }
                .keyboardShortcut("p")
                .disabled(!model.recorder.isActive)

                Divider()

                Button("Discard Recording") {
                    Task { await model.stopRecording(cancel: true) }
                }
                .keyboardShortcut(.escape, modifiers: [.command])
                .disabled(!model.recorder.isActive)
            }
            CommandGroup(after: .toolbar) {
                ForEach(Tab.allCases) { tab in
                    Button(tab.title) { model.selectedTab = tab }
                        .keyboardShortcut(KeyEquivalent(Character("\(tabIndex(tab) + 1)")), modifiers: .command)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    private func tabIndex(_ tab: Tab) -> Int {
        Tab.allCases.firstIndex(of: tab) ?? 0
    }
}
