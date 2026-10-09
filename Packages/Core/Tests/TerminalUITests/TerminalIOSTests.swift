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
#endif
