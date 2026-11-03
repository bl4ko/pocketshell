#if os(iOS)
    import UIKit

    /// Marked text never reaches the host or the renderer, so the composition is drawn here at the caret.
    final class IMECompositionView: UIView {
        private let label = UILabel()

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingHead
            addSubview(label)
            // Terminal content is not accessibility-visible, so this is the only handle
            // a UI test has on what an IME is composing.
            isAccessibilityElement = true
            accessibilityIdentifier = "terminal.composition"
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("not used from a storyboard")
        }

        func update(
            text: String, clause: NSRange, font: UIFont, foreground: UIColor, background: UIColor, caret: CGRect,
            visible: CGRect
        ) {
            accessibilityValue = text
            guard !text.isEmpty else {
                isHidden = true
                label.attributedText = nil
                return
            }
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: foreground,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: foreground,
                ]
            )
            // The IME marks the clause it is currently converting; iOS text fields show it
            // with a heavier underline, and CJK users read that to know what Enter commits.
            let full = NSRange(location: 0, length: attributed.length)
            if clause.length > 0, NSIntersectionRange(clause, full) == clause {
                attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: clause)
            }
            label.attributedText = attributed
            let size = attributed.size()
            frame = IMECompositionLayout.frame(
                caret: caret,
                textWidth: ceil(size.width),
                textHeight: ceil(size.height),
                visible: visible
            )
            label.frame = bounds
            // Opaque, so the glyphs the composition sits on top of do not show through.
            backgroundColor = background
            isHidden = false
        }
    }
#endif
