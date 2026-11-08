import Testing

@testable import ToolbarUI

@Test func keyboardToggleShowsChevronOnlyWhileKeyboardIsVisible() {
    #expect(KeyboardToggle.icon(keyboardVisible: true) == "keyboard.chevron.compact.down")
    #expect(KeyboardToggle.icon(keyboardVisible: false) == "keyboard")
}
