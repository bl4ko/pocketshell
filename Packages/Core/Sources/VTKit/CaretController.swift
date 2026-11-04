import Foundation

public struct CaretController: Sendable {
    public enum Update: Equatable, Sendable {
        case show(row: Int, col: Int)
        case hide
        case hold(TimeInterval)
    }

    public var multiplexer = false
    public private(set) var parkedRow: Int?
    public private(set) var parkWait: TimeInterval?
    private var gate = CaretSettleGate()
    private var park = CaretSettleGate()
    private var hidePending = false
    private var frameEnded = false
    private var lastFeed: TimeInterval = 0

    public init() {}

    public mutating func noteFeed(at time: TimeInterval, sawHide: Bool, sawSyncEnd: Bool = false) {
        lastFeed = time
        if multiplexer, sawHide {
            hidePending = true
        }
        if sawSyncEnd {
            frameEnded = true
        }
    }

    public mutating func reset() {
        gate.reset()
        park.reset()
        parkedRow = nil
        parkWait = nil
        hidePending = false
        frameEnded = false
    }

    public mutating func update(
        row: Int, col: Int, hidden: Bool, addressed: Bool, cell: UInt32, previousCell: UInt32,
        now: TimeInterval
    ) -> Update {
        let divider: UInt32 = 0x2502
        let redrawAnchor = col == 0 || cell == divider || previousCell == divider
        let restoredAfterHide = (hidePending || frameEnded) && !hidden
        let parked = restoredAfterHide || (addressed && !redrawAnchor)
        let decision = gate.evaluate(
            row: row, addressed: parked, hidden: hidden, lastFeed: redrawAnchor && !hidden ? now : lastFeed, now: now)
        notePark(row: row, addressed: parked, redrawAnchor: redrawAnchor, now: now)
        if !multiplexer, hidden {
            return .hide
        }
        switch decision {
        case .commit:
            if restoredAfterHide {
                hidePending = false
                frameEnded = false
            }
            return hidden ? .hide : .show(row: row, col: col)
        case .wait(let remaining):
            return .hold(remaining)
        }
    }

    // TUIs such as Claude Code hide the cursor but still park it on their input line.
    private mutating func notePark(row: Int, addressed: Bool, redrawAnchor: Bool, now: TimeInterval) {
        parkWait = nil
        guard !redrawAnchor else { return }
        switch park.evaluate(row: row, addressed: addressed, lastFeed: lastFeed, now: now) {
        case .commit: parkedRow = row
        case .wait(let remaining): parkWait = remaining
        }
    }
}
