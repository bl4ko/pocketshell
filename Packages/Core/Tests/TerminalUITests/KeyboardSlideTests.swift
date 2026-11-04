import CoreGraphics
import Testing

@testable import TerminalUI

struct KeyboardSlideTests {
    let line: CGFloat = 20
    let height: CGFloat = 800
    let keyboard: CGFloat = 300

    func caret(row: Int) -> CaretPlacement {
        CaretPlacement(top: CGFloat(row) * line, lineHeight: line, viewHeight: height)
    }

    func opened(at row: Int) -> KeyboardSlide {
        var slide = KeyboardSlide()
        slide.follow(caret(row: row), keyboard: 0)
        slide.follow(caret(row: row), keyboard: keyboard)
        return slide
    }

    @Test func caretNearTheTopKeepsTheContentStill() {
        let slide = opened(at: 7)
        #expect(slide.offset(keyboard: keyboard) == 0)
        #expect(slide.offset(keyboard: keyboard / 2) == 0)
    }

    @Test func caretOnTheLastRowSlidesTheWholeKeyboard() {
        let slide = opened(at: 39)
        #expect(slide.offset(keyboard: keyboard) == keyboard)
        #expect(slide.offset(keyboard: 120) == 120)
    }

    @Test func caretInTheMiddleSlidesOnlyToKeepTheFooterAboveTheKeyboard() {
        let slide = opened(at: 25)
        let visibleBottom = height - keyboard + slide.offset(keyboard: keyboard)
        #expect(visibleBottom == CGFloat(25 + 1 + 3) * line)
        #expect(slide.offset(keyboard: 0) == 0)
    }

    @Test func slideFollowsTheKeyboardOnlyOnceItReachesTheFooter() {
        let slide = opened(at: 25)
        #expect(slide.offset(keyboard: 220) == 0)
        #expect(slide.offset(keyboard: 250) == 30)
        #expect(slide.offset(keyboard: keyboard) == 80)
    }

    @Test func caretMovingDownGrowsTheSlide() {
        var slide = opened(at: 7)
        slide.follow(caret(row: 30), keyboard: keyboard)
        #expect(slide.offset(keyboard: keyboard) == 180)
    }

    @Test func caretMovingWithinTheVisibleRowsHoldsTheSlide() {
        var slide = opened(at: 30)
        for row in [24, 29, 12, 30, 10] {
            slide.follow(caret(row: row), keyboard: keyboard)
            #expect(slide.offset(keyboard: keyboard) == 180)
        }
    }

    @Test func caretAboveTheVisibleTopShrinksTheSlide() {
        var slide = opened(at: 39)
        slide.follow(caret(row: 2), keyboard: keyboard)
        #expect(slide.offset(keyboard: keyboard) == 20)
        slide.follow(caret(row: 0), keyboard: keyboard)
        #expect(slide.offset(keyboard: keyboard) == 0)
    }

    @Test func unknownCaretSlidesTheWholeKeyboard() {
        var slide = KeyboardSlide()
        slide.follow(nil, keyboard: keyboard)
        #expect(slide.offset(keyboard: keyboard) == keyboard)
        #expect(slide.offset(keyboard: 0) == 0)
    }

    @Test func missingCaretKeepsTheLastSlide() {
        var slide = opened(at: 30)
        slide.follow(nil, keyboard: keyboard)
        #expect(slide.offset(keyboard: keyboard) == 180)
    }

    @Test func closedKeyboardTracksTheCaretAgain() {
        var slide = opened(at: 39)
        slide.follow(caret(row: 3), keyboard: 0)
        slide.follow(caret(row: 3), keyboard: keyboard)
        #expect(slide.offset(keyboard: keyboard) == 0)
    }

    @Test func hidingKeepsTheHeldSlideWhileTheKeyboardLeaves() {
        var slide = opened(at: 39)
        slide.follow(caret(row: 7), keyboard: keyboard)
        #expect(slide.offset(keyboard: keyboard) == 120)
        slide.follow(caret(row: 7), keyboard: 0)
        #expect(slide.offset(keyboard: keyboard) == 120)
        #expect(slide.offset(keyboard: 200) == 20)
        #expect(slide.offset(keyboard: 150) == 0)
    }

    @Test func reopeningStartsFromTheCaret() {
        var slide = opened(at: 39)
        slide.follow(caret(row: 7), keyboard: keyboard)
        slide.follow(caret(row: 7), keyboard: 0)
        slide.follow(caret(row: 7), keyboard: keyboard)
        #expect(slide.offset(keyboard: keyboard) == 0)
    }

    @Test func smallerKeyboardSlidesLess() {
        var slide = opened(at: 39)
        slide.follow(caret(row: 39), keyboard: 100)
        #expect(slide.offset(keyboard: 100) == 100)
        slide.follow(caret(row: 30), keyboard: 100)
        #expect(slide.offset(keyboard: 100) == 100)
        slide.follow(caret(row: 4), keyboard: 100)
        #expect(slide.offset(keyboard: 100) == 60)
    }
}
