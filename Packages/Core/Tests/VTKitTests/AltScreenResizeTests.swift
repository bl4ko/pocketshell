import Testing

@testable import VTKit

struct AltScreenResizeTests {
    @Test func shrinkingAltScreenKeepsTopRows() {
        let terminal = VTTerminal(cols: 20, rows: 10)
        terminal.feed("\u{1b}[?1049h\u{1b}[1;1HHEADER\u{1b}[10;1HPROMPT")

        terminal.resize(cols: 20, rows: 6)

        #expect(terminal.lines()[0] == "HEADER")
        #expect(terminal.cursor.row == 5)
    }

    @Test func shrinkingNormalScreenKeepsCursorRow() {
        let terminal = VTTerminal(cols: 20, rows: 10)
        terminal.feed("\u{1b}[1;1HHEADER\u{1b}[10;1HPROMPT")

        terminal.resize(cols: 20, rows: 6)

        #expect(terminal.lines()[5] == "PROMPT")
    }
}
