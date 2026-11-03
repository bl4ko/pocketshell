import Foundation

public struct CaretController: Sendable {
    public enum Update: Equatable, Sendable {
        case show(row: Int, col: Int)
        case hide
        case hold(TimeInterval)
    }

    public var multiplexer = false
    private var gate = CaretSettleGate()
    private var hidePending = false
    private var lastFeed: TimeInterval = 0

    public init() {}

    public mutating func noteFeed(at time: TimeInterval, sawHide: Bool) {
        lastFeed = time
        if multiplexer, sawHide {
            hidePending = true
        }
    }

    public mutating func reset() {
        gate.reset()
        hidePending = false
    }

    public mutating func update(
        row: Int, col: Int, hidden: Bool, addressed: Bool, cell: UInt32, previousCell: UInt32,
        now: TimeInterval
    ) -> Update {
        let divider: UInt32 = 0x2502
        let redrawAnchor = col == 0 || cell == divider || previousCell == divider
        let restoredAfterHide = hidePending && !hidden
        let decision = gate.evaluate(
            row: row, addressed: restoredAfterHide || (addressed && !redrawAnchor), hidden: hidden,
            lastFeed: redrawAnchor && !hidden ? now : lastFeed, now: now)
        if !multiplexer, hidden {
            return .hide
        }
        switch decision {
        case .commit:
            if restoredAfterHide {
                hidePending = false
            }
            return hidden ? .hide : .show(row: row, col: col)
        case .wait(let remaining):
            return .hold(remaining)
        }
    }
}
