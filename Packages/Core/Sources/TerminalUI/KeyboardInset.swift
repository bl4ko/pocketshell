import CoreGraphics

/// Terminal layout follows the keyboard with one resize: growing commits at once and the
/// larger view slides down behind the keyboard, shrinking waits until the keyboard has
/// arrived so the content rides up with it instead of jumping ahead.
public struct KeyboardInset: Equatable {
    public private(set) var layout: CGFloat
    public private(set) var target: CGFloat

    public init(_ inset: CGFloat = 0) {
        layout = inset
        target = inset
    }

    public mutating func move(to inset: CGFloat) {
        target = inset
        layout = min(layout, inset)
    }

    public mutating func settle(_ inset: CGFloat) {
        if inset == target { layout = inset }
    }

    public static func animates(
        from old: (inset: CGFloat, active: Bool), to new: (inset: CGFloat, active: Bool)
    ) -> Bool {
        old.active && new.active && old.inset != new.inset
    }
}
