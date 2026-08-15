#if os(iOS)
    import Models
    import SwiftUI

    enum ToolbarPalette {
        static let dark = Color(red: 22 / 255, green: 24 / 255, blue: 26 / 255)
        static let darkKey = Color(red: 35 / 255, green: 38 / 255, blue: 42 / 255)
        static let darkBorder = Color(red: 60 / 255, green: 64 / 255, blue: 69 / 255)

        static func bar(_ theme: TerminalTheme) -> Color { themed("ECEAE3", theme, mix: 0.12) }
        static func pinned(_ theme: TerminalTheme) -> Color { themed("E5E3DA", theme, mix: 0.16) }
        static func key(_ theme: TerminalTheme) -> Color { themed("FFFFFF", theme, mix: 0.08) }
        static func border(_ theme: TerminalTheme) -> Color { themed("CFCCC0", theme, mix: 0.28) }
        static func text(_ theme: TerminalTheme) -> Color { themed("3C4045", theme, dark: theme.foreground) }
        static func accent(_ theme: TerminalTheme) -> Color { themed("E8590C", theme, dark: theme.accentHex) }
        static func accentDark(_ theme: TerminalTheme) -> Color {
            themed("C2410C", theme, dark: theme.accentHex)
        }
        static func accentTint(_ theme: TerminalTheme) -> Color {
            themed("FDF1E8", theme, dark: mixed(theme.background, theme.accentHex, 0.18))
        }
        static func accentBorder(_ theme: TerminalTheme) -> Color {
            themed("EAB896", theme, dark: mixed(theme.background, theme.accentHex, 0.50))
        }

        private static func themed(_ light: String, _ theme: TerminalTheme, dark: String) -> Color {
            color(theme.lightChrome ? light : dark)
        }

        private static func themed(_ light: String, _ theme: TerminalTheme, mix: Double) -> Color {
            themed(light, theme, dark: mixed(theme.background, theme.foreground, mix))
        }

        private static func color(_ hex: String) -> Color {
            let rgb = RGBColor(hex: hex) ?? RGBColor(red: 0, green: 0, blue: 0)
            return Color(
                red: Double(rgb.red) / 255,
                green: Double(rgb.green) / 255,
                blue: Double(rgb.blue) / 255
            )
        }

        private static func mixed(_ from: String, _ to: String, _ amount: Double) -> String {
            guard let from = RGBColor(hex: from), let to = RGBColor(hex: to) else { return from }
            func channel(_ a: UInt8, _ b: UInt8) -> UInt8 {
                UInt8((Double(a) + (Double(b) - Double(a)) * amount).rounded())
            }
            return String(
                format: "%02x%02x%02x",
                channel(from.red, to.red),
                channel(from.green, to.green),
                channel(from.blue, to.blue)
            )
        }
    }
#endif
