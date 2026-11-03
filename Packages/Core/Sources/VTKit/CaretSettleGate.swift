import Foundation

public struct CaretSettleGate: Sendable {
    public enum Decision: Equatable, Sendable {
        case commit
        case wait(TimeInterval)
    }

    public var settleDelay: TimeInterval
    private var committedRow: Int?
    private var committedHidden = false

    public init(settleDelay: TimeInterval = 0.25) {
        self.settleDelay = settleDelay
    }

    public mutating func evaluate(
        row: Int, addressed: Bool, hidden: Bool = false, lastFeed: TimeInterval, now: TimeInterval
    ) -> Decision {
        if hidden != committedHidden {
            let quietTime = now - lastFeed
            if hidden && quietTime < settleDelay {
                return .wait(settleDelay - quietTime)
            }
            committedHidden = hidden
        }
        if hidden {
            return .commit
        }
        if addressed || row == committedRow || now - lastFeed >= settleDelay {
            committedRow = row
            return .commit
        }
        return .wait(settleDelay - (now - lastFeed))
    }

    public mutating func reset() {
        committedRow = nil
        committedHidden = false
    }
}
