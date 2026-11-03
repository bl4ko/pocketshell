import Foundation
import Testing
import VTKit

@testable import TerminalUI

struct TextInputDocumentTests {
    @Test func typingSendsTextAndKeepsContext() {
        var document = TextInputDocument()
        #expect(document.insert("ab") == [.text("ab")])
        #expect(document.storage == "ab")
        #expect(document.deleteBackward() == [.backspaces(1)])
        #expect(document.storage == "a")
    }

    @Test func markedTextNeverReachesTheHostUntilCommitted() {
        var document = TextInputDocument()
        document.setMarked("n", selectedRange: NSRange(location: 1, length: 0))
        document.setMarked("に", selectedRange: NSRange(location: 1, length: 0))
        #expect(document.markedText == "に")
        #expect(document.unmark() == [.text("に")])
        #expect(document.markedRange == nil)
    }

    @Test func insertReplacesMarkedText() {
        var document = TextInputDocument()
        _ = document.insert("x")
        document.setMarked("にほ", selectedRange: NSRange(location: 2, length: 0))
        #expect(document.insert("日本") == [.text("日本")])
        #expect(document.storage == "x日本")
    }

    @Test func deleteInsideCompositionStaysLocal() {
        var document = TextInputDocument()
        document.setMarked("にほ", selectedRange: NSRange(location: 2, length: 0))
        #expect(document.deleteBackward() == [])
        #expect(document.markedText == "に")
    }

    @Test func replacementBackspacesTheTail() {
        var document = TextInputDocument()
        _ = document.insert("teh ")
        #expect(document.replace(0..<3, with: "the") == [.backspaces(4), .text("the ")])
        #expect(document.storage == "the ")
    }

    @Test func koreanSyllableAssemblyRewritesTheLastCharacter() {
        var document = TextInputDocument()
        _ = document.insert("ㅎ")
        #expect(document.deleteBackward() == [.backspaces(1)])
        #expect(document.insert("하") == [.text("하")])
        #expect(document.storage == "하")
    }

    @Test func newlineResetsTheDocument() {
        var document = TextInputDocument()
        _ = document.insert("ls")
        _ = document.insert("\n")
        #expect(document.storage.isEmpty)
        #expect(document.deleteBackward() == [.backspaces(1)])
    }

    @Test func handleGrabKeepsTouchToHandleOffset() {
        let grab = HandleGrabMath.grab(
            point: CGPoint(x: 21, y: 9), start: (col: 2, row: 1), end: (col: 5, row: 1), cellWidth: 10,
            cellHeight: 20, slop: 30)
        #expect(grab?.handle == .start)
        #expect(grab?.colOffset == 0)
        #expect(grab?.rowOffset == 1)
        let end = HandleGrabMath.grab(
            point: CGPoint(x: 62, y: 41), start: (col: 2, row: 1), end: (col: 5, row: 1), cellWidth: 10,
            cellHeight: 20, slop: 30)
        #expect(end?.handle == .end)
        #expect(end?.colOffset == -1)
        #expect(end?.rowOffset == -1)
        #expect(
            HandleGrabMath.grab(
                point: CGPoint(x: 300, y: 300), start: (col: 2, row: 1), end: (col: 5, row: 1), cellWidth: 10,
                cellHeight: 20, slop: 30) == nil)
    }
}

struct SplitPaneTests {
    @Test func detectsTmuxVerticalSplit() {
        let terminal = VTKit.VTTerminal(cols: 20, rows: 6)
        terminal.feed(Array(repeating: "left     │right", count: 6).joined(separator: "\r\n"))
        terminal.updateScreen()
        #expect(SplitPanes.hasVerticalDivider(terminal.screen))
    }

    @Test func ignoresStrayDividers() {
        let terminal = VTKit.VTTerminal(cols: 20, rows: 6)
        terminal.feed("a │ b\r\nplain\r\nplain")
        terminal.updateScreen()
        #expect(!SplitPanes.hasVerticalDivider(terminal.screen))
    }

    @Test func rectangularCopyTakesOnePane() {
        let terminal = VTKit.VTTerminal(cols: 20, rows: 3)
        terminal.feed("ab   │cd\r\nef   │gh")
        terminal.select(
            VTKit.VTSelection(start: VTKit.VTPoint(col: 0, row: 0), end: VTKit.VTPoint(col: 1, row: 1), rectangle: true)
        )
        #expect(terminal.selectionText() == "ab\nef")
    }
}
