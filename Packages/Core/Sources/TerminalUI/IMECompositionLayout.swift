import CoreGraphics

/// Where the inline IME composition is drawn, relative to the caret.
///
/// ponytail: one line, shifted left to fit, never wrapped — a composition wider than the
/// screen is rare, and its tail is the part being edited. Wrap it if that stops holding.
enum IMECompositionLayout {
    static func frame(caret: CGRect, textWidth: CGFloat, textHeight: CGFloat, visible: CGRect) -> CGRect {
        let width = min(textWidth, visible.width)
        let x = min(max(caret.minX, visible.minX), visible.maxX - width)
        return CGRect(x: x, y: caret.minY, width: width, height: max(caret.height, textHeight))
    }
}
