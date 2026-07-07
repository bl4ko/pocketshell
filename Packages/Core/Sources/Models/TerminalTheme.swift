import Foundation

public struct RGBColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        red = UInt8((value >> 16) & 0xff)
        green = UInt8((value >> 8) & 0xff)
        blue = UInt8(value & 0xff)
    }
}

public struct TerminalTheme: Equatable, Sendable, Identifiable {
    public let name: String
    public let background: String
    public let foreground: String
    public let cursor: String
    public let ansi: [String]

    public var id: String { name }

    public static func named(_ name: String) -> TerminalTheme {
        all.first { $0.name == name } ?? defaultTheme
    }

    public static let defaultTheme = TerminalTheme(
        name: "Default",
        background: "000000",
        foreground: "ffffff",
        cursor: "aaaaaa",
        ansi: [
            "000000", "cd3131", "0dbc79", "e5e510", "2472c8", "bc3fbc", "11a8cd", "e5e5e5",
            "666666", "f14c4c", "23d18b", "f5f543", "3b8eea", "d670d6", "29b8db", "ffffff",
        ]
    )

    public static let all: [TerminalTheme] = [
        defaultTheme,
        TerminalTheme(
            name: "Dracula",
            background: "282a36",
            foreground: "f8f8f2",
            cursor: "f8f8f2",
            ansi: [
                "21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2",
                "6272a4", "ff6e6e", "69ff94", "ffffa5", "d6acff", "ff92df", "a4ffff", "ffffff",
            ]
        ),
        TerminalTheme(
            name: "Catppuccin Mocha",
            background: "1e1e2e",
            foreground: "cdd6f4",
            cursor: "f5e0dc",
            ansi: [
                "45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "bac2de",
                "585b70", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8",
            ]
        ),
        TerminalTheme(
            name: "Nord",
            background: "2e3440",
            foreground: "d8dee9",
            cursor: "d8dee9",
            ansi: [
                "3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
                "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4",
            ]
        ),
        TerminalTheme(
            name: "Gruvbox Dark",
            background: "282828",
            foreground: "ebdbb2",
            cursor: "ebdbb2",
            ansi: [
                "282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
                "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2",
            ]
        ),
        TerminalTheme(
            name: "Solarized Dark",
            background: "002b36",
            foreground: "839496",
            cursor: "839496",
            ansi: [
                "073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3",
            ]
        ),
    ]
}
