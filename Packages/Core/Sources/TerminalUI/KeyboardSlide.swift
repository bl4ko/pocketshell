import CoreGraphics

public struct CaretPlacement: Equatable, Sendable {
    public var top: CGFloat
    public var lineHeight: CGFloat
    public var viewHeight: CGFloat

    public init(top: CGFloat, lineHeight: CGFloat, viewHeight: CGFloat) {
        self.top = top
        self.lineHeight = lineHeight
        self.viewHeight = viewHeight
    }
}

/// Slides an unresized terminal only as far as its parked caret needs, and holds while the caret stays visible.
public struct KeyboardSlide: Equatable {
    public static let rowsBelow: CGFloat = 3
    public static let rowsAbove: CGFloat = 1

    public private(set) var reach: CGFloat?
    private var caret: CaretPlacement?
    private var keyboard: CGFloat = 0

    public init() {}

    public mutating func follow(_ caret: CaretPlacement?, keyboard: CGFloat) {
        let opening = keyboard > 0 && self.keyboard <= 0
        self.keyboard = keyboard
        if let caret { self.caret = caret }
        guard let caret = self.caret, keyboard > 0 else { return }
        let low = caret.top + caret.lineHeight * (1 + Self.rowsBelow)
        guard !opening, let reach else {
            reach = low
            return
        }
        let high = caret.top - caret.lineHeight * Self.rowsAbove + caret.viewHeight - keyboard
        self.reach = min(max(reach, low), max(low, high))
    }

    public func offset(keyboard shown: CGFloat) -> CGFloat {
        guard shown > 0 else { return 0 }
        guard let reach, let caret else { return shown }
        return min(max(reach - (caret.viewHeight - shown), 0), shown)
    }
}
