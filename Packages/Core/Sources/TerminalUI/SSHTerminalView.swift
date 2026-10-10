#if os(iOS)
    import Models
    import SwiftTerm
    import SwiftUI
    import ToolbarUI
    import UIKit

    extension UIColor {
        convenience init(_ rgb: Models.RGBColor) {
            self.init(
                red: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255,
                alpha: 1
            )
        }
    }

    final class BottomAnchoredTerminalView: TerminalView {
        private var previousSize = CGSize.zero
        private var resizeCount = 0
        var pasteImage: (() -> Bool)?

        var tapRaisesKeyboard: Bool {
            #if targetEnvironment(macCatalyst)
                return true
            #else
                return isFirstResponder || getTerminal().mouseMode == .off
            #endif
        }

        override func paste(_ sender: Any?) {
            if pasteImage?() != true {
                super.paste(sender)
            }
        }

        override func layoutSubviews() {
            let sizeChanged = bounds.size != previousSize
            let wasAtBottom = !canScroll || scrollPosition >= 0.999
            super.layoutSubviews()
            if sizeChanged, wasAtBottom {
                scroll(toPosition: 1)
            }
            accessibilityValue = !canScroll || scrollPosition >= 0.999 ? "bottom" : "history"
            if sizeChanged, ProcessInfo.processInfo.environment["PS_UI_TEST_RESIZE_COUNT"] == "1" {
                resizeCount += 1
                accessibilityLabel = "Terminal resize count: \(resizeCount)"
            }
            previousSize = bounds.size
        }

        // Pin a steady block: SwiftTerm's blink is an opacity fade restarted on every
        // focus/resize, and remote DECSCUSR flips styles mid-session — both read as flicker.
        override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
            super.cursorStyleChanged(source: source, newStyle: .steadyBlock)
        }

    }

    final class TerminalViewController: UIViewController {
        let terminalView = BottomAnchoredTerminalView()
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

            func updateShortcuts(bridge: TerminalBridge, keys: [ToolbarKey], theme: TerminalTheme) {
                let inputs = ShortcutInputs(
                    keys: keys, theme: theme, multiplexer: terminalView.multiplexerMode,
                    category: bridge.shortcutCategory)
                if inputs != shortcutInputs {
                    shortcutInputs = inputs
                    renderShortcuts(bridge: bridge, keys: keys, theme: theme)
                }
                let input: UIView? = bridge.shortcutsActive ? shortcutInput : nil
                if terminalView.inputView !== input {
                    terminalView.inputView = input
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
                terminalView.copy(nil)
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

            // SwiftTerm's pressesBegan repeats held keys on a fixed 0.4s/10Hz timer;
            // UIKeyCommand repeats at the system key-repeat rate instead.
            @objc private func handleArrow(_ command: UIKeyCommand) {
                let letter: String
                switch command.input {
                case UIKeyCommand.inputUpArrow: letter = "A"
                case UIKeyCommand.inputDownArrow: letter = "B"
                case UIKeyCommand.inputRightArrow: letter = "C"
                case UIKeyCommand.inputLeftArrow: letter = "D"
                default: return
                }
                let prefix = terminalView.getTerminal().applicationCursor ? "\u{1b}O" : "\u{1b}["
                sendBytes?(Data((prefix + letter).utf8))
            }
        #endif
    }

    public struct SSHTerminalView: UIViewControllerRepresentable {
        @ObservedObject private var bridge: TerminalBridge
        private let theme: TerminalTheme
        private let scale: Double
        private let multiplexerMode: Bool
        private let shortcutKeys: [ToolbarKey]

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

        static func apply(_ theme: TerminalTheme, to view: TerminalView) {
            if let background = Models.RGBColor(hex: theme.background) {
                view.backgroundColor = UIColor(background)
                view.nativeBackgroundColor = UIColor(background)
            }
            if let foreground = Models.RGBColor(hex: theme.foreground) {
                view.nativeForegroundColor = UIColor(foreground)
            }
            if let cursor = Models.RGBColor(hex: theme.cursor) {
                view.caretColor = UIColor(cursor)
            }
            let colors = theme.ansi.compactMap { Models.RGBColor(hex: $0) }.map {
                SwiftTerm.Color(
                    red: UInt16($0.red) * 257,
                    green: UInt16($0.green) * 257,
                    blue: UInt16($0.blue) * 257
                )
            }
            if colors.count == 16 {
                view.installColors(colors)
            }
        }

        static func isApplied(_ theme: TerminalTheme, to view: TerminalView) -> Bool {
            guard
                let background = Models.RGBColor(hex: theme.background),
                let foreground = Models.RGBColor(hex: theme.foreground),
                let cursor = Models.RGBColor(hex: theme.cursor)
            else { return false }
            return view.nativeBackgroundColor.isEqual(UIColor(background))
                && view.nativeForegroundColor.isEqual(UIColor(foreground))
                && view.caretColor.isEqual(UIColor(cursor))
        }

        public func makeUIViewController(context: Context) -> UIViewController {
            let controller = TerminalViewController()
            let view = controller.terminalView
            view.accessibilityIdentifier = "terminal.view"
            view.terminalDelegate = context.coordinator
            view.allowMouseReporting = false
            view.multiplexerMode = multiplexerMode
            view.getTerminal().setCursorStyle(.steadyBlock)
            view.inputAccessoryView = nil
            view.focusEffect = nil
            view.pasteImage = { [weak bridge] in bridge?.pasteImage() ?? false }
            let composition = IMECompositionView()
            view.addSubview(composition)
            view.markedTextObserver = { [weak view, weak composition] text, clause in
                guard let view, let composition else { return }
                composition.update(text: text, clause: clause, in: view)
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
            let pan = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleScrollPan(_:))
            )
            pan.allowedScrollTypesMask = .all
            let gestureDelegate = SimultaneousGestureDelegate()
            pan.delegate = gestureDelegate
            context.coordinator.gestureDelegate = gestureDelegate
            view.addGestureRecognizer(pan)
            let tap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleMouseTap(_:))
            )
            tap.cancelsTouchesInView = false
            tap.delegate = gestureDelegate
            view.addGestureRecognizer(tap)
            let nativeTapGate = NativeTapGate()
            context.coordinator.nativeTapGate = nativeTapGate
            for recognizer in view.gestureRecognizers ?? [] {
                if let native = recognizer as? UITapGestureRecognizer, native !== tap,
                    native.numberOfTapsRequired == 1
                {
                    native.delegate = nativeTapGate
                }
            }
            #if targetEnvironment(macCatalyst)
                let selectionPan = UIPanGestureRecognizer(
                    target: context.coordinator,
                    action: #selector(Coordinator.handleSelectionPan(_:))
                )
                selectionPan.maximumNumberOfTouches = 1
                selectionPan.delegate = gestureDelegate
                view.addGestureRecognizer(selectionPan)
                // Short drags stay within the tap's slop, and the tap clears the
                // selection the drag just made.
                tap.require(toFail: selectionPan)
                let hover = UIHoverGestureRecognizer(
                    target: context.coordinator,
                    action: #selector(Coordinator.handleHover(_:))
                )
                view.addGestureRecognizer(hover)
            #endif
            let pinch = UIPinchGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handlePinch(_:))
            )
            view.addGestureRecognizer(pinch)
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(
                    target: context.coordinator,
                    action: #selector(Coordinator.handleWindowSwipe(_:))
                )
                swipe.direction = direction
                swipe.delegate = gestureDelegate
                // A swipe that swallows or delays touches costs the terminal its
                // taps, and an unfocused terminal draws no caret.
                swipe.cancelsTouchesInView = false
                swipe.delaysTouchesEnded = false
                view.addGestureRecognizer(swipe)
            }
            let linkPress = UILongPressGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleLinkPress(_:))
            )
            linkPress.minimumPressDuration = 0.5
            linkPress.delegate = gestureDelegate
            linkPress.cancelsTouchesInView = false
            view.addGestureRecognizer(linkPress)
            #if !targetEnvironment(macCatalyst)
                let cursorGesture = CursorGestureController(view: view, bridge: bridge) {
                    [weak coordinator = context.coordinator, weak view] point in
                    guard let view else { return }
                    if coordinator?.openLink(in: view, at: point) != true { view.selectWord(at: point) }
                }
                context.coordinator.cursorGesture = cursorGesture
                pan.require(toFail: cursorGesture.press)
                tap.require(toFail: cursorGesture.press)
                for gesture in view.gestureRecognizers ?? [] where gesture is UISwipeGestureRecognizer {
                    gesture.require(toFail: cursorGesture.press)
                }
            #endif
            let saved = UserDefaults.standard.double(forKey: Coordinator.fontSizeKey)
            let base = FontZoom.range.contains(saved) ? saved : Double(view.font.pointSize)
            view.font = UIFont.monospacedSystemFont(
                ofSize: CGFloat(FontZoom.size(base: base, scale: scale)), weight: .regular)
            context.coordinator.scale = scale
            bridge.view = view
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
            guard let uiView = (uiViewController as? TerminalViewController)?.terminalView else { return }
            uiView.multiplexerMode = multiplexerMode
            bridge.setTheme(theme)
            #if !targetEnvironment(macCatalyst)
                if let controller = uiViewController as? TerminalViewController {
                    bridge.updateShortcutKeyboard = { [weak controller, weak bridge] in
                        guard let bridge else { return }
                        controller?.updateShortcuts(bridge: bridge, keys: shortcutKeys, theme: theme)
                    }
                    controller.updateShortcuts(bridge: bridge, keys: shortcutKeys, theme: theme)
                }
            #endif
            guard context.coordinator.scale != scale else { return }
            let saved = UserDefaults.standard.double(forKey: Coordinator.fontSizeKey)
            let base =
                FontZoom.range.contains(saved)
                ? saved
                : Double(uiView.font.pointSize) / context.coordinator.scale
            uiView.font = UIFont.monospacedSystemFont(
                ofSize: CGFloat(FontZoom.size(base: base, scale: scale)), weight: .regular)
            context.coordinator.scale = scale
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(bridge: bridge)
        }

        final class NativeTapGate: NSObject, UIGestureRecognizerDelegate {
            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                (gestureRecognizer.view as? BottomAnchoredTerminalView)?.tapRaisesKeyboard ?? true
            }
        }

        final class SimultaneousGestureDelegate: NSObject, UIGestureRecognizerDelegate {
            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool {
                true
            }
        }

        public final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
            private let bridge: TerminalBridge
            private var scrollTracker = PanScrollTracker(step: 1)
            var gestureDelegate: SimultaneousGestureDelegate?
            var nativeTapGate: NativeTapGate?
            #if !targetEnvironment(macCatalyst)
                var cursorGesture: CursorGestureController?
            #endif

            init(bridge: TerminalBridge) {
                self.bridge = bridge
            }

            static let fontSizeKey = "pocketshell.terminalFontSize"
            var scale = 1.0
            private var pinchBaseSize: Double = 0

            @objc func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
                MainActor.assumeIsolated {
                    handleScrollPanOnMain(gesture)
                }
            }

            @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
                MainActor.assumeIsolated {
                    handlePinchOnMain(gesture)
                }
            }

            @objc func handleMouseTap(_ gesture: UITapGestureRecognizer) {
                MainActor.assumeIsolated {
                    guard gesture.state == .ended, let view = gesture.view as? TerminalView else { return }
                    noteUserPresence()
                    if (view as? BottomAnchoredTerminalView)?.tapRaisesKeyboard ?? true {
                        _ = view.becomeFirstResponder()
                    }
                    #if targetEnvironment(macCatalyst)
                        if view.selectionActive {
                            view.clearSelection()
                        }
                    #endif
                    sendMouseClick(in: view, at: gesture.location(in: view))
                }
            }

            @MainActor func sendMouseClick(in view: TerminalView, at location: CGPoint) {
                let terminal = view.getTerminal()
                let (row, col) = cell(at: location, in: view)
                if terminal.mouseMode == .off {
                    let lines = (0..<terminal.rows).map {
                        terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? ""
                    }
                    if let shortcut = CodexOptionTap.shortcut(lines: lines, tappedRow: row) {
                        bridge.processOutgoing(Data([shortcut]))
                    }
                    return
                }
                terminal.sendEvent(
                    buttonFlags: terminal.encodeButton(
                        button: 0, release: false, shift: false, meta: false, control: false),
                    x: col,
                    y: row
                )
                terminal.sendEvent(
                    buttonFlags: terminal.encodeButton(
                        button: 0, release: true, shift: false, meta: false, control: false),
                    x: col,
                    y: row
                )
            }

            /// Horizontal swipe walks tmux windows; a plain shell would just get the
            /// prefix bytes, so it only fires while attached to a multiplexer.
            @objc func handleWindowSwipe(_ gesture: UISwipeGestureRecognizer) {
                MainActor.assumeIsolated {
                    guard let view = gesture.view as? TerminalView, view.multiplexerMode else { return }
                    noteUserPresence()
                    bridge.processOutgoing(Data("\u{02}\(gesture.direction == .left ? "n" : "p")".utf8))
                }
            }

            @objc func handleLinkPress(_ gesture: UILongPressGestureRecognizer) {
                MainActor.assumeIsolated {
                    guard gesture.state == .began, let view = gesture.view as? TerminalView else { return }
                    _ = openLink(in: view, at: gesture.location(in: view))
                }
            }

            @MainActor fileprivate func openLink(in view: TerminalView, at location: CGPoint) -> Bool {
                let terminal = view.getTerminal()
                let (row, col) = cell(at: location, in: view)
                let lines = (0..<terminal.rows).map {
                    terminal.getLine(row: $0)?.translateToString(trimRight: false) ?? ""
                }
                let wrapped = (0..<terminal.rows).map { terminal.getLine(row: $0)?.isWrapped ?? false }
                guard let link = TerminalURL.find(lines: lines, wrapped: wrapped, row: row, column: col),
                    let url = URL(string: link)
                else { return false }
                presentLinkMenu(for: url, in: view, at: location)
                return true
            }

            @MainActor private func presentLinkMenu(for url: URL, in view: UIView, at point: CGPoint) {
                guard let controller = view.window?.rootViewController else { return }
                let sheet = UIAlertController(title: url.absoluteString, message: nil, preferredStyle: .actionSheet)
                sheet.addAction(
                    UIAlertAction(title: "Open Link", style: .default) { _ in
                        UIApplication.shared.open(url)
                    })
                sheet.addAction(
                    UIAlertAction(title: "Copy Link", style: .default) { _ in
                        UIPasteboard.general.string = url.absoluteString
                    })
                sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                sheet.popoverPresentationController?.sourceView = view
                sheet.popoverPresentationController?.sourceRect = CGRect(origin: point, size: .zero)
                controller.present(sheet, animated: true)
            }

            // Attaching from another device wins tmux's window-size latest with no
            // input at all, so the device being touched or hovered has to say so to
            // reclaim its size; typing already counts as client activity.
            private var lastPresenceNudge = Date.distantPast

            @MainActor private func noteUserPresence() {
                guard Date().timeIntervalSince(lastPresenceNudge) > 2 else { return }
                lastPresenceNudge = Date()
                bridge.userInteracted?()
            }

            #if targetEnvironment(macCatalyst)
                var selectionStart: CGPoint?

                @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
                    MainActor.assumeIsolated {
                        guard gesture.view?.window?.isKeyWindow == true else { return }
                        noteUserPresence()
                    }
                }

                @objc func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
                    MainActor.assumeIsolated {
                        guard let view = gesture.view as? TerminalView else { return }
                        if gesture.state == .cancelled || gesture.state == .failed {
                            view.endSelectionHandleDrag()
                            selectionStart = nil
                            return
                        }
                        guard gesture.buttonMask.contains(.primary) else { return }
                        let point = gesture.location(in: view)
                        switch gesture.state {
                        case .began:
                            // .began only fires after the pan slop, so location is
                            // already a cell past the press — back out the translation
                            // or the first character is always dropped.
                            let translation = gesture.translation(in: view)
                            let press = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
                            selectionStart = press
                            // Tight slop: a mouse is precise, and a generous grab area
                            // would steal drags meant to start a fresh selection.
                            if !view.grabSelectionHandle(at: press, slop: 14) {
                                view.startPointerSelection(at: press)
                                view.extendPointerSelection(to: point)
                            }
                        case .changed:
                            if view.selectionHandleDragActive {
                                view.dragSelectionHandle(to: point)
                            } else {
                                view.extendPointerSelection(to: point)
                            }
                        case .ended:
                            if view.selectionHandleDragActive {
                                view.dragSelectionHandle(to: point)
                                view.endSelectionHandleDrag()
                            } else {
                                view.extendPointerSelection(to: point)
                                // A click that drifts past the pan slop never reaches the
                                // tap handler, and tmux only moves its active pane on a
                                // mouse report.
                                if let start = selectionStart,
                                    hypot(point.x - start.x, point.y - start.y) < 6
                                {
                                    view.clearSelection()
                                    sendMouseClick(in: view, at: point)
                                }
                            }
                            selectionStart = nil
                        default:
                            break
                        }
                    }
                }
            #endif

            @MainActor private func handlePinchOnMain(_ gesture: UIPinchGestureRecognizer) {
                guard let view = gesture.view as? TerminalView else { return }
                switch gesture.state {
                case .began:
                    pinchBaseSize = Double(view.font.pointSize)
                case .changed:
                    let size = FontZoom.size(base: pinchBaseSize, scale: Double(gesture.scale))
                    if abs(size - Double(view.font.pointSize)) >= 0.5 {
                        view.font = UIFont.monospacedSystemFont(ofSize: CGFloat(size.rounded()), weight: .regular)
                    }
                case .ended:
                    UserDefaults.standard.set(Double(view.font.pointSize) / scale, forKey: Self.fontSizeKey)
                default:
                    break
                }
            }

            @MainActor func handleScrollPanOnMain(_ gesture: UIPanGestureRecognizer) {
                guard let view = gesture.view as? TerminalView else { return }
                if gesture.state == .began {
                    noteUserPresence()
                }
                #if targetEnvironment(macCatalyst)
                    guard !gesture.buttonMask.contains(.primary) else { return }
                #else
                    if bridge.selectMode {
                        switch gesture.state {
                        case .began:
                            // Back out the pan slop so the anchor is the press point,
                            // not a cell past it (first character was always dropped).
                            let point = gesture.location(in: view)
                            let translation = gesture.translation(in: view)
                            let press = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
                            if !view.grabSelectionHandle(at: press) {
                                // Also disables SwiftTerm's own selection pan for this drag.
                                view.clearSelection()
                                view.startPointerSelection(at: press)
                                view.extendPointerSelection(to: point)
                            }
                        case .changed, .ended:
                            if view.selectionHandleDragActive {
                                view.dragSelectionHandle(to: gesture.location(in: view))
                                if gesture.state == .ended {
                                    view.endSelectionHandleDrag()
                                }
                            } else {
                                view.extendPointerSelection(to: gesture.location(in: view))
                            }
                        case .cancelled, .failed:
                            view.endSelectionHandleDrag()
                        default:
                            break
                        }
                        return
                    }
                    // Yield only while a handle is actually being dragged, so a pan
                    // away from the handles still scrolls with the selection intact.
                    if view.selectionActive, view.selectionHandleDragActive {
                        return
                    }
                #endif
                let terminal = view.getTerminal()
                switch gesture.state {
                case .began:
                    scrollTracker = PanScrollTracker(step: Double(view.font.lineHeight))
                case .changed:
                    let delta = gesture.translation(in: view).y
                    gesture.setTranslation(.zero, in: view)
                    let lines = scrollTracker.lines(for: Double(delta))
                    guard lines != 0 else { return }
                    if terminal.mouseMode == .off {
                        if lines > 0 {
                            view.scrollUp(lines: lines)
                        } else {
                            view.scrollDown(lines: -lines)
                        }
                        return
                    }
                    let flags = terminal.encodeButton(
                        button: lines > 0 ? 4 : 5,
                        release: false,
                        shift: false,
                        meta: false,
                        control: false
                    )
                    let (row, col) = cell(at: gesture.location(in: view), in: view)
                    for _ in 0..<abs(lines) {
                        terminal.sendEvent(buttonFlags: flags, x: col, y: row)
                    }
                default:
                    break
                }
            }

            @MainActor private func cell(at location: CGPoint, in view: TerminalView) -> (row: Int, col: Int) {
                let terminal = view.getTerminal()
                return TerminalCell.at(
                    location, contentOffset: view.contentOffset, viewport: view.bounds.size,
                    rows: terminal.rows, cols: terminal.cols)
            }

            private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
                if Thread.isMainThread {
                    MainActor.assumeIsolated { work() }
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { work() }
                    }
                }
            }

            public func send(source: TerminalView, data: ArraySlice<UInt8>) {
                let payload = Data(data)
                let bridge = bridge
                onMain {
                    bridge.processOutgoing(payload)
                }
            }

            public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
                let bridge = bridge
                onMain {
                    bridge.resizeHost?(newCols, newRows)
                }
            }

            public func setTerminalTitle(source: TerminalView, title: String) {
                let bridge = bridge
                onMain { bridge.setTerminalTitle(title) }
            }
            public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
            public func scrolled(source: TerminalView, position: Double) {}
            public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
                guard let url = URL(string: link) else { return }
                onMain {
                    UIApplication.shared.open(url)
                }
            }
            public func bell(source: TerminalView) {}
            public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
            public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
            public func clipboardCopy(source: TerminalView, content: Data) {
                if let text = String(data: content, encoding: .utf8) {
                    UIPasteboard.general.string = text
                }
            }
        }
    }
#endif
