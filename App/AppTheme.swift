import Foundation
import Models
import SwiftUI
import TmuxKit
import UIKit

enum PocketshellTheme {
    private static var selected: TerminalTheme {
        TerminalTheme.named(
            UserDefaults.standard.string(forKey: AppSettings.terminalThemeKey) ?? TerminalTheme.defaultTheme.name
        )
    }

    private static var isLightChrome: Bool { selected.lightChrome }

    static var paper: Color { color(light: "F2F1EC", dark: selected.background) }
    static var surface: Color { color(light: "FFFFFF", darkMix: 0.08) }
    static var secondarySurface: Color { color(light: "ECEAE3", darkMix: 0.12) }
    static var pinnedSurface: Color { color(light: "E5E3DA", darkMix: 0.16) }
    static var border: Color { color(light: "D9D6CB", darkMix: 0.22) }
    static var divider: Color { color(light: "E9E7DE", darkMix: 0.14) }
    static var chipBorder: Color { color(light: "CFCCC0", darkMix: 0.28) }
    static var ink: Color { color(light: "16181A", dark: selected.foreground) }
    static var body: Color { color(light: "23262A", dark: selected.foreground) }
    static var secondary: Color { color(light: "5C6167", darkMix: 0.72) }
    static var muted: Color { color(light: "8A8E93", darkMix: 0.55) }
    static var faint: Color { color(light: "B6B9AE", darkMix: 0.40) }
    static var accent: Color { color(light: "E8590C", dark: selected.accentHex) }
    static var accentDark: Color { color(light: "C2410C", dark: selected.accentHex) }
    static var accentTint: Color { color(light: "FDF1E8", dark: mixed(selected.background, selected.accentHex, 0.18)) }
    static var accentBorder: Color {
        color(light: "EAB896", dark: mixed(selected.background, selected.accentHex, 0.50))
    }
    static let busy = Color(hexRGB: "D97706")
    static var busyText: Color { isLightChrome ? Color(hexRGB: "B45309") : busy }
    static let waiting = Color(hexRGB: "7C3AED")
    static var waitingText: Color { isLightChrome ? Color(hexRGB: "6D28D9") : waiting }
    static let idle = Color(hexRGB: "22A04D")
    static var idleText: Color { isLightChrome ? Color(hexRGB: "15803D") : idle }

    private static func color(light: String, dark: String) -> Color {
        Color(hexRGB: isLightChrome ? light : dark)
    }

    private static func color(light: String, darkMix amount: Double) -> Color {
        color(light: light, dark: mixed(selected.background, selected.foreground, amount))
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

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let saved = UserDefaults.standard.double(forKey: AppSettings.uiScaleKey)
        return .system(size: size * (saved == 0 ? 1 : saved), weight: weight, design: .monospaced)
    }
}

extension AgentStatus {
    var chromeColor: Color {
        switch self {
        case .busy: PocketshellTheme.busy
        case .waiting: PocketshellTheme.waiting
        case .idle: PocketshellTheme.idle
        }
    }

    var chromeTextColor: Color {
        switch self {
        case .busy: PocketshellTheme.busyText
        case .waiting: PocketshellTheme.waitingText
        case .idle: PocketshellTheme.idleText
        }
    }
}

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

private struct AppScreen: ViewModifier {
    @AppStorage(AppSettings.terminalThemeKey) private var themeName = TerminalTheme.defaultTheme.name

    func body(content: Content) -> some View {
        let theme = TerminalTheme.named(themeName)
        let style: UIUserInterfaceStyle = theme.lightChrome ? .light : .dark
        content
            .scrollContentBackground(.hidden)
            .background(PocketshellTheme.paper.ignoresSafeArea())
            .tint(PocketshellTheme.accent)
            .toolbarBackground(PocketshellTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(theme.lightChrome ? .light : .dark)
            .onAppear { Self.overrideWindows(style) }
            // On a first launch the scene is often not connected yet, so onAppear
            // iterates over no windows at all and the chrome keeps the system style.
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                Self.overrideWindows(style)
            }
            .onChange(of: themeName) { _, name in
                Self.overrideWindows(TerminalTheme.named(name).lightChrome ? .light : .dark)
            }
    }

    private static func overrideWindows(_ style: UIUserInterfaceStyle) {
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

extension View {
    func themedScreen() -> some View {
        modifier(AppScreen())
    }

    func paperScreen() -> some View {
        modifier(AppScreen())
    }
}
