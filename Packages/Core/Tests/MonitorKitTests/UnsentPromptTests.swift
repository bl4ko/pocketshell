import Foundation
import MonitorKit
import Testing

private func fixture(_ name: String, _ ext: String = "screen.txt") throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func screen(_ name: String) throws -> [String] {
    try fixture(name).components(separatedBy: "\n")
}

@Test func readsClaudeSingleLinePrompt() throws {
    let prompt = try #require(UnsentPrompt.read(screenLines: screen("claude-single")))
    #expect(prompt == UnsentPrompt(agent: .claude, text: "fix the flaky reconnect test please", rows: 1))
}

@Test func readsClaudeMultiLinePrompt() throws {
    let prompt = try #require(UnsentPrompt.read(screenLines: screen("claude-multi")))
    #expect(prompt.text == "first line of the plan\nsecond line here\nthird and final line")
    #expect(prompt.rows == 3)
}

@Test func joinsClaudeWrappedRowsWithSpaces() throws {
    let prompt = try #require(UnsentPrompt.read(screenLines: screen("claude-wrapped")))
    #expect(
        prompt.text
            == "please look at the reconnect state machine and explain why the backoff never resets after a successful handshake, then propose a minimal fix with a regression test that fails before the change and passes after it"
    )
    #expect(prompt.rows == 3)
}

@Test func joinsAHardWrappedWordWithoutASpace() {
    let rule = String(repeating: "─", count: 20)
    let lines = [rule, "❯ see " + String(repeating: "a", count: 12), "  aaaaaaaa done", rule]
    #expect(UnsentPrompt.read(screenLines: lines)?.text == "see " + String(repeating: "a", count: 20) + " done")
}

@Test func keepsBlankLinesAndIgnoresTheBypassFooter() throws {
    let prompt = try #require(UnsentPrompt.read(screenLines: screen("claude-bypass")))
    #expect(prompt.text == "refactor the composer\n\nkeep the draft per host")
    #expect(prompt.rows == 3)
}

@Test func readsAnEmptyClaudeBox() throws {
    let prompt = try #require(UnsentPrompt.read(screenLines: screen("claude-empty")))
    #expect(prompt.agent == .claude)
    #expect(prompt.isEmpty)
}

@Test func treatsClaudePlaceholdersAsEmpty() {
    let rule = String(repeating: "─", count: 40)
    for placeholder in [#"Try "refactor App/ComposerBar.swift""#, "Press up to edit queued messages"] {
        let prompt = UnsentPrompt.read(screenLines: [rule, "❯\u{A0}\(placeholder)", rule, "  ⏵⏵ auto mode on"])
        #expect(prompt?.agent == .claude)
        #expect(prompt?.text == "")
    }
}

@Test func marksCollapsedPastesIncomplete() throws {
    let claude = try #require(UnsentPrompt.read(screenLines: screen("claude-pasted")))
    #expect(claude.text == "intro text [Pasted text #1 +14 lines]")
    #expect(!claude.isComplete)
    let codex = try #require(UnsentPrompt.read(screenLines: screen("codex-pasted"), columns: 100))
    #expect(codex.agent == .codex)
    #expect(!codex.isComplete)
}

@Test func readsCodexPrompts() throws {
    let single = try #require(UnsentPrompt.read(screenLines: screen("codex-single"), columns: 100))
    #expect(single == UnsentPrompt(agent: .codex, text: "fix the flaky reconnect test please", rows: 1))
    let multi = try #require(UnsentPrompt.read(screenLines: screen("codex-multi"), columns: 100))
    #expect(multi.text == "first line of the plan\nsecond line here\nthird and final line")
    let paragraphs = try #require(UnsentPrompt.read(screenLines: screen("codex-paragraphs"), columns: 100))
    #expect(paragraphs.text == "first paragraph\n\nsecond paragraph")
    #expect(paragraphs.rows == 3)
}

@Test func joinsCodexWrappedRows() {
    let lines = ["", "› " + String(repeating: "a", count: 95), "  bb", "", "  ? for shortcuts"]
    #expect(UnsentPrompt.read(screenLines: lines, columns: 100)?.text == String(repeating: "a", count: 95) + " bb")
}

@Test func blanksFaintPlaceholdersFromANSI() throws {
    let lines = UnsentPrompt.plainLines(ansi: try fixture("codex-placeholder", "ansi"))
    let prompt = try #require(UnsentPrompt.read(screenLines: lines, columns: 100))
    #expect(prompt.agent == .codex)
    #expect(prompt.isEmpty)
    #expect(
        UnsentPrompt.plainLines(ansi: "\u{1B}[38;2;136;136;136mkept\u{1B}[0;2m faint\u{1B}[22m back") == [
            "kept       back"
        ])
}

@Test func readsTheHerdrPaneFromANSI() throws {
    let lines = UnsentPrompt.plainLines(ansi: try fixture("herdr-claude", "ansi"))
    #expect(UnsentPrompt.read(screenLines: lines)?.text == "herdr pane text for the parser")
    #expect(UnsentPrompt.read(screenLines: try screen("herdr-claude"))?.text == "herdr pane text for the parser")
}

@Test func ignoresScreensWithoutAnAgentBox() throws {
    #expect(UnsentPrompt.read(screenLines: ["user@host ~ % ls", "App  Packages", "user@host ~ %"]) == nil)
    let codexPlaceholder = try screen("codex-placeholder")
    let update = ["", "› 1. Update now", "  2. Skip", "  3. Skip until next version", "", "  enter continue"]
    #expect(UnsentPrompt.read(screenLines: update, columns: 100) == nil)
    let transcript = ["", "› earlier prompt", "", "• Done.", "  more output", "  even more", "  last line", ""]
    #expect(UnsentPrompt.read(screenLines: transcript, columns: 100) == nil)
    let trust = String(repeating: "─", count: 30)
    #expect(UnsentPrompt.read(screenLines: [trust, " Accessing workspace:", "", " ❯ No, exit", "   Yes"]) == nil)
    #expect(UnsentPrompt.read(screenLines: codexPlaceholder, columns: 100)?.text == "")
}

@Test func clearSequenceAlternatesKillKeysForEveryRow() {
    #expect(UnsentPrompt.clearSequence(rows: 1) == [0x0B, 0x15, 0x0B, 0x15, 0x0B, 0x15])
    #expect(UnsentPrompt(agent: .codex, text: "a\nb", rows: 2).clearSequence.count == 10)
}

@Test func prefillStartsFromTheBoxOnlyWhenTheDraftAllowsIt() {
    let box = UnsentPrompt(agent: .claude, text: "half written", rows: 1)
    #expect(
        ComposerPrefill.resolve(draft: "", replacesBox: false, box: box)
            == ComposerPrefill(draft: "half written", replacesBox: true))
    #expect(
        ComposerPrefill.resolve(draft: "half written", replacesBox: false, box: box)
            == ComposerPrefill(draft: "half written", replacesBox: true))
    #expect(
        ComposerPrefill.resolve(draft: "my own draft", replacesBox: false, box: box)
            == ComposerPrefill(draft: "my own draft", replacesBox: false))
    #expect(
        ComposerPrefill.resolve(draft: "edited draft", replacesBox: true, box: box)
            == ComposerPrefill(draft: "edited draft", replacesBox: true))
    let pasted = UnsentPrompt(agent: .claude, text: "[Pasted text #1 +9 lines]", rows: 1, isComplete: false)
    #expect(
        ComposerPrefill.resolve(draft: "", replacesBox: false, box: pasted)
            == ComposerPrefill(draft: "", replacesBox: false))
    let empty = UnsentPrompt(agent: .claude, text: "", rows: 1)
    #expect(
        ComposerPrefill.resolve(draft: "kept", replacesBox: true, box: empty)
            == ComposerPrefill(draft: "kept", replacesBox: false))
    #expect(
        ComposerPrefill.resolve(draft: "", replacesBox: false, box: nil)
            == ComposerPrefill(draft: "", replacesBox: false))
}

@Test func closingDropsAnUntouchedPrefillOnly() {
    #expect(
        ComposerPrefill.closing(draft: "box text", replacesBox: true, prefilled: "box text")
            == ComposerPrefill(draft: "", replacesBox: false))
    #expect(
        ComposerPrefill.closing(draft: "box text, edited", replacesBox: true, prefilled: "box text")
            == ComposerPrefill(draft: "box text, edited", replacesBox: true))
    #expect(
        ComposerPrefill.closing(draft: "mine", replacesBox: false, prefilled: "mine")
            == ComposerPrefill(draft: "mine", replacesBox: false))
}
