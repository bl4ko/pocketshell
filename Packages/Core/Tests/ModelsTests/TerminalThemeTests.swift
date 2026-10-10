import Testing

@testable import Models

@Test func hexParsesSixDigitColor() {
    let rgb = RGBColor(hex: "282a36")
    #expect(rgb == RGBColor(red: 0x28, green: 0x2a, blue: 0x36))
}

@Test func hexParsesWithLeadingHash() {
    #expect(RGBColor(hex: "#ff5555") == RGBColor(red: 0xff, green: 0x55, blue: 0x55))
}

@Test func hexRejectsInvalidInput() {
    #expect(RGBColor(hex: "xyzxyz") == nil)
    #expect(RGBColor(hex: "fff") == nil)
    #expect(RGBColor(hex: "") == nil)
}

@Test func allThemesHaveSixteenAnsiColors() {
    #expect(!TerminalTheme.all.isEmpty)
    for theme in TerminalTheme.all {
        #expect(theme.ansi.count == 16)
        #expect(RGBColor(hex: theme.background) != nil)
        #expect(RGBColor(hex: theme.foreground) != nil)
        #expect(RGBColor(hex: theme.cursor) != nil)
        for color in theme.ansi {
            #expect(RGBColor(hex: color) != nil)
        }
    }
}

@Test func themeNamesAreUnique() {
    let names = TerminalTheme.all.map(\.name)
    #expect(Set(names).count == names.count)
}

@Test func accentHexIsAnsiBlue() {
    #expect(TerminalTheme.defaultTheme.accentHex == "2472c8")
    #expect(TerminalTheme.named("Pocketshell").background == "24262b")
    #expect(TerminalTheme.named("Pocketshell").accentHex == "e8590c")
    #expect(TerminalTheme.named("Dracula").accentHex == "bd93f9")
}

@Test func namedLookupFallsBackToDefault() {
    #expect(TerminalTheme.named("Dracula").name == "Dracula")
    #expect(TerminalTheme.named("nonexistent") == TerminalTheme.defaultTheme)
}

private let tokyoNight: [(name: String, background: String, foreground: String, light: Bool)] = [
    ("Tokyo Night", "1a1b26", "c0caf5", false),
    ("Tokyo Night Storm", "24283b", "c0caf5", false),
    ("Tokyo Night Moon", "222436", "c8d3f5", false),
    ("Tokyo Night Day", "e1e2e7", "3760bf", true),
]

@Test func tokyoNightVariantsAreRegisteredAndPinned() {
    for expected in tokyoNight {
        let matches = TerminalTheme.all.filter { $0.name == expected.name }
        #expect(matches.count == 1)
        let theme = TerminalTheme.named(expected.name)
        #expect(theme.name == expected.name)
        #expect(theme.background == expected.background)
        #expect(theme.foreground == expected.foreground)
        #expect(theme.cursor == expected.foreground)
        #expect(theme.lightChrome == expected.light)
        #expect(theme.ansi.count == 16)
        for color in theme.ansi + [theme.background, theme.foreground, theme.cursor] {
            #expect(color.count == 6)
            #expect(RGBColor(hex: color) != nil)
        }
    }
}

@Test func tokyoNightAnsiPalettesArePinned() {
    #expect(TerminalTheme.named("Tokyo Night").ansi[1] == "f7768e")
    #expect(TerminalTheme.named("Tokyo Night").accentHex == "7aa2f7")
    #expect(TerminalTheme.named("Tokyo Night Storm").ansi[0] == "1d202f")
    #expect(TerminalTheme.named("Tokyo Night Moon").ansi[2] == "c3e88d")
    #expect(TerminalTheme.named("Tokyo Night Day").ansi[15] == "3760bf")
}
