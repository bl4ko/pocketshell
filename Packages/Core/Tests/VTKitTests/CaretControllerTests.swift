import Testing

@testable import VTKit

struct CaretSettleGateTests {
    @Test func firstUnaddressedPositionMustSettle() {
        var gate = CaretSettleGate(settleDelay: 0.25)
        #expect(gate.evaluate(row: 20, addressed: false, lastFeed: 1.0, now: 1.0) == .wait(0.25))
        #expect(gate.evaluate(row: 20, addressed: false, lastFeed: 1.0, now: 1.25) == .commit)
    }

    @Test func sameRowCommitsDuringActiveStream() {
        var gate = CaretSettleGate(settleDelay: 0.25)
        _ = gate.evaluate(row: 20, addressed: true, lastFeed: 1.0, now: 1.0)
        #expect(gate.evaluate(row: 20, addressed: false, lastFeed: 1.02, now: 1.02) == .commit)
    }

    @Test func addressedRowChangeCommitsImmediately() {
        var gate = CaretSettleGate(settleDelay: 0.25)
        _ = gate.evaluate(row: 20, addressed: true, lastFeed: 1.0, now: 1.0)
        #expect(gate.evaluate(row: 45, addressed: true, lastFeed: 1.01, now: 1.01) == .commit)
    }

    @Test func hideWaitsForQuietButShowCommitsImmediately() {
        var gate = CaretSettleGate(settleDelay: 0.25)
        _ = gate.evaluate(row: 20, addressed: true, lastFeed: 1.0, now: 1.0)
        #expect(gate.evaluate(row: 20, addressed: true, hidden: true, lastFeed: 1.01, now: 1.01) == .wait(0.25))
        #expect(gate.evaluate(row: 20, addressed: true, hidden: true, lastFeed: 1.01, now: 1.26) == .commit)
        #expect(gate.evaluate(row: 20, addressed: true, hidden: false, lastFeed: 1.27, now: 1.27) == .commit)
    }

    @Test func midFramePieceNeverCommitsDuringPause() {
        var gate = CaretSettleGate(settleDelay: 0.25)
        _ = gate.evaluate(row: 40, addressed: true, lastFeed: 1.0, now: 1.0)
        var t = 1.0
        for _ in 0..<20 {
            t += 0.1
            guard case .wait = gate.evaluate(row: 29, addressed: false, lastFeed: t, now: t) else {
                Issue.record("mid-frame park must not commit while the stream is active")
                return
            }
            t += 0.1
            #expect(gate.evaluate(row: 40, addressed: true, lastFeed: t, now: t) == .commit)
        }
    }
}

struct CaretControllerTests {
    @Test func plainShellHidesImmediately() {
        var caret = CaretController()
        _ = caret.update(row: 3, col: 4, hidden: false, addressed: true, cell: 0, previousCell: 0, now: 1)
        #expect(caret.update(row: 3, col: 4, hidden: true, addressed: true, cell: 0, previousCell: 0, now: 1) == .hide)
    }

    @Test func multiplexerHoldsCaretThroughHideTransaction() {
        var caret = CaretController()
        caret.multiplexer = true
        #expect(
            caret.update(row: 3, col: 4, hidden: false, addressed: true, cell: 0, previousCell: 0, now: 1)
                == .show(row: 3, col: 4))
        caret.noteFeed(at: 1.01, sawHide: true)
        guard
            case .hold = caret.update(
                row: 3, col: 4, hidden: true, addressed: true, cell: 0, previousCell: 0, now: 1.01)
        else {
            Issue.record("a hide during a multiplexer redraw must keep the caret painted")
            return
        }
        caret.noteFeed(at: 1.05, sawHide: false)
        #expect(
            caret.update(row: 0, col: 0, hidden: false, addressed: false, cell: 0, previousCell: 0, now: 1.05)
                == .show(row: 0, col: 0))
    }

    @Test func paneDividerAnchorsDoNotCountAsParks() {
        var caret = CaretController()
        caret.multiplexer = true
        _ = caret.update(row: 10, col: 5, hidden: false, addressed: true, cell: 0, previousCell: 0, now: 1)
        caret.noteFeed(at: 1.01, sawHide: false)
        guard
            case .hold = caret.update(
                row: 4, col: 41, hidden: false, addressed: true, cell: 0x2502, previousCell: 0, now: 1.01)
        else {
            Issue.record("a cursor parked on a pane divider is mid-repaint")
            return
        }
    }

    @Test func unaddressedNewlineCommitsAfterQuiet() {
        var caret = CaretController()
        caret.multiplexer = true
        _ = caret.update(row: 10, col: 5, hidden: false, addressed: true, cell: 0, previousCell: 0, now: 1)
        caret.noteFeed(at: 1.0, sawHide: false)
        #expect(
            caret.update(row: 11, col: 2, hidden: false, addressed: false, cell: 0, previousCell: 0, now: 1.3)
                == .show(row: 11, col: 2))
    }
}
