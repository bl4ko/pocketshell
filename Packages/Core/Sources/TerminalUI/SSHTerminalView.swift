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

    private final class BottomAnchoredTerminalView: TerminalView {
        private var previousSize = CGSize.zero
        var pasteImage: (() -> Bool)?

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
            previousSize = bounds.size
        }

    }

    private final class TerminalViewController: UIViewController {
        let terminalView = BottomAnchoredTerminalView()
        var sendControl: ((Character) -> Void)?
        var sendEscape: (() -> Void)?
        var sendBytes: ((Data) -> Void)?

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
        private let bridge: TerminalBridge
        private let theme: TerminalTheme
        private let scale: Double

        public init(bridge: TerminalBridge, theme: TerminalTheme = .defaultTheme, scale: Double = 1) {
            self.bridge = bridge
            self.theme = theme
            self.scale = scale
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
            view.inputAccessoryView = nil
            view.focusEffect = nil
            view.pasteImage = { [weak bridge] in bridge?.pasteImage() ?? false }
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
            let saved = UserDefaults.standard.double(forKey: Coordinator.fontSizeKey)
            let base = FontZoom.range.contains(saved) ? saved : Double(view.font.pointSize)
            view.font = UIFont.monospacedSystemFont(
                ofSize: CGFloat(FontZoom.size(base: base, scale: scale)), weight: .regular)
            context.coordinator.scale = scale
            bridge.view = view
            bridge.setTheme(theme)
            return controller
        }

        public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
            guard let uiView = (uiViewController as? TerminalViewController)?.terminalView else { return }
            bridge.setTheme(theme)
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
                    #if targetEnvironment(macCatalyst)
                        if view.selectionActive {
                            view.clearSelection()
                        }
                    #endif
                    let terminal = view.getTerminal()
                    guard terminal.mouseMode != .off else { return }
                    let location = gesture.location(in: view)
                    let col = clamp(
                        Int(location.x / view.bounds.width * CGFloat(terminal.cols)), max: terminal.cols - 1)
                    let row = clamp(
                        Int(location.y / view.bounds.height * CGFloat(terminal.rows)), max: terminal.rows - 1)
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
            }

            #if targetEnvironment(macCatalyst)
                private var lastPointerNudge = Date.distantPast

                // Attaching from another device wins tmux's window-size latest with no
                // input at all; moving the pointer here means this device is the one
                // being looked at, so it reclaims the size without waiting for a click.
                @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
                    MainActor.assumeIsolated {
                        guard gesture.view?.window?.isKeyWindow == true,
                            Date().timeIntervalSince(lastPointerNudge) > 2
                        else { return }
                        lastPointerNudge = Date()
                        bridge.pointerActivity?()
                    }
                }

                @objc func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
                    MainActor.assumeIsolated {
                        guard gesture.buttonMask.contains(.primary),
                            let view = gesture.view as? TerminalView
                        else { return }
                        switch gesture.state {
                        case .began:
                            view.startPointerSelection(at: gesture.location(in: view))
                        case .changed, .ended:
                            view.extendPointerSelection(to: gesture.location(in: view))
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

            @MainActor private func handleScrollPanOnMain(_ gesture: UIPanGestureRecognizer) {
                guard let view = gesture.view as? TerminalView else { return }
                #if targetEnvironment(macCatalyst)
                    guard !gesture.buttonMask.contains(.primary) else { return }
                #else
                    if bridge.selectMode {
                        switch gesture.state {
                        case .began:
                            // Also disables SwiftTerm's own selection pan for this drag.
                            view.clearSelection()
                            view.startPointerSelection(at: gesture.location(in: view))
                        case .changed, .ended:
                            view.extendPointerSelection(to: gesture.location(in: view))
                        default:
                            break
                        }
                        return
                    }
                    // SwiftTerm extends the selection on any pan once its own gesture is
                    // armed; scrolling at the same time makes the handles undraggable.
                    if view.selectionActive, view.selectionPanActive {
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
                    let location = gesture.location(in: view)
                    let col = clamp(
                        Int(location.x / view.bounds.width * CGFloat(terminal.cols)), max: terminal.cols - 1)
                    let row = clamp(
                        Int(location.y / view.bounds.height * CGFloat(terminal.rows)), max: terminal.rows - 1)
                    for _ in 0..<abs(lines) {
                        terminal.sendEvent(buttonFlags: flags, x: col, y: row)
                    }
                default:
                    break
                }
            }

            private func clamp(_ value: Int, max limit: Int) -> Int {
                min(max(value, 0), max(limit, 0))
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

            public func setTerminalTitle(source: TerminalView, title: String) {}
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
