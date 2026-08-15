#if os(iOS)
    import SwiftTerm
    import UIKit

    /// Draws the in-progress IME composition inline at the caret.
    ///
    /// SwiftTerm keeps marked text in its own storage and sends nothing to the host until
    /// the input method commits it, and it never draws that text — so Korean, Japanese and
    /// Chinese keyboards otherwise compose invisibly and only the committed result appears.
    /// The fork calls `markedTextObserver` on every composition change; this view renders it
    /// underlined over the caret cell, the way a native text field does.
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

        func update(text: String, clause: NSRange, in view: TerminalView) {
            accessibilityValue = text
            guard !text.isEmpty else {
                isHidden = true
                label.attributedText = nil
                return
            }
            let foreground = view.nativeForegroundColor
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: view.font,
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
                caret: view.caretFrame,
                textWidth: ceil(size.width),
                textHeight: ceil(size.height),
                visible: view.bounds
            )
            label.frame = bounds
            // Opaque, so the glyphs the composition sits on top of do not show through.
            backgroundColor = view.nativeBackgroundColor
            isHidden = false
        }
    }
#endif
