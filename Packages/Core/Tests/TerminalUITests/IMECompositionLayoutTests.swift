import CoreGraphics
import Testing

@testable import TerminalUI

struct IMECompositionLayoutTests {
    private let visible = CGRect(x: 0, y: 0, width: 390, height: 800)

    @Test func sitsOnTheCaretCell() {
        let caret = CGRect(x: 40, y: 120, width: 10, height: 20)
        let frame = IMECompositionLayout.frame(caret: caret, textWidth: 60, textHeight: 18, visible: visible)
        #expect(frame.origin == CGPoint(x: 40, y: 120))
        #expect(frame.width == 60)
        #expect(frame.height == 20)
    }

    @Test func neverShorterThanTheCell() {
        let caret = CGRect(x: 0, y: 0, width: 10, height: 20)
        let frame = IMECompositionLayout.frame(caret: caret, textWidth: 30, textHeight: 26, visible: visible)
        #expect(frame.height == 26)
    }

    @Test func shiftsLeftWhenItWouldOverflowTheRightEdge() {
        let caret = CGRect(x: 360, y: 40, width: 10, height: 20)
        let frame = IMECompositionLayout.frame(caret: caret, textWidth: 100, textHeight: 18, visible: visible)
        #expect(frame.maxX == visible.maxX)
        #expect(frame.minX == 290)
    }

    @Test func clampsToTheLeftEdgeWhenWiderThanTheScreen() {
        let caret = CGRect(x: 200, y: 40, width: 10, height: 20)
        let frame = IMECompositionLayout.frame(caret: caret, textWidth: 900, textHeight: 18, visible: visible)
        #expect(frame.minX == visible.minX)
        #expect(frame.width == visible.width)
    }

    @Test func followsAHorizontallyScrolledViewport() {
        let scrolled = CGRect(x: 50, y: 0, width: 390, height: 800)
        let caret = CGRect(x: 430, y: 40, width: 10, height: 20)
        let frame = IMECompositionLayout.frame(caret: caret, textWidth: 40, textHeight: 18, visible: scrolled)
        #expect(frame.maxX == scrolled.maxX)
    }
}
