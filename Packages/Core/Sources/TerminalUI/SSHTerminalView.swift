#if os(iOS)
    import Models
    import SwiftUI
    import ToolbarUI
    import UIKit

    final class TerminalViewController: UIViewController {
        let terminalView = GhosttyTerminalView()
        var sendControl: ((Character) -> Void)?
        var sendEscape: (() -> Void)?
        var sendBytes: ((Data) -> Void)?
        #if !targetEnvironment(macCatalyst)
            private(set) var shortcutHost: UIHostingController<ShortcutPanel>?
            private(set) var shortcutRenderCount = 0
            let shortcutInput = UIInputView(
                frame: CGRect(x: 0, y: 0, width: 0, height: 260), inputViewStyle: .keyboard)

            private struct ShortcutInputs: Equatable {
                var keys: [ToolbarKey]
                var theme: TerminalTheme
                var multiplexer: Bool
                var category: ShortcutCategory
            }
            private var shortcutInputs: ShortcutInputs?
            private static var typingKeyboardHeight: CGFloat = 260

            override func viewDidLoad() {
                super.viewDidLoad()
                NotificationCenter.default.addObserver(
                    self, selector: #selector(keyboardDidChangeFrame(_:)),
                    name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
            }

            @objc private func keyboardDidChangeFrame(_ note: Notification) {
                guard terminalView.customInputView == nil, terminalView.isFirstResponder,
                    let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                    let screen = view.window?.windowScene?.screen, frame.minY < screen.bounds.maxY,
                    frame.height > 150  // ponytail: skips the hardware-keyboard bar
                else { return }
                Self.typingKeyboardHeight = frame.height
            }

            func updateShortcuts(bridge: TerminalBridge, keys: [ToolbarKey], theme: TerminalTheme) {
                let inputs = ShortcutInputs(
                    keys: keys, theme: theme, multiplexer: terminalView.multiplexerMode,
                    category: bridge.shortcutCategory)
                if inputs != shortcutInputs {
                    shortcutInputs = inputs
                    renderShortcuts(bridge: bridge, keys: keys, theme: theme)
                }
                let input: UIView? = bridge.shortcutsActive ? shortcutInput : nil
                if terminalView.customInputView !== input {
                    // UIKit posts no show for the keyboard replacing a same-height panel, only the panel's hide.
                    let hold = input == nil && terminalView.isFirstResponder ? Self.typingKeyboardHeight : nil
                    if bridge.keyboardHold != hold { bridge.keyboardHold = hold }
                    shortcutInput.frame.size.height = Self.typingKeyboardHeight
                    terminalView.customInputView = input
                    terminalView.reloadInputViews()
                }
            }

            private func renderShortcuts(bridge: TerminalBridge, keys: [ToolbarKey], theme: TerminalTheme) {
                shortcutRenderCount += 1
                let panel = ShortcutPanel(
                    theme: theme,
                    userKeys: keys,
                    multiplexer: terminalView.multiplexerMode,
                    onKey: { [weak bridge] in bridge?.handleToolbar($0) },
                    onClose: { [weak bridge] in bridge?.showTypingKeyboard() },
                    category: Binding(
                        get: { bridge.shortcutCategory },
                        set: { bridge.selectShortcutCategory($0) }
                    )
                )
                if let shortcutHost {
                    shortcutHost.rootView = panel
                } else {
                    let host = UIHostingController(rootView: panel)
                    shortcutHost = host
                    // UIKit installs input views in its keyboard window, outside this controller's hierarchy.
                    host.view.backgroundColor = .clear
                    host.view.translatesAutoresizingMaskIntoConstraints = false
                    shortcutInput.addSubview(host.view)
                    NSLayoutConstraint.activate([
                        host.view.leadingAnchor.constraint(equalTo: shortcutInput.leadingAnchor),
                        host.view.trailingAnchor.constraint(equalTo: shortcutInput.trailingAnchor),
                        host.view.topAnchor.constraint(equalTo: shortcutInput.topAnchor),
                        host.view.bottomAnchor.constraint(equalTo: shortcutInput.safeAreaLayoutGuide.bottomAnchor),
                    ])
                }
            }
        #endif

        override func loadView() {
            view = terminalView
        }

        #if targetEnvironment(macCatalyst)
            func installControlKeyCommands() {
                for character in "abcdefghijklmnopqrstuvwxyz" {
                    let command = UIKeyCommand(
                        input: String(character),
                        modifierFlags: .control,
                        action: #selector(handleControl(_:))
                    )
                    command.wantsPriorityOverSystemBehavior = true
                    addKeyCommand(command)
                }
                let copyCommand = UIKeyCommand(
                    input: "c",
                    modifierFlags: .command,
                    action: #selector(handleCopy)
                )
                copyCommand.wantsPriorityOverSystemBehavior = true
                addKeyCommand(copyCommand)
                let pasteCommand = UIKeyCommand(
                    input: "v",
                    modifierFlags: .command,
                    action: #selector(handlePaste)
                )
                pasteCommand.wantsPriorityOverSystemBehavior = true
                addKeyCommand(pasteCommand)
                let escapeCommand = UIKeyCommand(
                    input: UIKeyCommand.inputEscape,
                    modifierFlags: [],
                    action: #selector(handleEscape)
                )
                escapeCommand.wantsPriorityOverSystemBehavior = true
                addKeyCommand(escapeCommand)
                // Catalyst's focus engine eats shift+tab before the terminal sees it.
                let backTabCommand = UIKeyCommand(
                    input: "\t",
                    modifierFlags: .shift,
                    action: #selector(handleBackTab)
                )
                backTabCommand.wantsPriorityOverSystemBehavior = true
                addKeyCommand(backTabCommand)
                for arrow in [
                    UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
                    UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
                ] {
                    let command = UIKeyCommand(
                        input: arrow,
                        modifierFlags: [],
                        action: #selector(handleArrow(_:))
                    )
                    command.wantsPriorityOverSystemBehavior = true
                    addKeyCommand(command)
                }
            }

            @objc private func handleControl(_ command: UIKeyCommand) {
                if let character = command.input?.first {
                    sendControl?(character)
                }
            }

            @objc private func handleCopy() {
                guard terminalView.selectionActive else { return }
                terminalView.copySelectionToPasteboard()
            }

            @objc private func handlePaste() {
                terminalView.paste(nil)
            }

            @objc private func handleEscape() {
                sendEscape?()
            }

            @objc private func handleBackTab() {
                sendBytes?(Data("\u{1b}[Z".utf8))
            }

            // pressesBegan repeats on a fixed timer; UIKeyCommand follows the system key-repeat rate.
            @objc private func handleArrow(_ command: UIKeyCommand) {
                let letter: String
                switch command.input {
                case UIKeyCommand.inputUpArrow: letter = "A"
                case UIKeyCommand.inputDownArrow: letter = "B"
                case UIKeyCommand.inputRightArrow: letter = "C"
                case UIKeyCommand.inputLeftArrow: letter = "D"
                default: return
                }
                let prefix = terminalView.applicationCursorKeys ? "\u{1b}O" : "\u{1b}["
                sendBytes?(Data((prefix + letter).utf8))
            }
        #endif
    }

    public struct SSHTerminalView: UIViewControllerRepresentable {
        @ObservedObject private var bridge: TerminalBridge
        let theme: TerminalTheme
        let scale: Double
        let multiplexerMode: Bool
        let shortcutKeys: [ToolbarKey]

        public init(
            bridge: TerminalBridge,
            theme: TerminalTheme = .defaultTheme,
            scale: Double = 1,
            multiplexerMode: Bool = false,
            shortcutKeys: [ToolbarKey] = ToolbarKey.defaults
        ) {
            self.bridge = bridge
            self.theme = theme
            self.scale = scale
            self.multiplexerMode = multiplexerMode
            self.shortcutKeys = shortcutKeys
        }

        public func makeUIViewController(context: Context) -> UIViewController {
            let controller = TerminalViewController()
            let view = controller.terminalView
            let gestures = GhosttyGestureCoordinator(bridge: bridge, view: view)
            context.coordinator.gestures = gestures
            view.accessibilityIdentifier = "terminal.view"
            view.multiplexerMode = multiplexerMode
            view.onSend = { [weak bridge] data in bridge?.processOutgoing(data) }
            view.onResize = { [weak bridge] cols, rows in bridge?.resizeHost?(cols, rows) }
            view.onTitle = { [weak bridge] title in bridge?.setTerminalTitle(title) }
            view.pasteImage = { [weak bridge] in bridge?.pasteImage() ?? false }
            let composition = IMECompositionView()
            view.addSubview(composition)
            view.markedTextObserver = { [weak view, weak composition] text, clause in
                guard let view, let composition else { return }
                composition.update(
                    text: text, clause: clause, font: view.font, foreground: view.themeForeground,
                    background: view.themeBackground, caret: view.caretFrame, visible: view.bounds)
            }
            #if targetEnvironment(macCatalyst)
                controller.sendControl = { [weak bridge] character in
                    guard let data = ToolbarKeyEncoder.applyCtrl(to: character) else { return }
                    bridge?.processOutgoing(data)
                }
                controller.sendEscape = { [weak bridge] in
                    bridge?.processOutgoing(Data([0x1b]))
                }
                controller.sendBytes = { [weak bridge] data in
                    bridge?.processOutgoing(data)
                }
                controller.installControlKeyCommands()
            #endif
            gestures.install()
            setFont(on: view, base: Double(view.font.pointSize))
            gestures.zoomScale = scale
            bridge.view = view
            view.onResign = { [weak bridge] in bridge?.keyboardHold = nil }
            bridge.setTheme(theme)
            #if !targetEnvironment(macCatalyst)
                bridge.updateShortcutKeyboard = { [weak controller, weak bridge] in
                    guard let bridge else { return }
                    controller?.updateShortcuts(bridge: bridge, keys: shortcutKeys, theme: theme)
                }
                controller.updateShortcuts(bridge: bridge, keys: shortcutKeys, theme: theme)
            #endif
            return controller
        }

        public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
            guard let controller = uiViewController as? TerminalViewController else { return }
            let view = controller.terminalView
            view.multiplexerMode = multiplexerMode
            bridge.setTheme(theme)
            #if !targetEnvironment(macCatalyst)
                bridge.updateShortcutKeyboard = { [weak controller, weak bridge] in
                    guard let bridge else { return }
                    controller?.updateShortcuts(bridge: bridge, keys: shortcutKeys, theme: theme)
                }
                controller.updateShortcuts(bridge: bridge, keys: shortcutKeys, theme: theme)
            #endif
            guard let gestures = context.coordinator.gestures, gestures.zoomScale != scale else { return }
            setFont(on: view, base: Double(view.font.pointSize) / gestures.zoomScale)
            gestures.zoomScale = scale
        }

        @MainActor private func setFont(on view: GhosttyTerminalView, base fallback: Double) {
            let saved = UserDefaults.standard.double(forKey: Coordinator.fontSizeKey)
            let base = FontZoom.range.contains(saved) ? saved : fallback
            view.setFont(
                UIFont.monospacedSystemFont(ofSize: CGFloat(FontZoom.size(base: base, scale: scale)), weight: .regular))
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        @MainActor public final class Coordinator {
            static let fontSizeKey = "pocketshell.terminalFontSize"
            var gestures: GhosttyGestureCoordinator?
        }
    }
#endif
