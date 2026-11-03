#if os(iOS)
    import Combine
    import Models
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
    private func makeTerminal() -> GhosttyTerminalView {
        let view = GhosttyTerminalView(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        view.layoutIfNeeded()
        return view
    }

    @MainActor
    private func cellPoint(_ view: GhosttyTerminalView, col: Int, row: Int) -> CGPoint {
        let metrics = view.metrics!
        return CGPoint(x: (CGFloat(col) + 0.5) * metrics.pointWidth, y: (CGFloat(row) + 0.5) * metrics.pointHeight)
    }

    @MainActor
    private func gestures(_ view: GhosttyTerminalView, _ bridge: TerminalBridge) -> GhosttyGestureCoordinator {
        view.onSend = { [weak bridge] in bridge?.processOutgoing($0) }
        bridge.view = view
        return GhosttyGestureCoordinator(bridge: bridge, view: view)
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
                let view = makeTerminal()
                let coordinator = gestures(view, bridge)
                view.feed(Data("hello world\r\n".utf8))
                view.startPointerSelection(at: cellPoint(view, col: 0, row: 0))
                view.extendPointerSelection(to: cellPoint(view, col: 6, row: 0))
                #expect(view.grabSelectionHandle(at: cellPoint(view, col: 0, row: 0), slop: 10_000))
                #expect(view.selectionHandleDragActive)
                let pan = StatefulPan()
                view.addGestureRecognizer(pan)
                pan.deliver(state)
                #expect(pan.state == state)
                coordinator.handleScrollPan(pan)
                #expect(!view.selectionHandleDragActive)
            }
        }

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
                let view = makeTerminal()
                let coordinator = gestures(view, TerminalBridge())
                view.feed(Data("hello world\r\n".utf8))
                let start = cellPoint(view, col: 0, row: 0)
                view.startPointerSelection(at: start)
                view.extendPointerSelection(to: cellPoint(view, col: 6, row: 0))
                #expect(view.grabSelectionHandle(at: start, slop: 10_000))
                let pan = PointerPan()
                view.addGestureRecognizer(pan)
                pan.point = start
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
        private func windowedTerminal() -> (GhosttyTerminalView, UIWindow) {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            let view = makeTerminal()
            window.addSubview(view)
            window.makeKeyAndVisible()
            return (view, window)
        }

        @MainActor
        @Test func mouseReportingTapSendsClickWithoutRaisingKeyboard() {
            let bridge = TerminalBridge()
            var sent: [Data] = []
            bridge.sendToHost = { sent.append($0) }
            let (view, window) = windowedTerminal()
            let coordinator = gestures(view, bridge)
            view.feed(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
            #expect(!view.isFirstResponder)
            let tap = EndedTap()
            tap.point = cellPoint(view, col: 0, row: view.terminalRows - 1)
            #expect(!view.tapRaisesKeyboard(at: tap.point))
            view.addGestureRecognizer(tap)
            coordinator.handleTap(tap)
            #expect(!view.isFirstResponder)
            #expect(!sent.isEmpty)
            withExtendedLifetime(window) {}
        }

        @MainActor
        @Test func plainShellTapRaisesKeyboard() {
            let (view, window) = windowedTerminal()
            let coordinator = gestures(view, TerminalBridge())
            #expect(view.tapRaisesKeyboard(at: .zero))
            let tap = EndedTap()
            view.addGestureRecognizer(tap)
            coordinator.handleTap(tap)
            #expect(view.isFirstResponder)
            withExtendedLifetime(window) {}
        }

        @MainActor
        @Test func mouseReportingTapKeepsKeyboardWhenAlreadyUp() {
            let (view, window) = windowedTerminal()
            view.feed(Data("\u{1b}[?1000h".utf8))
            #expect(view.becomeFirstResponder())
            #expect(view.tapRaisesKeyboard(at: cellPoint(view, col: 0, row: view.terminalRows - 1)))
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
            let view = makeTerminal()
            let coordinator = gestures(view, bridge)
            view.multiplexerMode = true
            view.feed(Data("\u{1b}[?1002h\u{1b}[?1006h".utf8))
            let pan = ScriptedPan()
            view.addGestureRecognizer(pan)
            pan.point = CGPoint(x: 55, y: 45)
            pan.moved = CGPoint(x: 20, y: 0)
            pan.forced = .began
            coordinator.handleScrollPan(pan)
            pan.point = CGPoint(x: 205, y: 105)
            pan.forced = .changed
            coordinator.handleScrollPan(pan)
            pan.forced = .ended
            coordinator.handleScrollPan(pan)
            func sgr(_ x: CGFloat, _ y: CGFloat) -> String {
                let cell = view.cell(at: CGPoint(x: x, y: y))
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
            let view = makeTerminal()
            let coordinator = gestures(view, bridge)
            view.multiplexerMode = true
            let swipe = UISwipeGestureRecognizer()
            swipe.direction = .left
            view.addGestureRecognizer(swipe)
            bridge.selectMode = true
            coordinator.handleWindowSwipe(swipe)
            #expect(sent.isEmpty)
            bridge.selectMode = false
            view.feed(Data("hello world\r\n".utf8))
            view.selectWord(at: cellPoint(view, col: 0, row: 0))
            #expect(view.selectionActive)
            coordinator.handleWindowSwipe(swipe)
            #expect(sent.isEmpty)
            view.clearSelection()
            coordinator.handleWindowSwipe(swipe)
            #expect(sent == [Data("\u{02}n".utf8)])
        }

        @MainActor
        @Test func mouseReportingTapOnInputLineRaisesKeyboard() {
            let bridge = TerminalBridge()
            var sent: [Data] = []
            bridge.sendToHost = { sent.append($0) }
            let (view, window) = windowedTerminal()
            let coordinator = gestures(view, bridge)
            let rows = view.terminalRows
            view.feed(Data("\u{1b}[?1000h\u{1b}[?1006h\u{1b}[\(rows - 1);3H".utf8))
            let tap = EndedTap()
            tap.point = cellPoint(view, col: 0, row: rows - 1)
            #expect(view.tapRaisesKeyboard(at: tap.point))
            #expect(!view.tapRaisesKeyboard(at: cellPoint(view, col: 0, row: 0)))
            view.addGestureRecognizer(tap)
            coordinator.handleTap(tap)
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
#endif
