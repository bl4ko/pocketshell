import Models
import SwiftUI

enum AppSettings {
    static let terminalThemeKey = "pocketshell.terminalTheme"
    static let appLockKey = "pocketshell.appLock"
    static let agentNotifyKey = "pocketshell.agentNotify"
}

struct SettingsView: View {
    @EnvironmentObject var monitor: SessionMonitor
    @AppStorage(AppSettings.terminalThemeKey) private var themeName = TerminalTheme.defaultTheme.name
    @AppStorage(AppSettings.appLockKey) private var appLock = false
    @AppStorage(AppSettings.agentNotifyKey) private var agentNotify = false

    var body: some View {
        List {
            Section {
                Toggle("Require Face ID", isOn: $appLock)
            } header: {
                Text("Security")
            } footer: {
                Text("Locks the app after 30 seconds in background. Takes effect on next launch.")
            }
            Section {
                Toggle("Notify when agents finish", isOn: $agentNotify)
                    .onChange(of: agentNotify) { _, on in
                        if on {
                            SessionMonitor.requestAuthorization()
                            monitor.startPolling()
                        } else {
                            monitor.stopPolling()
                        }
                    }
            } header: {
                Text("Agents")
            } footer: {
                Text("Polls tmux windows on hosts with a tmux session and notifies when a busy agent goes idle or needs input.")
            }
            Section("Terminal theme") {
                ForEach(TerminalTheme.all) { theme in
                    Button {
                        themeName = theme.name
                    } label: {
                        HStack {
                            themePreview(theme)
                            Text(theme.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if theme.name == themeName {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
    }

    private func themePreview(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(theme.ansi.prefix(8).enumerated()), id: \.offset) { _, hex in
                Circle()
                    .fill(color(hex))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(4)
        .background(color(theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func color(_ hex: String) -> Color {
        guard let rgb = RGBColor(hex: hex) else { return .black }
        return Color(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }
}
