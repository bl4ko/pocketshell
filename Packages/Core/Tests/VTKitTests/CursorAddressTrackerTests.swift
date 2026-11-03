import Testing

@testable import VTKit

struct CursorAddressTrackerTests {
    private func addressed(after text: String, from start: Bool = false) -> Bool {
        var tracker = CursorAddressTracker()
        if start { tracker.scan(Array("\u{1b}[5;5H".utf8)) }
        tracker.scan(Array(text.utf8))
        return tracker.addressed
    }

    @Test func cupAndHvpAddress() {
        #expect(addressed(after: "\u{1b}[3;4H"))
        #expect(addressed(after: "\u{1b}[H"))
        #expect(addressed(after: "\u{1b}[2;2f"))
    }

    @Test func textAndRelativeMovesDropTheAddress() {
        #expect(!addressed(after: "x", from: true))
        #expect(!addressed(after: "\r\n", from: true))
        #expect(!addressed(after: "\u{1b}[2A", from: true))
        #expect(!addressed(after: "\u{1b}[5G", from: true))
        #expect(!addressed(after: "\u{1b}[7d", from: true))
        #expect(!addressed(after: "\u{1b}8", from: true))
        #expect(!addressed(after: "\u{1b}M", from: true))
        #expect(!addressed(after: "é", from: true))
    }

    @Test func modesStylesAndStringsKeepTheAddress() {
        #expect(addressed(after: "\u{1b}[?25h\u{1b}[1;31m\u{1b}[K\u{1b}[2J", from: true))
        #expect(addressed(after: "\u{1b}]0;title with text\u{07}", from: true))
        #expect(addressed(after: "\u{1b}]2;x\u{1b}\\", from: true))
        #expect(addressed(after: "\u{1b}7\u{1b}[ q", from: true))
    }

    @Test func lastMoveInChunkWins() {
        #expect(addressed(after: "hello\u{1b}[1;1H"))
        #expect(!addressed(after: "\u{1b}[1;1Hhello"))
    }

    @Test func sequenceSplitAcrossChunksStillAddresses() {
        var tracker = CursorAddressTracker()
        tracker.scan(Array("abc\u{1b}[1".utf8))
        tracker.scan(Array(";1H".utf8))
        #expect(tracker.addressed)
    }

    @Test func recordsCursorHideWithinChunk() {
        var tracker = CursorAddressTracker()
        tracker.beginChunk()
        tracker.scan(Array("\u{1b}[?25l".utf8))
        #expect(tracker.sawHide)
        tracker.beginChunk()
        tracker.scan(Array("\u{1b}[?1049;25l".utf8))
        #expect(tracker.sawHide)
        tracker.beginChunk()
        tracker.scan(Array("\u{1b}[?2025l\u{1b}[?25h".utf8))
        #expect(!tracker.sawHide)
    }
}
