import Testing

@testable import TerminalUI

@Test func codexOptionRowsAndWrappedDescriptionsSendTheirDigit() {
    let lines = [
        "Question 2/3 (2 unanswered)",
        "What should the notification contain?",
        "› 1. Realm + count      Keep labels private",
        "                          and low-cardinality.",
        "  2. User identity       Include username/email,",
        "                          requiring a separate path.",
        "  3. None of the above",
        "tab to add notes | enter to submit answer | ←/→ to navigate questions",
    ]

    #expect(CodexOptionTap.shortcut(lines: lines, tappedRow: 2) == UInt8(ascii: "1"))
    #expect(CodexOptionTap.shortcut(lines: lines, tappedRow: 5) == UInt8(ascii: "2"))
    #expect(CodexOptionTap.shortcut(lines: lines, tappedRow: 6) == UInt8(ascii: "3"))
    #expect(CodexOptionTap.shortcut(lines: lines, tappedRow: 1) == nil)
    #expect(CodexOptionTap.shortcut(lines: lines, tappedRow: 7) == nil)
    #expect(CodexOptionTap.shortcut(lines: ["1. ordinary output"], tappedRow: 0) == nil)
}
