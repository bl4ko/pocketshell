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
        #if targetEnvironment(macCatalyst)
            private let dragSelectionLayer = CAShapeLayer()
            private var dragSelectionStart: Position?
            private var dragSelectionEnd: Position?
        #endif
        var pasteImage: (() -> Bool)?

        override func copy(_ sender: Any?) {
            #if targetEnvironment(macCatalyst)
                if let text = dragSelectionText(), !text.isEmpty {
                    UIPasteboard.general.string = text
                    return
                }
            #endif
            super.copy(sender)
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
            previousSize = bounds.size
        }

        #if targetEnvironment(macCatalyst)
            func beginDragSelection(at point: CGPoint) {
                dragSelectionStart = terminalPosition(at: point)
                dragSelectionEnd = dragSelectionStart
                drawDragSelection()
            }

            func extendDragSelection(to point: CGPoint) {
                dragSelectionEnd = terminalPosition(at: point)
                drawDragSelection()
            }

            func clearDragSelection() {
                dragSelectionStart = nil
                dragSelectionEnd = nil
                dragSelectionLayer.removeFromSuperlayer()
            }

            private func terminalPosition(at point: CGPoint) -> Position {
                let terminal = getTerminal()
                let col = min(max(Int(point.x / bounds.width * CGFloat(terminal.cols)), 0), terminal.cols - 1)
                let row = min(max(Int(point.y / bounds.height * CGFloat(terminal.rows)), 0), terminal.rows - 1)
                return Position(col: col, row: row)
            }

            private func orderedSelection() -> (Position, Position)? {
                guard let start = dragSelectionStart, let end = dragSelectionEnd else { return nil }
                return start.row < end.row || (start.row == end.row && start.col <= end.col)
                    ? (start, end) : (end, start)
            }

            private func dragSelectionText() -> String? {
                guard let (start, end) = orderedSelection() else { return nil }
                return (start.row...end.row).compactMap { row in
                    guard let line = getTerminal().getLine(row: row) else { return nil }
                    let text = line.translateToString(trimRight: true)
                    let lower = row == start.row ? start.col : 0
                    let upper = row == end.row ? end.col + 1 : text.count
                    guard lower < text.count else { return "" }
                    return String(text.dropFirst(lower).prefix(max(0, min(upper, text.count) - lower)))
                }.joined(separator: "\n")
            }

            private func drawDragSelection() {
                guard let (start, end) = orderedSelection() else { return }
                let terminal = getTerminal()
                let cellWidth = bounds.width / CGFloat(terminal.cols)
                let cellHeight = bounds.height / CGFloat(terminal.rows)
                let path = CGMutablePath()
                for row in start.row...end.row {
                    let firstCol = row == start.row ? start.col : 0
                    let lastCol = row == end.row ? end.col : terminal.cols - 1
                    path.addRect(
                        CGRect(
                            x: CGFloat(firstCol) * cellWidth,
                            y: CGFloat(row) * cellHeight,
                            width: CGFloat(lastCol - firstCol + 1) * cellWidth,
                            height: cellHeight
                        ))
                }
                dragSelectionLayer.path = path
                dragSelectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.35).cgColor
                if dragSelectionLayer.superlayer == nil {
                    layer.addSublayer(dragSelectionLayer)
                }
            }
        #endif
    }

    private final class TerminalViewController: UIViewController {
        let terminalView = BottomAnchoredTerminalView()
        var sendControl: ((Character) -> Void)?
        var sendEscape: (() -> Void)?

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
                let escapeCommand = UIKeyCommand(
                    input: UIKeyCommand.inputEscape,
                    modifierFlags: [],
                    action: #selector(handleEscape)
                )
                escapeCommand.wantsPriorityOverSystemBehavior = true
                addKeyCommand(escapeCommand)
            }

            @objc private func handleControl(_ command: UIKeyCommand) {
                if let character = command.input?.first {
                    sendControl?(character)
                }
            }

            @objc private func handleCopy() {
                terminalView.copy(nil)
            }

            @objc private func handleEscape() {
                sendEscape?()
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
                        (view as? BottomAnchoredTerminalView)?.clearDragSelection()
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
                @objc func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
                    MainActor.assumeIsolated {
                        guard gesture.buttonMask.contains(.primary),
                            let view = gesture.view as? BottomAnchoredTerminalView
                        else { return }
                        switch gesture.state {
                        case .began:
                            view.beginDragSelection(at: gesture.location(in: view))
                        case .changed, .ended:
                            view.extendDragSelection(to: gesture.location(in: view))
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
