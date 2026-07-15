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
    #expect(TerminalTheme.named("Dracula").accentHex == "bd93f9")
}

@Test func namedLookupFallsBackToDefault() {
    #expect(TerminalTheme.named("Dracula").name == "Dracula")
    #expect(TerminalTheme.named("nonexistent") == TerminalTheme.defaultTheme)
}
