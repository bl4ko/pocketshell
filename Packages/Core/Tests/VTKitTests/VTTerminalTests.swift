import Testing

@testable import VTKit

struct VTTerminalTests {
    @Test func feedsTextAndReadsLines() {
        let terminal = VTTerminal(cols: 20, rows: 5)
        terminal.feed("hello\r\nworld")
        #expect(terminal.lines()[0] == "hello")
        #expect(terminal.lines()[1] == "world")
        #expect(terminal.cursor == VTPoint(col: 5, row: 1))
    }
}

struct VTTerminalStateTests {
    @Test func skippedCellsReadAsSpacesNotNUL() {
        let terminal = VTTerminal(cols: 30, rows: 3)
        terminal.feed("export\u{1b}[1CTART_HOME")
        #expect(terminal.lines()[0] == "export TART_HOME")
        #expect(!terminal.visibleText().contains("\u{0}"))
    }

    @Test func longGraphemeClustersSurviveLineText() {
        let terminal = VTTerminal(cols: 10, rows: 2)
        let text = "e" + String(repeating: "\u{0301}", count: 20) + "x"
        terminal.feed(text)
        #expect(Array(terminal.lines()[0].unicodeScalars) == Array(text.unicodeScalars))
    }

    @Test func lineCellsCarryTheirColumns() {
        let terminal = VTTerminal(cols: 6, rows: 1)
        terminal.feed("a漢b")
        let cells = terminal.lineCells(row: 0).prefix(3)
        #expect(cells.map(\.text) == ["a", "漢", "b"])
        #expect(cells.map(\.col) == [0, 1, 3])
        #expect(cells.map(\.wide) == [false, true, false])
    }

    @Test func wideCharactersReadOnce() {
        let terminal = VTTerminal(cols: 10, rows: 2)
        terminal.feed("a漢b")
        #expect(terminal.lines()[0] == "a漢b")
    }

    @Test func reportsModes() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        #expect(!terminal.applicationCursor)
        #expect(!terminal.bracketedPaste)
        #expect(!terminal.isAlternateScreen)
        #expect(terminal.mouseTracking == .none)
        terminal.feed("\u{1b}[?1h\u{1b}[?2004h\u{1b}[?1049h\u{1b}[?1002h")
        #expect(terminal.applicationCursor)
        #expect(terminal.bracketedPaste)
        #expect(terminal.isAlternateScreen)
        #expect(terminal.mouseTracking == .button)
    }

    @Test func tracksCursorVisibility() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        terminal.feed("\u{1b}[?25l")
        #expect(!terminal.cursorVisible)
        terminal.feed("\u{1b}[?25h")
        #expect(terminal.cursorVisible)
    }

    @Test func reportsTitleAndClipboard() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        var title: String?
        var clipboard: String?
        terminal.onTitle = { title = $0 }
        terminal.onClipboard = { clipboard = $0 }
        terminal.feed("\u{1b}]0;hello\u{07}\u{1b}]52;c;aGk=\u{07}")
        #expect(title == "hello")
        #expect(clipboard == "hi")
    }

    @Test(arguments: ["", "c", "p", "s"])
    func copiesEveryClipboardSelectionToThePasteboard(selection: String) {
        let terminal = VTTerminal(cols: 10, rows: 3)
        var clipboard: String?
        terminal.onClipboard = { clipboard = $0 }
        terminal.feed("\u{1b}]52;\(selection);aGk=\u{07}")
        #expect(clipboard == "hi")
    }

    @Test func readsOSC8HyperlinkTargets() {
        let terminal = VTTerminal(cols: 30, rows: 3)
        terminal.feed("see \u{1b}]8;;https://example.com/x\u{1b}\\docs\u{1b}]8;;\u{1b}\\ here")
        #expect(terminal.hyperlink(at: VTPoint(col: 5, row: 0), tag: .viewport) == "https://example.com/x")
        #expect(terminal.hyperlink(at: VTPoint(col: 1, row: 0), tag: .viewport) == nil)
    }

    @Test func declinesKittyGraphicsItCannotDraw() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        var replies: [UInt8] = []
        terminal.onWrite = { replies += $0 }
        terminal.feed("\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\")
        #expect(!String(decoding: replies, as: UTF8.self).contains("OK"))
    }

    @Test func answersDeviceQueries() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        var replies: [UInt8] = []
        terminal.onWrite = { replies += $0 }
        terminal.feed("\u{1b}[6n")
        #expect(String(decoding: replies, as: UTF8.self) == "\u{1b}[1;1R")
    }

    @Test func scrollsThroughHistory() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        terminal.feed((1...10).map { "line\($0)" }.joined(separator: "\r\n"))
        #expect(terminal.scrollbar.atBottom)
        #expect(terminal.scrollbar.canScroll)
        terminal.scroll(by: -2)
        #expect(!terminal.viewportAtBottom)
        #expect(terminal.lines(tag: .viewport)[0] == "line6")
        terminal.scrollToBottom()
        #expect(terminal.lines(tag: .viewport)[2] == "line10")
    }
}

struct VTScreenTests {
    @Test func snapshotsCellsColorsAndCursor() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        terminal.setColors(
            foreground: VTColor(r: 1, g: 2, b: 3), background: VTColor(r: 4, g: 5, b: 6), cursor: nil,
            palette: (0..<16).map { VTColor(r: UInt8($0), g: 0, b: 0) })
        terminal.feed("a\u{1b}[1;31mb\u{1b}[0m\u{1b}[7mc")
        #expect(terminal.updateScreen())
        let screen = terminal.screen
        #expect(screen.background == VTColor(r: 4, g: 5, b: 6))
        #expect(screen.cell(col: 0, row: 0).scalar == UInt32(("a" as Unicode.Scalar).value))
        #expect(screen.cell(col: 0, row: 0).fg == nil)
        #expect(screen.cell(col: 1, row: 0).fg == VTColor(r: 9, g: 0, b: 0))
        #expect(screen.cell(col: 1, row: 0).flags.contains(.bold))
        #expect(screen.cell(col: 2, row: 0).flags.contains(.inverse))
        #expect(screen.cursor.col == 3)
        #expect(screen.line(0).hasPrefix("abc"))
        #expect(screen.takeDirtyRows().contains(0))
        #expect(!terminal.updateScreen())
    }

    @Test func boldBasicColorsDrawBright() {
        let terminal = VTTerminal(cols: 10, rows: 1)
        terminal.setColors(
            foreground: VTColor(r: 1, g: 2, b: 3), background: VTColor(r: 4, g: 5, b: 6), cursor: nil,
            palette: (0..<16).map { VTColor(r: UInt8($0), g: 0, b: 0) })
        terminal.feed("\u{1b}[1;32ma\u{1b}[22mb\u{1b}[1;92mc\u{1b}[1;38;5;100md\u{1b}[1;38;2;7;8;9me")
        terminal.updateScreen()
        let screen = terminal.screen
        #expect(screen.cell(col: 0, row: 0).fg == VTColor(r: 10, g: 0, b: 0))
        #expect(screen.cell(col: 1, row: 0).fg == VTColor(r: 2, g: 0, b: 0))
        #expect(screen.cell(col: 2, row: 0).fg == VTColor(r: 10, g: 0, b: 0))
        #expect(screen.cell(col: 3, row: 0).fg != VTColor(r: 10, g: 0, b: 0))
        #expect(screen.cell(col: 4, row: 0).fg == VTColor(r: 7, g: 8, b: 9))
    }

    @Test func onlyChangedRowsAreDirty() {
        let terminal = VTTerminal(cols: 10, rows: 4)
        terminal.feed("one\r\ntwo")
        terminal.updateScreen()
        _ = terminal.screen.takeDirtyRows()
        terminal.feed("\u{1b}[4;1Hfour")
        #expect(terminal.updateScreen())
        let dirty = terminal.screen.takeDirtyRows()
        #expect(dirty.contains(3))
        #expect(!dirty.contains(0))
    }
}

struct VTSelectionTests {
    @Test func selectsAndCopiesRange() {
        let terminal = VTTerminal(cols: 20, rows: 3)
        terminal.feed("hello world\r\nsecond")
        terminal.select(VTSelection(start: VTPoint(col: 6, row: 0), end: VTPoint(col: 2, row: 1)))
        #expect(terminal.selectionText() == "world\nsec")
        #expect(terminal.selection == VTSelection(start: VTPoint(col: 6, row: 0), end: VTPoint(col: 2, row: 1)))
        terminal.clearSelection()
        #expect(terminal.selection == nil)
    }

    @Test func reversedSelectionIsOrdered() {
        let terminal = VTTerminal(cols: 20, rows: 3)
        terminal.feed("hello world")
        terminal.select(VTSelection(start: VTPoint(col: 4, row: 0), end: VTPoint(col: 0, row: 0)))
        #expect(terminal.selection?.start == VTPoint(col: 0, row: 0))
        #expect(terminal.selectionText() == "hello")
    }

    @Test func selectsWordAndLine() {
        let terminal = VTTerminal(cols: 20, rows: 3)
        terminal.feed("foo barbaz qux")
        #expect(terminal.selectWord(at: VTPoint(col: 6, row: 0)) != nil)
        #expect(terminal.selectionText() == "barbaz")
        terminal.selectLine(at: VTPoint(col: 1, row: 0))
        #expect(terminal.selectionText() == "foo barbaz qux")
    }

    @Test func copiedSelectionHasNoNUL() {
        let terminal = VTTerminal(cols: 20, rows: 3)
        terminal.feed("export\u{1b}[1CTART")
        terminal.select(VTSelection(start: VTPoint(col: 0, row: 0), end: VTPoint(col: 10, row: 0)))
        #expect(terminal.selectionText() == "export TART")
    }

    @Test func selectionRendersPerRow() {
        let terminal = VTTerminal(cols: 20, rows: 3)
        terminal.feed("hello world")
        terminal.select(VTSelection(start: VTPoint(col: 2, row: 0), end: VTPoint(col: 4, row: 0)))
        terminal.updateScreen()
        #expect(terminal.screen.selection[0] == 2...4)
        #expect(terminal.screen.selection[1] == nil)
    }
}

struct VTEncoderTests {
    @Test func arrowsFollowApplicationCursorMode() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        #expect(terminal.encodeKey(.up) == Array("\u{1b}[A".utf8))
        terminal.feed("\u{1b}[?1h")
        #expect(terminal.encodeKey(.up) == Array("\u{1b}OA".utf8))
    }

    @Test func controlLetterAndText() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        let c = VTKey(hidUsage: 0x06)!
        #expect(terminal.encodeKey(c, modifiers: .control, text: "c", unshifted: "c") == [0x03])
        #expect(terminal.encodeKey(c, text: "c", unshifted: "c") == Array("c".utf8))
        #expect(terminal.encodeKey(.enter, text: "\r") == [0x0d])
        #expect(terminal.encodeKey(.backspace) == [0x7f])
        #expect(terminal.encodeKey(.tab, modifiers: .shift) == Array("\u{1b}[Z".utf8))
    }

    @Test func kittyKeyboardProtocol() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        terminal.feed("\u{1b}[>1u")
        #expect(terminal.kittyKeyboardFlags == 1)
        #expect(terminal.encodeKey(.escape) == Array("\u{1b}[27u".utf8))
    }

    @Test func mouseReportsOnlyWhenTracking() {
        let terminal = VTTerminal(cols: 80, rows: 24)
        #expect(terminal.encodeMouse(button: .left, action: .press, col: 2, row: 3).isEmpty)
        terminal.feed("\u{1b}[?1000h\u{1b}[?1006h")
        #expect(terminal.encodeMouse(button: .left, action: .press, col: 2, row: 3) == Array("\u{1b}[<0;3;4M".utf8))
        #expect(terminal.encodeMouse(button: .left, action: .release, col: 2, row: 3) == Array("\u{1b}[<0;3;4m".utf8))
        #expect(terminal.encodeMouse(button: .wheelUp, action: .press, col: 0, row: 0) == Array("\u{1b}[<64;1;1M".utf8))
    }

    @Test func dragReportsInButtonMode() {
        let terminal = VTTerminal(cols: 80, rows: 24)
        terminal.feed("\u{1b}[?1002h\u{1b}[?1006h")
        _ = terminal.encodeMouse(button: .left, action: .press, col: 1, row: 1)
        #expect(terminal.encodeMouse(button: .left, action: .motion, col: 5, row: 1) == Array("\u{1b}[<32;6;2M".utf8))
    }

    @Test func focusEvents() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        #expect(terminal.encodeFocus(true) == Array("\u{1b}[I".utf8))
        #expect(terminal.encodeFocus(false) == Array("\u{1b}[O".utf8))
    }

    @Test func mapsHidUsages() {
        #expect(VTKey(hidUsage: 0x04) == VTKey(hidUsage: 0x04))
        #expect(VTKey(hidUsage: 0x52) == .up)
        #expect(VTKey(hidUsage: 0x29) == .escape)
        #expect(VTKey(hidUsage: 0xe0)?.isModifier == true)
        #expect(VTKey(hidUsage: 0x02) == nil)
    }
}

struct VTWrapTests {
    @Test func softWrappedRowsReportContinuation() {
        let terminal = VTTerminal(cols: 5, rows: 3)
        terminal.feed("abcdefgh\r\nxy")
        #expect(terminal.lineWrapped(row: 0))
        #expect(!terminal.lineIsContinuation(row: 0))
        #expect(terminal.lineIsContinuation(row: 1))
        #expect(!terminal.lineIsContinuation(row: 2))
    }
}

struct VTDirtyTests {
    @Test func selectionChangesMarkRowsDirty() {
        let terminal = VTTerminal(cols: 20, rows: 3)
        terminal.feed("hello\r\nworld")
        terminal.updateScreen()
        _ = terminal.screen.takeDirtyRows()
        terminal.select(VTSelection(start: VTPoint(col: 0, row: 1), end: VTPoint(col: 2, row: 1)))
        #expect(terminal.updateScreen())
        #expect(terminal.screen.takeDirtyRows().contains(1))
        #expect(terminal.screen.selection[1] == 0...2)
        terminal.clearSelection()
        #expect(terminal.updateScreen())
        #expect(terminal.screen.selection[1] == nil)
    }

    @Test func scrollingRedrawsTheViewport() {
        let terminal = VTTerminal(cols: 10, rows: 3)
        terminal.feed((1...10).map { "l\($0)" }.joined(separator: "\r\n"))
        terminal.updateScreen()
        _ = terminal.screen.takeDirtyRows()
        terminal.scroll(by: -3)
        #expect(terminal.updateScreen())
        #expect(terminal.screen.takeDirtyRows().count == 3)
        #expect(terminal.screen.line(0).hasPrefix("l5"))
    }
}
