#if os(iOS)
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers

    struct PasteKey: UIViewRepresentable {
        let background: UIColor
        let foreground: UIColor
        let border: UIColor
        let onPaste: ([NSItemProvider]) -> Void

        func makeUIView(context: Context) -> PasteKeyView { PasteKeyView() }

        func updateUIView(_ view: PasteKeyView, context: Context) {
            view.onPaste = onPaste
            view.style(background: background, foreground: foreground, border: border)
        }
    }

    final class PasteKeyView: UIView {
        var onPaste: (([NSItemProvider]) -> Void)?
        private(set) var control: UIPasteControl?

        init() {
            super.init(frame: .zero)
            pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
                UTType.image.identifier, UTType.text.identifier,
            ])
            layer.cornerRadius = 8
            layer.borderWidth = 1
        }

        required init?(coder: NSCoder) { nil }

        override func paste(itemProviders: [NSItemProvider]) {
            onPaste?(itemProviders)
        }

        func style(background: UIColor, foreground: UIColor, border: UIColor) {
            backgroundColor = background
            layer.borderColor = border.cgColor
            if let current = control?.configuration,
                current.baseBackgroundColor == background, current.baseForegroundColor == foreground
            {
                return
            }
            control?.removeFromSuperview()
            let configuration = UIPasteControl.Configuration()
            configuration.displayMode = .iconOnly
            configuration.cornerStyle = .fixed
            configuration.cornerRadius = 7
            configuration.baseBackgroundColor = background
            configuration.baseForegroundColor = foreground
            let control = UIPasteControl(configuration: configuration)
            control.target = self
            control.traitOverrides.preferredContentSizeCategory = .extraSmall
            control.accessibilityIdentifier = "terminal.clipboard"
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .vertical)
            addSubview(control)
            let fill = [
                control.widthAnchor.constraint(equalTo: widthAnchor, constant: -2),
                control.heightAnchor.constraint(equalTo: heightAnchor, constant: -2),
            ]
            fill.forEach { $0.priority = .defaultHigh - 1 }
            NSLayoutConstraint.activate(
                fill + [
                    control.centerXAnchor.constraint(equalTo: centerXAnchor),
                    control.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            self.control = control
        }
    }
#endif
