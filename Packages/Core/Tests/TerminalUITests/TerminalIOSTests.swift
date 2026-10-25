#if os(iOS)
    import Combine
    import Models
    import SwiftTerm
    import Testing
    import ToolbarUI
    import UIKit
    import UIKit.UIGestureRecognizerSubclass

    @testable import TerminalUI

    private final class StatefulPan: UIPanGestureRecognizer {
        var forced = UIGestureRecognizer.State.possible
        override var state: UIGestureRecognizer.State {
            get { forced }
            set { forced = newValue }
        }
        func deliver(_ newState: UIGestureRecognizer.State) { forced = newState }
    }

    @MainActor
    private func makeTerminal(rows: Int = 10) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.getTerminal().resize(cols: 40, rows: rows)
        view.layoutIfNeeded()
        return view
    }

    @MainActor
    @Test func terminalTitleChangeDoesNotPublish() {
        let bridge = TerminalBridge()
        var fired = 0
        let token = bridge.objectWillChange.sink { fired += 1 }
        bridge.setTerminalTitle("⠋ working")
        #expect(bridge.terminalTitle == "⠋ working")
        #expect(fired == 0)
        token.cancel()
    }

    #if !targetEnvironment(macCatalyst)
        @MainActor
        @Test func cancelledSelectModePanEndsHandleDrag() {
            for state in [UIGestureRecognizer.State.cancelled, .failed] {
                let bridge = TerminalBridge()
                bridge.selectMode = true
                let coordinator = SSHTerminalView.Coordinator(bridge: bridge)
                let view = makeTerminal()
                view.feed(text: "hello world\r\n")
                view.startPointerSelection(at: CGPoint(x: 1, y: 1))
                view.extendPointerSelection(to: CGPoint(x: 60, y: 1))
                #expect(view.grabSelectionHandle(at: CGPoint(x: 1, y: 1), slop: 10_000))
                #expect(view.selectionHandleDragActive)
                let pan = StatefulPan()
                view.addGestureRecognizer(pan)
                pan.deliver(state)
                #expect(pan.state == state)
                coordinator.handleScrollPanOnMain(pan)
                #expect(!view.selectionHandleDragActive)
            }
        }
    #endif

    @MainActor
    @Test func scrolledTapMapsToVisibleRowNotLastRow() {
        let bridge = TerminalBridge()
        var sent: [Data] = []
        bridge.sendToHost = { sent.append($0) }
        let coordinator = SSHTerminalView.Coordinator(bridge: bridge)
        let view = makeTerminal()
        var text = (0..<20).map { "head \($0)" }
        text += ["Question 1/1", "1. Alpha", "2. Beta", "3. Gamma", "enter to submit answer"]
        text += (0..<40).map { "filler \($0)" }
        view.feed(text: text.joined(separator: "\r\n") + "\r\n")
        view.layoutIfNeeded()
        view.scrollUp(lines: 30)
        let terminal = view.getTerminal()
        let rows = (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        let optionRow = try! #require(rows.firstIndex(of: "2. Beta"))
        let rowHeight = view.bounds.height / CGFloat(terminal.rows)
        let y = view.contentOffset.y + (CGFloat(optionRow) + 0.5) * rowHeight
        #expect(view.contentOffset.y > 0)
        #expect(optionRow < terminal.rows - 1)
        coordinator.sendMouseClick(in: view, at: CGPoint(x: 10, y: y))
        #expect(sent == [Data([UInt8(ascii: "2")])])
    }

    #if !targetEnvironment(macCatalyst)
        private func key(_ label: String) -> ToolbarKey {
            ToolbarKey(label: label, action: .sequence(label))
        }

        @MainActor
        @Test func shortcutPanelRebuildsOnlyWhenInputsChange() {
            let bridge = TerminalBridge()
            let controller = TerminalViewController()
            controller.loadViewIfNeeded()
            let keys = [key("a")]
            let theme = TerminalTheme.pocketshell
            let saved = bridge.shortcutCategory
            defer { bridge.selectShortcutCategory(saved) }
            bridge.selectShortcutCategory(.favorites)

            controller.updateShortcuts(bridge: bridge, keys: keys, theme: theme)
            #expect(controller.shortcutRenderCount == 1)
            controller.updateShortcuts(bridge: bridge, keys: keys, theme: theme)
            #expect(controller.shortcutRenderCount == 1)

            bridge.selectShortcutCategory(.shell)
            controller.updateShortcuts(bridge: bridge, keys: keys, theme: theme)
            #expect(controller.shortcutRenderCount == 2)

            controller.updateShortcuts(bridge: bridge, keys: [key("b")], theme: theme)
            #expect(controller.shortcutRenderCount == 3)

            controller.terminalView.multiplexerMode.toggle()
            controller.updateShortcuts(bridge: bridge, keys: [key("b")], theme: theme)
            #expect(controller.shortcutRenderCount == 4)
        }

        @MainActor
        @Test func shortcutInputViewFollowsBridgeWithoutRebuild() {
            let bridge = TerminalBridge()
            let controller = TerminalViewController()
            controller.loadViewIfNeeded()
            let keys = [key("a")]
            let theme = TerminalTheme.pocketshell

            controller.updateShortcuts(bridge: bridge, keys: keys, theme: theme)
            #expect(controller.terminalView.inputView == nil)
            bridge.toggleShortcuts()
            controller.updateShortcuts(bridge: bridge, keys: keys, theme: theme)
            #expect(controller.terminalView.inputView === controller.shortcutInput)
            #expect(controller.shortcutRenderCount == 1)
            bridge.toggleShortcuts()
            controller.updateShortcuts(bridge: bridge, keys: keys, theme: theme)
            #expect(controller.terminalView.inputView == nil)
            #expect(controller.shortcutRenderCount == 1)
        }
    #endif

    #if targetEnvironment(macCatalyst)
        private final class PointerPan: UIPanGestureRecognizer {
            var forced = UIGestureRecognizer.State.possible
            var point = CGPoint.zero
            override var state: UIGestureRecognizer.State {
                get { forced }
                set { forced = newValue }
            }
            override var buttonMask: UIEvent.ButtonMask { .primary }
            override func location(in view: UIView?) -> CGPoint { point }
            override func translation(in view: UIView?) -> CGPoint { .zero }
        }

        @MainActor
        @Test func cancelledCatalystSelectionPanEndsHandleDragAndNextPanStartsFresh() {
            for state in [UIGestureRecognizer.State.cancelled, .failed] {
                let coordinator = SSHTerminalView.Coordinator(bridge: TerminalBridge())
                let view = makeTerminal()
                view.feed(text: "hello world\r\n")
                view.startPointerSelection(at: CGPoint(x: 1, y: 1))
                view.extendPointerSelection(to: CGPoint(x: 60, y: 1))
                #expect(view.grabSelectionHandle(at: CGPoint(x: 1, y: 1), slop: 10_000))
                let pan = PointerPan()
                view.addGestureRecognizer(pan)
                pan.point = CGPoint(x: 1, y: 1)
                pan.forced = .began
                coordinator.handleSelectionPan(pan)
                #expect(view.selectionHandleDragActive)
                #expect(coordinator.selectionStart != nil)
                pan.forced = state
                coordinator.handleSelectionPan(pan)
                #expect(!view.selectionHandleDragActive)
                #expect(coordinator.selectionStart == nil)
                pan.point = CGPoint(x: 300, y: 200)
                pan.forced = .began
                coordinator.handleSelectionPan(pan)
                #expect(!view.selectionHandleDragActive)
                #expect(coordinator.selectionStart == CGPoint(x: 300, y: 200))
            }
        }
    #endif
    #if !targetEnvironment(macCatalyst)
        private final class EndedTap: UITapGestureRecognizer {
            var point = CGPoint.zero
            override var state: UIGestureRecognizer.State {
                get { .ended }
                set {}
            }
            override func location(in view: UIView?) -> CGPoint { point }
        }

        @MainActor
        private func windowedTerminal() -> (BottomAnchoredTerminalView, UIWindow) {
            let view = BottomAnchoredTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            view.getTerminal().resize(cols: 40, rows: 10)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            window.addSubview(view)
            window.makeKeyAndVisible()
            return (view, window)
        }

        @MainActor
        @Test func mouseReportingTapSendsClickWithoutRaisingKeyboard() async throws {
            let bridge = TerminalBridge()
            var sent: [Data] = []
            bridge.sendToHost = { sent.append($0) }
            let coordinator = SSHTerminalView.Coordinator(bridge: bridge)
            let (view, window) = windowedTerminal()
            view.terminalDelegate = coordinator
            view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
            #expect(!view.isFirstResponder)
            let tap = EndedTap()
            tap.point = CGPoint(x: 10, y: 285)
            #expect(!view.tapRaisesKeyboard(at: tap.point))
            view.addGestureRecognizer(tap)
            coordinator.handleMouseTap(tap)
            try await Task.sleep(for: .milliseconds(200))
            #expect(!view.isFirstResponder)
            #expect(!sent.isEmpty)
            withExtendedLifetime(window) {}
        }

        @MainActor
        @Test func plainShellTapRaisesKeyboard() {
            let bridge = TerminalBridge()
            let coordinator = SSHTerminalView.Coordinator(bridge: bridge)
            let (view, window) = windowedTerminal()
            view.terminalDelegate = coordinator
            #expect(view.tapRaisesKeyboard(at: .zero))
            let tap = EndedTap()
            view.addGestureRecognizer(tap)
            coordinator.handleMouseTap(tap)
            #expect(view.isFirstResponder)
            withExtendedLifetime(window) {}
        }

        @MainActor
        @Test func mouseReportingTapKeepsKeyboardWhenAlreadyUp() {
            let (view, window) = windowedTerminal()
            view.feed(text: "\u{1b}[?1000h")
            #expect(view.becomeFirstResponder())
            #expect(view.tapRaisesKeyboard(at: CGPoint(x: 10, y: 285)))
            withExtendedLifetime(window) {}
        }

        private final class ScriptedPan: UIPanGestureRecognizer {
            var forced = UIGestureRecognizer.State.possible
            var point = CGPoint.zero
            var moved = CGPoint.zero
            override var state: UIGestureRecognizer.State {
                get { forced }
                set { forced = newValue }
            }
            override func location(in view: UIView?) -> CGPoint { point }
            override func translation(in view: UIView?) -> CGPoint { moved }
        }

        @MainActor
        @Test func multiplexerSelectDragIsForwardedAsMouseDrag() {
            let bridge = TerminalBridge()
            bridge.selectMode = true
            var sent = ""
            bridge.sendToHost = { sent += String(decoding: $0, as: UTF8.self) }
            let coordinator = SSHTerminalView.Coordinator(bridge: bridge)
            let view = makeTerminal()
            view.terminalDelegate = coordinator
            view.multiplexerMode = true
            view.feed(text: "\u{1b}[?1002h\u{1b}[?1006h")
            let pan = ScriptedPan()
            view.addGestureRecognizer(pan)
            pan.point = CGPoint(x: 55, y: 45)
            pan.moved = CGPoint(x: 20, y: 0)
            pan.forced = .began
            coordinator.handleScrollPanOnMain(pan)
            pan.point = CGPoint(x: 205, y: 105)
            pan.forced = .changed
            coordinator.handleScrollPanOnMain(pan)
            pan.forced = .ended
            coordinator.handleScrollPanOnMain(pan)
            let terminal = view.getTerminal()
            func sgr(_ x: CGFloat, _ y: CGFloat) -> String {
                let cell = TerminalCell.at(
                    CGPoint(x: x, y: y), contentOffset: view.contentOffset, viewport: view.bounds.size,
                    rows: terminal.rows, cols: terminal.cols)
                return "\(cell.col + 1);\(cell.row + 1)"
            }
            #expect(sgr(35, 45) != sgr(205, 105))
            #expect(
                sent
                    == "\u{1b}[<0;\(sgr(35, 45))M\u{1b}[<32;\(sgr(55, 45))M"
                    + "\u{1b}[<32;\(sgr(205, 105))M\u{1b}[<0;\(sgr(205, 105))m")
            #expect(!view.selectionActive)
            #expect(!bridge.selectMode)
        }

        @MainActor
        @Test func swipeDuringSelectionDoesNotSwitchWindows() {
            let bridge = TerminalBridge()
            var sent: [Data] = []
            bridge.sendToHost = { sent.append($0) }
            let coordinator = SSHTerminalView.Coordinator(bridge: bridge)
            let view = makeTerminal()
            view.multiplexerMode = true
            let swipe = UISwipeGestureRecognizer()
            swipe.direction = .left
            view.addGestureRecognizer(swipe)
            bridge.selectMode = true
            coordinator.handleWindowSwipe(swipe)
            #expect(sent.isEmpty)
            bridge.selectMode = false
            view.feed(text: "hello world\r\n")
            view.selectWord(at: CGPoint(x: 1, y: 1))
            #expect(view.selectionActive)
            coordinator.handleWindowSwipe(swipe)
            #expect(sent.isEmpty)
            view.clearSelection()
            coordinator.handleWindowSwipe(swipe)
            #expect(sent == [Data("\u{02}n".utf8)])
        }

        @MainActor
        @Test func mouseReportingTapOnInputLineRaisesKeyboard() async throws {
            let bridge = TerminalBridge()
            var sent: [Data] = []
            bridge.sendToHost = { sent.append($0) }
            let coordinator = SSHTerminalView.Coordinator(bridge: bridge)
            let (view, window) = windowedTerminal()
            view.terminalDelegate = coordinator
            view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[9;3H")
            let tap = EndedTap()
            tap.point = CGPoint(x: 10, y: 285)
            #expect(view.tapRaisesKeyboard(at: tap.point))
            #expect(!view.tapRaisesKeyboard(at: CGPoint(x: 10, y: 15)))
            view.addGestureRecognizer(tap)
            coordinator.handleMouseTap(tap)
            try await Task.sleep(for: .milliseconds(200))
            #expect(view.isFirstResponder)
            #expect(!sent.isEmpty)
            withExtendedLifetime(window) {}
        }

        @MainActor
        @Test func closeKeyboardResignsTerminalAndTextField() {
            let bridge = TerminalBridge()
            let (view, window) = windowedTerminal()
            bridge.view = view
            #expect(view.becomeFirstResponder())
            bridge.closeKeyboard()
            #expect(!view.isFirstResponder)
            let field = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
            window.addSubview(field)
            #expect(field.becomeFirstResponder())
            bridge.closeKeyboard()
            #expect(!field.isFirstResponder)
            withExtendedLifetime(window) {}
        }
    #endif

    @MainActor
    @Test func halfPageScrollSendsWheelStepsAtCenterCellWhenMouseReporting() {
        let bridge = TerminalBridge()
        var sent = ""
        bridge.sendToHost = { sent += String(decoding: $0, as: UTF8.self) }
        let coordinator = SSHTerminalView.Coordinator(bridge: bridge)
        let view = makeTerminal()
        view.getTerminal().resize(cols: 40, rows: 24)
        view.terminalDelegate = coordinator
        bridge.view = view
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        bridge.scrollHalfPage(up: true)
        #expect(sent == String(repeating: "\u{1b}[<64;21;13M", count: 4))
        sent = ""
        bridge.scrollHalfPage(up: false)
        #expect(sent == String(repeating: "\u{1b}[<65;21;13M", count: 4))
        view.getTerminal().resize(cols: 40, rows: 5)
        sent = ""
        bridge.scrollHalfPage(up: true)
        #expect(sent == "\u{1b}[<64;21;3M")
    }

    @MainActor
    @Test func halfPageScrollMovesLocalScrollbackWithoutMouseReporting() {
        let bridge = TerminalBridge()
        var sent: [Data] = []
        bridge.sendToHost = { sent.append($0) }
        let view = makeTerminal()
        let terminal = view.getTerminal()
        terminal.resize(cols: 40, rows: 10)
        bridge.view = view
        view.feed(text: (0..<60).map { "line \($0)" }.joined(separator: "\r\n"))
        let bottom = terminal.getTopVisibleRow()
        #expect(bottom == 50)
        bridge.scrollHalfPage(up: true)
        #expect(terminal.getTopVisibleRow() == bottom - 5)
        bridge.scrollHalfPage(up: false)
        #expect(terminal.getTopVisibleRow() == bottom)
        #expect(sent.isEmpty)
    }
#endif
