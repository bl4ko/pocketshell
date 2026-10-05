import Testing

@testable import TerminalUI

struct ArrowPromptTests {
    @Test func recognizesClaudeAndCodexSelectionFooters() {
        for footer in [
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
            "enter to submit answer | ←/→ to navigate questions",
            "Use arrow keys to navigate. Enter to confirm.",
            "↑↓ to select, Enter to select",
        ] {
            var prompt = ArrowPrompt()
            #expect(prompt.update(lines: ["› 1. Mitigate", "  2. Upgrade", footer]) == true)
        }
    }

    @Test func supportsHerdrSidebarAndWrappedFooter() {
        var prompt = ArrowPrompt()
        #expect(
            prompt.update(lines: [
                "github │ › 1. Mitigate, keep Pis (Recommended)",
                "       │   2. Buy 16 GB boards",
                "       │ Enter to select · ↑/↓ to navigate",
                "       │ · Esc to cancel",
                "       └─────────────────────────",
                "         infrastructure",
            ]) == true)
    }

    @Test func ignoresNormalOutputAndOldScrollbackInstructions() {
        var prompt = ArrowPrompt()
        #expect(prompt.update(lines: ["1. Run tests", "2. Build", "$ "]) == nil)
        #expect(prompt.update(lines: ["↑/↓ to navigate", "$ "]) == nil)
        #expect(prompt.update(lines: ["Enter to select", "$ "]) == nil)
        #expect(
            prompt.update(lines: ["Enter to select · ↑/↓ to navigate"] + Array(repeating: "output", count: 6)) == nil)
    }

    @Test func emitsOnlyPromptTransitions() {
        var prompt = ArrowPrompt()
        let now = ContinuousClock.now
        let lines = ["Enter to select · ↑/↓ to navigate · Esc to cancel"]
        #expect(prompt.update(lines: lines) == true)
        #expect(prompt.update(lines: lines) == nil)
        #expect(prompt.update(lines: ["Done", "$ "], at: now) == nil)
        #expect(prompt.needsRecheck)
        #expect(prompt.update(lines: ["Done", "$ "], at: now.advanced(by: .milliseconds(500))) == false)
        #expect(!prompt.needsRecheck)
        #expect(prompt.update(lines: ["Done", "$ "], at: now.advanced(by: .seconds(1))) == nil)
        #expect(prompt.update(lines: lines) == true)
    }

    @Test func ignoresFooterGapsDuringResizeAndRepaint() {
        var prompt = ArrowPrompt()
        let now = ContinuousClock.now
        let lines = ["Enter to select · ↑/↓ to navigate · Esc to cancel"]
        #expect(prompt.update(lines: lines, at: now) == true)
        #expect(prompt.update(lines: [], at: now.advanced(by: .milliseconds(100))) == nil)
        #expect(prompt.update(lines: [], at: now.advanced(by: .milliseconds(250))) == nil)
        #expect(prompt.update(lines: lines, at: now.advanced(by: .milliseconds(400))) == nil)
        #expect(!prompt.needsRecheck)
        #expect(prompt.update(lines: [], at: now.advanced(by: .milliseconds(500))) == nil)
        #expect(prompt.update(lines: [], at: now.advanced(by: .seconds(1))) == false)
    }
}
