import Testing

@testable import TerminalUI

@Test func showingKeepsFullLayoutUntilKeyboardSettles() {
    var inset = KeyboardInset()
    inset.move(to: 300)
    #expect(inset.layout == 0)
    inset.settle(300)
    #expect(inset.layout == 300)
}

@Test func hidingGrowsLayoutImmediately() {
    var inset = KeyboardInset(300)
    inset.move(to: 0)
    #expect(inset.layout == 0)
}

@Test func staleSettleAfterReversalIsIgnored() {
    var inset = KeyboardInset(300)
    inset.move(to: 0)
    inset.move(to: 300)
    inset.settle(0)
    #expect(inset.layout == 0)
    inset.settle(300)
    #expect(inset.layout == 300)
}

@Test func hidingMidShowNeverLeavesLayoutAboveKeyboard() {
    var inset = KeyboardInset()
    inset.move(to: 300)
    inset.move(to: 120)
    #expect(inset.layout == 0)
    inset.settle(300)
    #expect(inset.layout == 0)
    inset.settle(120)
    #expect(inset.layout == 120)
}

@Test func keyboardMoveOnActiveTabAnimates() {
    #expect(KeyboardInset.animates(from: (0, true), to: (300, true)))
    #expect(KeyboardInset.animates(from: (300, true), to: (0, true)))
}

@Test func tabSwitchAndInitialValueJump() {
    #expect(!KeyboardInset.animates(from: (300, true), to: (300, true)))
    #expect(!KeyboardInset.animates(from: (0, false), to: (300, true)))
    #expect(!KeyboardInset.animates(from: (300, true), to: (300, false)))
    #expect(!KeyboardInset.animates(from: (0, false), to: (300, false)))
}
