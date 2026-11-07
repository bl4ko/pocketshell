#if os(iOS)
    import CoreText
    import Metal
    import Models
    import QuartzCore
    import UIKit
    import VTKit

    final class GhosttyTerminalView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }

        let terminal: VTTerminal
        var onSend: ((Data) -> Void)?
        var onResize: ((Int, Int) -> Void)?
        var onTitle: ((String) -> Void)?
        var pasteImage: (() -> Bool)?
        var onResign: (() -> Void)?
        var onCaretPlacement: ((CaretPlacement) -> Void)?
        private(set) var caretPlacement: CaretPlacement?
        var markedTextObserver: ((String, NSRange) -> Void)?
        var multiplexerMode = false {
            didSet {
                caret.multiplexer = multiplexerMode
                setNeedsRender()
            }
        }
        var writePasteboard: (String) -> Void = { UIPasteboard.general.string = $0 }
        var readPasteboard: () -> String? = { UIPasteboard.general.string }
        var keyRepeatDelay: TimeInterval = 0.3
        var keyRepeatInterval: TimeInterval = 1.0 / 30.0
        private(set) var renderCount = 0
        private(set) var lastRenderDuration: CFTimeInterval = 0

        private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
        private var renderer: TerminalRenderer?
        private var palette = RenderPalette(
            background: VTColor(r: 0, g: 0, b: 0), foreground: VTColor(r: 255, g: 255, b: 255),
            cursor: VTColor(r: 170, g: 170, b: 170))
        private var appliedTheme: TerminalTheme?
        private var displayLink: CADisplayLink?
        private var renderPending = false
        private var caret = CaretController()
        private var caretPaint: CaretPaint?
        var committedCaret: CaretPaint? { caretPaint }
        var renderBackground: VTColor { palette.background }
        private var caretTimer: Timer?
        private var previousSize = CGSize.zero
        private var resizeCount = 0
        private var keyRepeat: Timer?
        private var findMatch: VTSelection?
        private var handleGrab: (handle: SelectionHandleSide, colOffset: Int, rowOffset: Int)?
        private var selectionPivot: VTPoint?
        private var rectangularSelection = false
        private lazy var editMenu: UIEditMenuInteraction = {
            let interaction = UIEditMenuInteraction(delegate: nil)
            addInteraction(interaction)
            return interaction
        }()
        var document = TextInputDocument()
        var floatingCursor: CGPoint?
        weak var textInputDelegate: UITextInputDelegate?

        private(set) var font: UIFont

        init(font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)) {
            self.font = font
            terminal = VTTerminal(cols: 80, rows: 24)
            super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            isAccessibilityElement = true
            accessibilityTraits.formUnion([.staticText, .causesPageTurn])
            isMultipleTouchEnabled = true
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            metalLayer.isOpaque = true
            metalLayer.presentsWithTransaction = false
            metalLayer.maximumDrawableCount = 2
            if let device = MTLCreateSystemDefaultDevice() {
                metalLayer.device = device
            }
            terminal.onWrite = { [weak self] bytes in self?.onSend?(Data(bytes)) }
            terminal.onTitle = { [weak self] title in self?.onTitle?(title) }
            terminal.onClipboard = { [weak self] text in self?.writePasteboard(text) }
            rebuildRenderer()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("not used from a storyboard")
        }

        deinit {
            MainActor.assumeIsolated {
                displayLink?.invalidate()
                caretTimer?.invalidate()
                keyRepeat?.invalidate()
            }
        }

        // MARK: - Font and theme

        var metrics: CellMetrics? { renderer?.metrics }

        private var displayScale: CGFloat {
            let scale = window?.screen.scale ?? traitCollection.displayScale
            return scale > 0 ? scale : 2
        }

        func setFont(_ font: UIFont) {
            guard font != self.font else { return }
            self.font = font
            rebuildRenderer()
            setNeedsLayout()
        }

        private func rebuildRenderer() {
            guard let device = metalLayer.device,
                let atlas = GlyphAtlasCache.atlas(device: device, font: font, scale: displayScale)
            else { return }
            if let renderer {
                renderer.setAtlas(atlas)
            } else {
                renderer = TerminalRenderer(device: device, atlas: atlas, palette: palette)
            }
            metalLayer.contentsScale = displayScale
            setNeedsRender()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let metrics, metrics.scale != displayScale {
                rebuildRenderer()
                setNeedsLayout()
            }
            setNeedsRender()
        }

        func applyTheme(_ theme: TerminalTheme) {
            guard theme != appliedTheme else { return }
            appliedTheme = theme
            let background = Models.RGBColor(hex: theme.background).map(VTColor.init) ?? palette.background
            let foreground = Models.RGBColor(hex: theme.foreground).map(VTColor.init) ?? palette.foreground
            let cursor = Models.RGBColor(hex: theme.cursor).map(VTColor.init) ?? palette.cursor
            let ansi = theme.ansi.compactMap { Models.RGBColor(hex: $0).map(VTColor.init) }
            palette.background = background
            palette.foreground = foreground
            palette.cursor = cursor
            terminal.setColors(foreground: foreground, background: background, cursor: nil, palette: ansi)
            backgroundColor = UIColor(red: background)
            renderer?.setPalette(palette)
            setNeedsRender()
        }

        var themeForeground: UIColor { UIColor(red: palette.foreground) }
        var themeBackground: UIColor { UIColor(red: palette.background) }

        // MARK: - Layout

        override func layoutSubviews() {
            super.layoutSubviews()
            let scale = displayScale
            metalLayer.contentsScale = scale
            let drawable = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
            if !drawablesReleased, metalLayer.drawableSize != drawable {
                metalLayer.drawableSize = drawable
            }
            if let metrics, bounds.width > 0, bounds.height > 0 {
                let grid = metrics.grid(for: bounds.size)
                if grid.cols != terminal.cols || grid.rows != terminal.rows {
                    let wasAtBottom = terminal.viewportAtBottom
                    terminal.resize(
                        cols: grid.cols, rows: grid.rows, cellWidth: metrics.width, cellHeight: metrics.height)
                    if wasAtBottom { terminal.scrollToBottom() }
                    renderer?.invalidate()
                    onResize?(grid.cols, grid.rows)
                }
            }
            if bounds.size != previousSize, ProcessInfo.processInfo.environment["PS_UI_TEST_RESIZE_COUNT"] == "1" {
                resizeCount += 1
                accessibilityLabel = "Terminal resize count: \(resizeCount)"
            }
            previousSize = bounds.size
            updateScrollAccessibility()
            setNeedsRender()
        }

        private func updateScrollAccessibility() {
            accessibilityValue = terminal.viewportAtBottom ? "bottom" : "history"
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard super.point(inside: point, with: event) else { return false }
            var ancestor = superview
            while let current = ancestor {
                let local = convert(point, to: current)
                if current.clipsToBounds, !current.bounds.contains(local) { return false }
                if let mask = current.layer.mask {
                    let inMask = mask.convert(local, from: current.layer)
                    if let shape = mask as? CAShapeLayer, let path = shape.path {
                        if !path.contains(inMask) { return false }
                    } else if !mask.bounds.contains(inMask) {
                        return false
                    }
                }
                if let maskView = current.mask, !maskView.frame.contains(local) { return false }
                ancestor = current.superview
            }
            return true
        }

        // MARK: - Terminal state

        var terminalCols: Int { terminal.cols }
        var terminalRows: Int { terminal.rows }
        var isAlternateScreen: Bool { terminal.isAlternateScreen }
        var applicationCursorKeys: Bool { terminal.applicationCursor }
        var bracketedPasteMode: Bool { terminal.bracketedPaste }
        var mouseReportingActive: Bool { terminal.mouseTracking != .none }
        var mouseTracking: VTMouseTracking { terminal.mouseTracking }
        var scrolledToBottom: Bool { terminal.viewportAtBottom }

        var customInputView: UIView?
        override var inputView: UIView? { customInputView }
        override var inputAccessoryView: UIView? { nil }

        func feed(_ data: Data) {
            terminal.feed(data)
            caret.noteFeed(
                at: CACurrentMediaTime(), sawHide: terminal.tracker.sawHide, sawSyncEnd: terminal.tracker.sawSyncEnd)
            if !terminal.synchronizedOutput {
                terminal.updateScreen()
                updateCaret()
            }
            updateScrollAccessibility()
            setNeedsRender()
        }

        func screenLines() -> [String] {
            terminal.lines(tag: .viewport)
        }

        func wrappedRows() -> [Bool] {
            (0..<terminal.rows).map { terminal.lineIsContinuation(row: $0, tag: .viewport) }
        }

        func scrollViewport(up lines: Int) {
            guard lines != 0 else { return }
            terminal.scroll(by: -lines)
            updateScrollAccessibility()
            setNeedsRender()
        }

        func scrollToBottom() {
            terminal.scrollToBottom()
            updateScrollAccessibility()
            setNeedsRender()
        }

        func sendWheel(up: Bool, count: Int) {
            sendMouse(
                button: up ? .wheelUp : .wheelDown, action: .press, col: terminal.cols / 2, row: terminal.rows / 2,
                count: count)
        }

        func sendMouse(button: VTMouseButton?, action: VTMouseAction, col: Int, row: Int, count: Int = 1) {
            let bytes = terminal.encodeMouse(button: button, action: action, col: col, row: row)
            guard !bytes.isEmpty else { return }
            for _ in 0..<max(1, count) {
                onSend?(Data(bytes))
            }
        }

        func cell(at point: CGPoint) -> (row: Int, col: Int) {
            guard let metrics else { return (0, 0) }
            let col = Int(floor(point.x / metrics.pointWidth))
            let row = Int(floor(point.y / metrics.pointHeight))
            return (min(max(row, 0), terminal.rows - 1), min(max(col, 0), terminal.cols - 1))
        }

        func cursorViewportRow() -> Int {
            terminal.updateScreen()
            return terminal.screen.cursor.inViewport ? terminal.screen.cursor.row : -100
        }

        var lineHeight: CGFloat { metrics?.pointHeight ?? font.lineHeight }

        // MARK: - Rendering

        func setNeedsRender() {
            renderPending = true
            if displayLink == nil {
                let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            displayLink?.isPaused = false
        }

        override func setNeedsDisplay() {
            super.setNeedsDisplay()
            restoreDrawableSize()
            renderer?.invalidate()
            setNeedsRender()
        }

        private var drawablesReleased = false
        private var syncStarted: CFTimeInterval?

        private func restoreDrawableSize() {
            guard drawablesReleased else { return }
            drawablesReleased = false
            let scale = displayScale
            metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        }

        var drawableReleasedForHiddenLayer: Bool { drawablesReleased }

        func setRenderingSuspended(_ suspended: Bool) {
            layer.isHidden = suspended
            if suspended {
                drawablesReleased = true
                metalLayer.drawableSize = CGSize(width: 1, height: 1)
                displayLink?.isPaused = true
            } else {
                setNeedsDisplay()
            }
        }

        func tick() {
            guard renderPending else {
                displayLink?.isPaused = true
                return
            }
            guard !layer.isHidden, window != nil, bounds.width > 0 else {
                displayLink?.isPaused = true
                return
            }
            let now = CACurrentMediaTime()
            if terminal.synchronizedOutput {
                let started = syncStarted ?? now
                syncStarted = started
                if now - started < 1 { return }
            } else {
                syncStarted = nil
            }
            renderPending = false
            render()
        }

        func render() {
            guard let renderer else { return }
            let start = CACurrentMediaTime()
            terminal.updateScreen()
            renderer.update(screen: terminal.screen, dirty: terminal.screen.takeDirtyRows())
            updateCaret()
            let instances = renderer.instances(
                screen: terminal.screen, caret: caretPaint, handles: handlePaint())
            guard let drawable = metalLayer.nextDrawable(),
                let buffer = renderer.encode(
                    instances: instances, into: drawable.texture, background: palette.background)
            else { return }
            buffer.present(drawable)
            buffer.commit()
            renderCount += 1
            lastRenderDuration = CACurrentMediaTime() - start
        }

        private func updateCaret() {
            let screen = terminal.screen
            let cursor = screen.cursor
            caretTimer?.invalidate()
            caretTimer = nil
            guard cursor.inViewport else {
                caretPaint = nil
                return
            }
            let update = caret.update(
                row: cursor.row, col: cursor.col, hidden: !cursor.visible, addressed: terminal.cursorAddressed,
                cell: screen.cell(col: cursor.col, row: cursor.row).scalar,
                previousCell: screen.cell(col: cursor.col - 1, row: cursor.row).scalar, now: CACurrentMediaTime())
            let style = CaretPaint.Style.block
            var wake = caret.parkWait
            switch update {
            case .show(let row, let col):
                caretPaint = CaretPaint(col: col, row: row, style: style)
            case .hide:
                caretPaint = nil
            case .hold(let remaining):
                caretPaint?.style = style
                wake = min(wake ?? remaining, remaining)
            }
            if let wake {
                caretTimer = Timer.scheduledTimer(withTimeInterval: wake, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setNeedsRender() }
                }
            }
            publishCaretPlacement()
        }

        private func publishCaretPlacement() {
            guard let metrics, let row = caret.parkedRow else { return }
            let placement = CaretPlacement(
                top: CGFloat(row) * metrics.pointHeight, lineHeight: metrics.pointHeight, viewHeight: bounds.height)
            guard placement != caretPlacement else { return }
            caretPlacement = placement
            onCaretPlacement?(placement)
        }

        var caretFrame: CGRect {
            guard let metrics else { return .zero }
            terminal.updateScreen()
            let cursor = terminal.screen.cursor
            return CGRect(
                x: CGFloat(cursor.col) * metrics.pointWidth, y: CGFloat(cursor.row) * metrics.pointHeight,
                width: metrics.pointWidth, height: metrics.pointHeight)
        }

        // MARK: - Selection

        var selectionActive: Bool { terminal.hasSelection }
        var selectionHandleDragActive: Bool { handleGrab != nil }

        private func screenPoint(_ point: CGPoint) -> VTPoint {
            let hit = cell(at: point)
            return VTPoint(col: hit.col, row: terminal.screenRow(forViewportRow: hit.row))
        }

        func startPointerSelection(at point: CGPoint) {
            let hit = screenPoint(point)
            selectionPivot = hit
            terminal.updateScreen()
            rectangularSelection = SplitPanes.hasVerticalDivider(terminal.screen)
            terminal.clearSelection()
            setNeedsRender()
        }

        func extendPointerSelection(to point: CGPoint) {
            guard let pivot = selectionPivot else { return }
            terminal.select(VTSelection(start: pivot, end: screenPoint(point), rectangle: rectangularSelection))
            setNeedsRender()
        }

        func selectWord(at point: CGPoint) {
            if let selection = terminal.selectWord(at: screenPoint(point)) {
                selectionPivot = selection.start
                rectangularSelection = false
            }
            setNeedsRender()
        }

        func selectRow(at point: CGPoint) {
            if let selection = terminal.selectLine(at: screenPoint(point)) {
                selectionPivot = selection.start
                rectangularSelection = false
            }
            setNeedsRender()
        }

        override func selectAll(_ sender: Any?) {
            if let selection = terminal.selectAll() {
                selectionPivot = selection.start
                rectangularSelection = false
            }
            setNeedsRender()
        }

        func showEditMenu(at point: CGPoint) {
            #if !targetEnvironment(macCatalyst)
                guard selectionActive else { return }
                _ = becomeFirstResponder()
                editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            #endif
        }

        func clearSelection() {
            terminal.clearSelection()
            selectionPivot = nil
            handleGrab = nil
            setNeedsRender()
        }

        @discardableResult
        func grabSelectionHandle(at point: CGPoint, slop: CGFloat = 30) -> Bool {
            guard let selection = terminal.selection, let metrics else {
                handleGrab = nil
                return false
            }
            let offset = terminal.scrollbar.offset
            let start = VTPoint(col: selection.start.col, row: selection.start.row - offset)
            let end = VTPoint(col: selection.end.col, row: selection.end.row - offset)
            guard
                let grab = HandleGrabMath.grab(
                    point: point, start: (start.col, start.row), end: (end.col, end.row), cellWidth: metrics.pointWidth,
                    cellHeight: metrics.pointHeight, slop: slop)
            else {
                handleGrab = nil
                return false
            }
            selectionPivot = grab.handle == .start ? selection.end : selection.start
            rectangularSelection = selection.rectangle
            handleGrab = (grab.handle, grab.colOffset, grab.rowOffset)
            return true
        }

        func dragSelectionHandle(to point: CGPoint) {
            guard let handleGrab, let pivot = selectionPivot else { return }
            let hit = screenPoint(point)
            let target = VTPoint(
                col: min(max(0, hit.col + handleGrab.colOffset), terminal.cols - 1),
                row: max(0, hit.row + handleGrab.rowOffset))
            terminal.select(VTSelection(start: pivot, end: target, rectangle: rectangularSelection))
            setNeedsRender()
        }

        func endSelectionHandleDrag() {
            handleGrab = nil
        }

        private func handlePaint() -> HandlePaint? {
            #if targetEnvironment(macCatalyst)
                return nil
            #else
                guard let selection = terminal.selection else { return nil }
                let offset = terminal.scrollbar.offset
                return HandlePaint(
                    start: (selection.start.col, selection.start.row - offset),
                    end: (selection.end.col, selection.end.row - offset))
            #endif
        }

        func selectedText() -> String? {
            terminal.selectionText()
        }

        func copySelectionToPasteboard() {
            if let text = terminal.selectionText() {
                writePasteboard(text)
            }
            clearSelection()
        }

        // MARK: - Find

        func find(_ term: String, forward: Bool) -> Bool {
            let needle = term.lowercased().map { String($0) }
            guard !needle.isEmpty else { return false }
            let total = terminal.scrollbar.total
            guard total > 0 else { return false }
            let origin = findMatch?.start ?? VTPoint(col: forward ? -1 : terminal.cols, row: forward ? 0 : total - 1)
            let first = logicalLineHead(origin.row)
            var head = first
            repeat {
                if let match = nextMatch(
                    of: needle, inLineAt: head, after: head == first ? origin : nil, forward: forward)
                {
                    reveal(match)
                    return true
                }
                head = nextLogicalLine(after: head, forward: forward, total: total)
            } while head != first
            guard let match = nextMatch(of: needle, inLineAt: first, after: nil, forward: forward) else { return false }
            reveal(match)
            return true
        }

        private func logicalLineHead(_ row: Int) -> Int {
            var head = row
            while head > 0, terminal.lineIsContinuation(row: head, tag: .screen) { head -= 1 }
            return head
        }

        private func nextLogicalLine(after head: Int, forward: Bool, total: Int) -> Int {
            guard forward else { return logicalLineHead((head - 1 + total) % total) }
            var row = head + 1
            while row < total, terminal.lineIsContinuation(row: row, tag: .screen) { row += 1 }
            return row % total
        }

        private func nextMatch(of needle: [String], inLineAt head: Int, after origin: VTPoint?, forward: Bool)
            -> VTSelection?
        {
            var cells: [(text: String, start: VTPoint, end: VTPoint)] = []
            var row = head
            repeat {
                for cell in terminal.lineCells(row: row, tag: .screen) {
                    let start = VTPoint(col: cell.col, row: row)
                    cells.append(
                        (cell.text.lowercased(), start, VTPoint(col: cell.col + (cell.wide ? 1 : 0), row: row)))
                }
                row += 1
            } while row < terminal.scrollbar.total && terminal.lineIsContinuation(row: row, tag: .screen)
            guard cells.count >= needle.count else { return nil }
            let precedes = { (a: VTPoint, b: VTPoint) in a.row < b.row || (a.row == b.row && a.col < b.col) }
            let matches = (0...(cells.count - needle.count))
                .filter { index in (0..<needle.count).allSatisfy { cells[index + $0].text == needle[$0] } }
                .map { VTSelection(start: cells[$0].start, end: cells[$0 + needle.count - 1].end) }
                .filter { match in
                    guard let origin else { return true }
                    return forward ? precedes(origin, match.start) : precedes(match.start, origin)
                }
            return forward ? matches.first : matches.last
        }

        private func reveal(_ match: VTSelection) {
            findMatch = match
            terminal.select(match)
            let viewportTop = terminal.scrollbar.offset
            if match.start.row < viewportTop || match.end.row >= viewportTop + terminal.rows {
                terminal.scroll(toRow: max(0, match.start.row - terminal.rows / 2))
            }
            updateScrollAccessibility()
            setNeedsRender()
        }

        func clearFind() {
            findMatch = nil
            clearSelection()
        }

        // MARK: - Responder

        override var canBecomeFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became {
                if terminal.focusReporting { onSend?(Data(terminal.encodeFocus(true))) }
                setNeedsRender()
            }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                keyRepeat?.invalidate()
                keyRepeat = nil
                if terminal.focusReporting { onSend?(Data(terminal.encodeFocus(false))) }
                onResign?()
                setNeedsRender()
            }
            return resigned
        }

        func tapRaisesKeyboard(at point: CGPoint) -> Bool {
            #if targetEnvironment(macCatalyst)
                return true
            #else
                guard !isFirstResponder, mouseReportingActive else { return true }
                return abs(cell(at: point).row - (caretPaint?.row ?? cursorViewportRow())) <= 2
            #endif
        }

        // MARK: - Clipboard

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            switch action {
            case #selector(copy(_:)): selectionActive
            case #selector(paste(_:)), #selector(selectAll(_:)): true
            default: false
            }
        }

        override func copy(_ sender: Any?) {
            copySelectionToPasteboard()
        }

        override func paste(_ sender: Any?) {
            if pasteImage?() == true { return }
            pasteFromClipboard()
        }

        func pasteFromClipboard() {
            readPasteboard().map(pasteText)
        }

        func pasteText(_ text: String) {
            clearSelection()
            if terminal.bracketedPaste {
                send(Data("\u{1b}[200~".utf8) + Data(text.utf8) + Data("\u{1b}[201~".utf8))
            } else {
                send(Data(text.utf8))
            }
        }

        func send(_ data: Data) {
            guard !data.isEmpty else { return }
            if !terminal.viewportAtBottom {
                scrollToBottom()
            }
            onSend?(data)
        }

        // MARK: - Hardware keyboard

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard document.markedRange == nil else {
                super.pressesBegan(presses, with: event)
                return
            }
            var unhandled = Set<UIPress>()
            for press in presses {
                guard let key = press.key, let bytes = encode(key, action: .press) else {
                    unhandled.insert(press)
                    continue
                }
                if !bytes.isEmpty { send(Data(bytes)) }
                startRepeat(key)
            }
            if !unhandled.isEmpty {
                super.pressesBegan(unhandled, with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            keyRepeat?.invalidate()
            keyRepeat = nil
            if terminal.kittyKeyboardFlags & 0b10 != 0 {
                for press in presses {
                    if let key = press.key, let bytes = encode(key, action: .release), !bytes.isEmpty {
                        send(Data(bytes))
                    }
                }
            }
            super.pressesEnded(presses, with: event)
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            keyRepeat?.invalidate()
            keyRepeat = nil
            super.pressesCancelled(presses, with: event)
        }

        private func modifiers(of flags: UIKeyModifierFlags) -> VTModifiers {
            var result: VTModifiers = []
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.alternate) { result.insert(.alt) }
            if flags.contains(.command) { result.insert(.command) }
            return result
        }

        func encode(_ key: UIKey, action: VTKeyAction) -> [UInt8]? {
            encode(
                keyCode: key.keyCode, modifierFlags: key.modifierFlags, characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers, action: action)
        }

        func encode(
            keyCode: UIKeyboardHIDUsage, modifierFlags: UIKeyModifierFlags, characters: String,
            charactersIgnoringModifiers: String, action: VTKeyAction
        ) -> [UInt8]? {
            let modifiers = modifiers(of: modifierFlags)
            guard !modifiers.contains(.command), let vtKey = VTKey(hidUsage: keyCode.rawValue) else { return nil }
            if vtKey.isModifier {
                return terminal.kittyKeyboardFlags & 0b1000 != 0
                    ? terminal.encodeKey(vtKey, modifiers: modifiers, action: action) : nil
            }
            if keyCode == .keyboardPageUp || keyCode == .keyboardPageDown, !terminal.applicationCursor,
                terminal.kittyKeyboardFlags == 0, !terminal.isAlternateScreen
            {
                if action != .release {
                    scrollViewport(up: keyCode == .keyboardPageUp ? terminal.rows : -terminal.rows)
                }
                return []
            }
            if modifiers == .alt, terminal.kittyKeyboardFlags == 0,
                keyCode == .keyboardLeftArrow || keyCode == .keyboardRightArrow
            {
                return action == .release ? [] : Array((keyCode == .keyboardLeftArrow ? "\u{1b}b" : "\u{1b}f").utf8)
            }
            let special = charactersIgnoringModifiers.hasPrefix("UIKeyInput")
            let functional =
                characters.isEmpty || special
                || charactersIgnoringModifiers.unicodeScalars.contains {
                    $0.value < 0x20 || $0.value == 0x7f || (0xF700...0xF8FF).contains($0.value)
                }
            let modified = modifiers.contains(.control) || modifiers.contains(.alt)
            guard functional || modified || terminal.kittyKeyboardFlags & 0b1000 != 0 else { return nil }
            let unshifted = special ? nil : charactersIgnoringModifiers.lowercased().first
            let unmodified =
                modifiers.contains(.shift) ? charactersIgnoringModifiers.uppercased() : charactersIgnoringModifiers
            let text =
                modifiers.contains(.control) || functional
                ? nil : modifiers.contains(.alt) ? unmodified : characters
            let bytes = terminal.encodeKey(
                vtKey, modifiers: modifiers, text: text, unshifted: unshifted, action: action)
            return action == .release || !bytes.isEmpty ? bytes : nil
        }

        private func startRepeat(_ key: UIKey) {
            keyRepeat?.invalidate()
            keyRepeat = nil
            guard let vtKey = VTKey(hidUsage: key.keyCode.rawValue), !vtKey.isModifier else { return }
            let timer = Timer(
                fire: Date(timeIntervalSinceNow: keyRepeatDelay), interval: keyRepeatInterval, repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let bytes = self.encode(key, action: .repeatPress), !bytes.isEmpty else { return }
                    self.send(Data(bytes))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            keyRepeat = timer
        }
    }

    @MainActor
    private final class DisplayLinkProxy: NSObject {
        weak var view: GhosttyTerminalView?

        init(_ view: GhosttyTerminalView) {
            self.view = view
        }

        @objc func tick() {
            view?.tick()
        }
    }

    @MainActor
    enum GlyphAtlasCache {
        private struct Key: Hashable {
            var name: String
            var size: CGFloat
            var scale: CGFloat
        }

        private final class Box {
            weak var atlas: GlyphAtlas?
        }

        private static var cache: [Key: Box] = [:]

        static func atlas(device: MTLDevice, font: UIFont, scale: CGFloat) -> GlyphAtlas? {
            let key = Key(name: font.fontName, size: font.pointSize, scale: scale)
            if let atlas = cache[key]?.atlas { return atlas }
            guard let atlas = GlyphAtlas(device: device, font: font as CTFont, scale: scale) else { return nil }
            let box = Box()
            box.atlas = atlas
            cache[key] = box
            return atlas
        }
    }

    extension UIColor {
        convenience init(red color: VTColor) {
            self.init(
                red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
        }
    }

    extension VTColor {
        init(_ rgb: Models.RGBColor) {
            self.init(r: UInt8(clamping: rgb.red), g: UInt8(clamping: rgb.green), b: UInt8(clamping: rgb.blue))
        }
    }
#endif
