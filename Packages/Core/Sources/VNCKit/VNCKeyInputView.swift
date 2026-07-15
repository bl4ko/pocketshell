#if os(iOS)
    import SwiftUI
    import UIKit

    public struct VNCKeyInputView<Accessory: View>: UIViewRepresentable {
        @Binding var focused: Bool
        let onInsert: (String) -> Void
        let onDelete: () -> Void
        let accessory: Accessory

        public init(
            focused: Binding<Bool>,
            onInsert: @escaping (String) -> Void,
            onDelete: @escaping () -> Void,
            @ViewBuilder accessory: () -> Accessory
        ) {
            _focused = focused
            self.onInsert = onInsert
            self.onDelete = onDelete
            self.accessory = accessory()
        }

        public func makeUIView(context: Context) -> KeyInputUIView {
            let view = KeyInputUIView()
            view.onInsert = onInsert
            view.onDelete = onDelete
            view.onFocusChange = { isFocused in
                DispatchQueue.main.async {
                    if focused != isFocused {
                        focused = isFocused
                    }
                }
            }
            let host = UIHostingController(rootView: accessory)
            host.view.frame = CGRect(x: 0, y: 0, width: 0, height: 48)
            host.view.autoresizingMask = .flexibleWidth
            host.view.backgroundColor = .clear
            context.coordinator.host = host
            view.accessory = host.view
            return view
        }

        public func updateUIView(_ view: KeyInputUIView, context: Context) {
            view.onInsert = onInsert
            view.onDelete = onDelete
            context.coordinator.host?.rootView = accessory
            if focused, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if !focused, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        public final class Coordinator {
            var host: UIHostingController<Accessory>?
        }
    }

    public final class KeyInputUIView: UIView, UIKeyInput {
        var onInsert: ((String) -> Void)?
        var onDelete: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var accessory: UIView?

        public override var canBecomeFirstResponder: Bool { true }
        public override var inputAccessoryView: UIView? { accessory }

        public var hasText: Bool { true }
        public var autocorrectionType: UITextAutocorrectionType {
            get { .no }
            set {}
        }
        public var autocapitalizationType: UITextAutocapitalizationType {
            get { .none }
            set {}
        }
        public var spellCheckingType: UITextSpellCheckingType {
            get { .no }
            set {}
        }
        public var smartQuotesType: UITextSmartQuotesType {
            get { .no }
            set {}
        }
        public var smartDashesType: UITextSmartDashesType {
            get { .no }
            set {}
        }
        public var smartInsertDeleteType: UITextSmartInsertDeleteType {
            get { .no }
            set {}
        }
        public var keyboardAppearance: UIKeyboardAppearance {
            get { .dark }
            set {}
        }

        public func insertText(_ text: String) {
            onInsert?(text)
        }

        public func deleteBackward() {
            onDelete?()
        }

        @discardableResult
        public override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result {
                onFocusChange?(true)
            }
            return result
        }

        @discardableResult
        public override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result {
                onFocusChange?(false)
            }
            return result
        }
    }
#endif
