import Testing

@testable import ToolbarUI

@Test func enterIsTheRightmostToolbarKeyLikeTheKeyboardReturnKey() {
    #expect(
        ToolbarSlot.allCases == [.shortcuts, .ctrl, .escape, .tab, .attach, .clipboard, .voice, .keyboard, .enter])
}
