import Models
import SwiftUI

extension Color {
    init(hexRGB: String) {
        let rgb = RGBColor(hex: hexRGB) ?? RGBColor(red: 0, green: 0, blue: 0)
        self.init(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }
}

extension TerminalTheme {
    var backgroundColor: Color { Color(hexRGB: background) }
    var accentColor: Color { Color(hexRGB: accentHex) }
}

private struct ThemedScreen: ViewModifier {
    @AppStorage(AppSettings.terminalThemeKey) private var themeName = TerminalTheme.defaultTheme.name

    func body(content: Content) -> some View {
        let theme = TerminalTheme.named(themeName)
        content
            .scrollContentBackground(.hidden)
            .background(theme.backgroundColor.ignoresSafeArea())
            .tint(theme.accentColor)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func themedScreen() -> some View {
        modifier(ThemedScreen())
    }
}
