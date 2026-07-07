import Models
import SwiftUI

enum AppSettings {
    static let terminalThemeKey = "pocketshell.terminalTheme"
}

struct SettingsView: View {
    @AppStorage(AppSettings.terminalThemeKey) private var themeName = TerminalTheme.defaultTheme.name

    var body: some View {
        List {
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
