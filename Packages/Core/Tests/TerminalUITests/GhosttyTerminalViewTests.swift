#if os(iOS)
    import Foundation
    import Models
    import Testing
    import UIKit
    import VTKit

    @testable import TerminalUI

    @MainActor
    private func makeGhostty(width: CGFloat = 400, height: CGFloat = 300) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutIfNeeded()
        return view
    }

    @MainActor
    private func point(_ view: GhosttyTerminalView, col: Int, row: Int) -> CGPoint {
        let metrics = view.metrics!
        return CGPoint(
            x: (CGFloat(col) + 0.5) * metrics.pointWidth, y: (CGFloat(row) + 0.5) * metrics.pointHeight)
    }

    @MainActor
    @Suite(.serialized)
    struct GhosttyTerminalViewTests {
        @Test func layoutSizesTheGridFromTheFont() {
            let view = makeGhostty()
            var reported: (Int, Int)?
            view.onResize = { reported = ($0, $1) }
            view.frame.size.height = 200
            view.layoutIfNeeded()
            let metrics = view.metrics!
            #expect(view.terminalCols == Int(400 * metrics.scale) / metrics.width)
            #expect(view.terminalRows == Int(200 * metrics.scale) / metrics.height)
            #expect(reported?.1 == view.terminalRows)
        }

        @Test func screenLinesScrubNUL() {
            let view = makeGhostty()
            view.feedEngine(Data("export\u{1b}[1CTART_HOME".utf8))
            #expect(view.screenLines()[0] == "export TART_HOME")
        }

        @Test func pointerSelectionIncludesBothEnds() {
            let view = makeGhostty()
            view.feedEngine(Data("hello world".utf8))
            view.startPointerSelection(at: point(view, col: 4, row: 0))
            view.extendPointerSelection(to: point(view, col: 0, row: 0))
            #expect(view.selectedText() == "hello")
            view.startPointerSelection(at: point(view, col: 6, row: 0))
            view.extendPointerSelection(to: point(view, col: 10, row: 0))
            #expect(view.selectedText() == "world")
        }

        @Test func handleDragKeepsTheGrabbedEdge() {
            let view = makeGhostty()
            view.feedEngine(Data("hello world".utf8))
            view.startPointerSelection(at: point(view, col: 6, row: 0))
            view.extendPointerSelection(to: point(view, col: 10, row: 0))
            let metrics = view.metrics!
            let nearStart = CGPoint(x: 6 * metrics.pointWidth + 3, y: 4)
            #expect(view.grabSelectionHandle(at: nearStart, slop: 30))
            #expect(view.selectedText() == "world")
            view.dragSelectionHandle(to: nearStart)
            #expect(view.selectedText() == "world")
            view.dragSelectionHandle(to: CGPoint(x: nearStart.x - metrics.pointWidth * 2, y: nearStart.y))
            #expect(view.selectedText() == "o world")
            view.endSelectionHandleDrag()
            #expect(!view.selectionHandleDragActive)
        }

        @Test func wordAndRowSelection() {
            let view = makeGhostty()
            view.feedEngine(Data("foo barbaz qux".utf8))
            view.selectWord(at: point(view, col: 5, row: 0))
            #expect(view.selectedText() == "barbaz")
            view.selectRow(at: point(view, col: 0, row: 0))
            #expect(view.selectedText() == "foo barbaz qux")
            view.clearSelection()
            #expect(!view.selectionActive)
        }

        @Test func editMenuOffersCopyOnlyWithASelection() {
            let view = makeGhostty()
            view.feedEngine(Data("foo bar".utf8))
            let copy = #selector(UIResponderStandardEditActions.copy(_:))
            let paste = #selector(UIResponderStandardEditActions.paste(_:))
            #expect(!view.canPerformAction(copy, withSender: nil))
            #expect(view.canPerformAction(paste, withSender: nil))
            view.selectWord(at: point(view, col: 5, row: 0))
            #expect(view.canPerformAction(copy, withSender: nil))
        }

        @Test func copyPutsSelectionOnThePasteboard() {
            let view = makeGhostty()
            var copied: [String] = []
            view.writePasteboard = { copied.append($0) }
            view.feedEngine(Data("copy\u{1b}[2Cme".utf8))
            view.startPointerSelection(at: point(view, col: 0, row: 0))
            view.extendPointerSelection(to: point(view, col: 7, row: 0))
            view.copySelectionToPasteboard()
            view.feedEngine(Data("\u{1b}]52;c;aGk=\u{07}".utf8))
            #expect(copied == ["copy  me", "hi"])
            #expect(!view.selectionActive)
        }

        @Test func scrollingUpdatesAccessibilityPosition() {
            let view = makeGhostty()
            view.feedEngine(Data((0..<100).map { "line \($0)" }.joined(separator: "\r\n").utf8))
            #expect(view.accessibilityValue == "bottom")
            view.scrollViewport(up: 5)
            #expect(view.accessibilityValue == "history")
            #expect(!view.scrolledToBottom)
            view.scrollViewport(up: -5)
            #expect(view.accessibilityValue == "bottom")
        }

        @Test func typedOutputScrollsBackToTheBottom() {
            let view = makeGhostty()
            var sent: [Data] = []
            view.onSend = { sent.append($0) }
            view.feedEngine(Data((0..<100).map { "line \($0)" }.joined(separator: "\r\n").utf8))
            view.scrollViewport(up: 5)
            view.insertText("x")
            #expect(sent == [Data("x".utf8)])
            #expect(view.scrolledToBottom)
        }

        @Test func returnKeySendsCarriageReturn() {
            let view = makeGhostty()
            var sent: [Data] = []
            view.onSend = { sent.append($0) }
            view.insertText("\n")
            view.deleteBackward()
            #expect(sent == [Data([0x0d]), Data([0x7f])])
        }

        @Test func markedTextReportsCompositionAndCommits() {
            let view = makeGhostty()
            var sent: [Data] = []
            var composing: [String] = []
            view.onSend = { sent.append($0) }
            view.markedTextObserver = { text, _ in composing.append(text) }
            view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            #expect(sent.isEmpty)
            view.unmarkText()
            #expect(sent == [Data("に".utf8)])
            #expect(composing == ["に", ""])
        }

        @Test func codexOptionTapSendsDigitOnScrolledScreen() {
            let bridge = TerminalBridge()
            var sent: [Data] = []
            bridge.sendToHost = { sent.append($0) }
            let view = makeGhostty()
            let gestures = GhosttyGestureCoordinator(bridge: bridge, view: view)
            var text = (0..<20).map { "head \($0)" }
            text += ["Question 1/1", "1. Alpha", "2. Beta", "3. Gamma", "enter to submit answer"]
            text += (0..<40).map { "filler \($0)" }
            view.feedEngine(Data((text.joined(separator: "\r\n") + "\r\n").utf8))
            view.scrollViewport(up: 30)
            let rows = view.screenLines()
            let optionRow = try! #require(rows.firstIndex(of: "2. Beta"))
            gestures.sendMouseClick(at: point(view, col: 1, row: optionRow))
            #expect(sent == [Data([UInt8(ascii: "2")])])
        }

        @Test func tapReportsMouseClickWhenTracking() {
            let bridge = TerminalBridge()
            var sent: [Data] = []
            bridge.sendToHost = { sent.append($0) }
            let view = makeGhostty()
            view.onSend = { [weak bridge] in bridge?.processOutgoing($0) }
            let gestures = GhosttyGestureCoordinator(bridge: bridge, view: view)
            view.feedEngine(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
            gestures.sendMouseClick(at: point(view, col: 2, row: 3))
            #expect(sent == [Data("\u{1b}[<0;3;4M".utf8), Data("\u{1b}[<0;3;4m".utf8)])
        }

        @Test func bridgeRoutesThroughTheGhosttyEngine() {
            let bridge = TerminalBridge()
            let view = makeGhostty()
            bridge.view = view
            bridge.feed(Data("\u{1b}[?2004h\u{1b}[?1049hFULL".utf8))
            #expect(bridge.isFullScreenApp)
            #expect(bridge.visibleText().hasPrefix("FULL"))
            var sent: [Data] = []
            bridge.sendToHost = { sent.append($0) }
            bridge.sendPasted("x")
            #expect(sent == [Data("\u{1b}[200~x\u{1b}[201~".utf8)])
            #expect(bridge.currentSize.cols == view.terminalCols)
        }

        @Test func hiddenTabsSkipRenderingAndRepaintWhenShown() {
            let bridge = TerminalBridge()
            let view = makeGhostty()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            window.addSubview(view)
            bridge.view = view
            bridge.setLive(false)
            #expect(view.layer.isHidden)
            let before = view.renderCount
            bridge.feed(Data("background output".utf8))
            view.tick()
            #expect(view.renderCount == before)
            #expect(view.drawableReleasedForHiddenLayer)
            bridge.setLive(true)
            #expect(!view.layer.isHidden)
            #expect(!view.drawableReleasedForHiddenLayer)
            view.tick()
            #expect(view.renderCount == before + 1)
        }

        @Test func shrinkingFullScreenAppKeepsHeader() {
            let view = makeGhostty(height: 300)
            let rows = view.terminalRows
            view.feedEngine(Data("\u{1b}[?1049h\u{1b}[1;1HHEADER\u{1b}[\(rows);1HPROMPT".utf8))
            view.frame.size.height = 150
            view.layoutIfNeeded()
            #expect(view.screenLines()[0] == "HEADER")
        }

        @Test func themeColorsReachTheTerminal() throws {
            let view = makeGhostty()
            view.applyEngineTheme(.pocketshell)
            view.terminal.updateScreen()
            let hex = TerminalTheme.pocketshell.background
            let background = try #require(RGBColor(hex: hex))
            #expect(view.terminal.screen.background == VTColor(background))
        }

        @Test func halfPageScrollUsesWheelOnlyWhenMouseReporting() {
            let bridge = TerminalBridge()
            var sent = ""
            bridge.sendToHost = { sent += String(decoding: $0, as: UTF8.self) }
            let view = makeGhostty()
            view.onSend = { [weak bridge] in bridge?.processOutgoing($0) }
            bridge.view = view
            view.feedEngine(Data((0..<100).map { "line \($0)" }.joined(separator: "\r\n").utf8))
            bridge.scrollHalfPage(up: true)
            #expect(!view.scrolledToBottom)
            #expect(sent.isEmpty)
            bridge.scrollHalfPage(up: false)
            #expect(view.scrolledToBottom)
            view.feedEngine(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
            bridge.scrollHalfPage(up: true)
            let center = "\u{1b}[<64;\(view.terminalCols / 2 + 1);\(view.terminalRows / 2 + 1)M"
            #expect(sent == String(repeating: center, count: max(1, view.terminalRows / 6)))
        }

        @Test func synchronizedOutputHoldsTheFrame() {
            let view = makeGhostty()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            window.addSubview(view)
            view.tick()
            let before = view.renderCount
            view.feedEngine(Data("\u{1b}[?2026hhalf".utf8))
            view.tick()
            #expect(view.renderCount == before)
            view.feedEngine(Data("done\u{1b}[?2026l".utf8))
            view.tick()
            #expect(view.renderCount == before + 1)
        }

        @Test func programBackgroundOverrideDoesNotBeatTheTheme() {
            let view = makeGhostty()
            view.applyEngineTheme(.pocketshell)
            let themed = view.renderBackground
            view.feedEngine(Data("\u{1b}]11;#000000\u{07}".utf8))
            #expect(view.renderBackground == themed)
            #expect(themed != VTColor(r: 0, g: 0, b: 0))
        }

        @Test func tmuxRedrawTransactionParksTheCaretAtTheFinalPosition() {
            let view = makeGhostty()
            view.multiplexerMode = true
            view.feedEngine(Data("\u{1b}[5;3H".utf8))
            #expect(view.committedCaret.map { [$0.row, $0.col] } == [4, 2])
            view.feedEngine(Data("\u{1b}[?25l\u{1b}[10;42Hpane".utf8))
            #expect(view.committedCaret.map { [$0.row, $0.col] } == [4, 2])
            view.feedEngine(Data("\u{1b}[1;1H\u{1b}[?25h".utf8))
            #expect(view.committedCaret.map { [$0.row, $0.col] } == [0, 0])
            view.feedEngine(Data("\u{1b}[12;30Hmid-frame".utf8))
            #expect(view.committedCaret.map { [$0.row, $0.col] } == [0, 0])
        }

        @Test func slidContentOutsideTheMaskTakesNoTouches() {
            let container = UIView(frame: CGRect(x: 0, y: 100, width: 400, height: 300))
            let mask = CAShapeLayer()
            mask.path = CGPath(rect: CGRect(x: 0, y: 0, width: 400, height: 300), transform: nil)
            container.layer.mask = mask
            let view = makeGhostty()
            view.frame.origin.y = -80
            container.addSubview(view)
            #expect(!view.point(inside: CGPoint(x: 50, y: 40), with: nil))
            #expect(view.point(inside: CGPoint(x: 50, y: 120), with: nil))
            container.layer.mask = nil
            container.clipsToBounds = true
            #expect(!view.point(inside: CGPoint(x: 50, y: 40), with: nil))
            #expect(view.point(inside: CGPoint(x: 50, y: 120), with: nil))
        }

        @Test func caretStaysASteadyBlockWithoutFocus() {
            let view = makeGhostty()
            view.feedEngine(Data("\u{1b}[3;5H".utf8))
            #expect(!view.isFirstResponder)
            #expect(view.committedCaret?.style == .block)
        }

        @Test func keyRepeatMatchesHardwareRates() {
            let view = makeGhostty()
            #expect(view.keyRepeatDelay == 0.3)
            #expect(view.keyRepeatInterval == 1.0 / 30.0)
        }

        @Test func controllerHostsTheSelectedEngine() {
            #expect(TerminalViewController(engine: .ghostty).terminalView is GhosttyTerminalView)
            #expect(TerminalViewController(engine: .swiftTerm).terminalView is BottomAnchoredTerminalView)
        }
    }
#endif
