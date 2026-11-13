import Foundation
import Testing

@testable import MonitorKit

private func screen(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func claudeAskUserQuestionReadsHeaderQuestionOptionsAndFreeTextRows() throws {
    let prompt = try #require(InteractivePrompt.read(try screen("ask-unifi.screen")))
    #expect(prompt.header == "UniFi site")
    #expect(
        prompt.question
            == "UniFi auto-update is one site-wide setting: it covers switches, UPS 2U and the U7 Pro AP "
            + "(gateway is separate, stays on). Turn it off site-wide?")
    #expect(prompt.context.isEmpty)
    #expect(prompt.options.map(\.number) == [1, 2, 3, 4])
    #expect(prompt.choices.map(\.label) == ["Off site-wide (Recommended)", "Keep on"])
    #expect(
        prompt.options[0].detail
            == "Switches, UPS and AP update only in the monthly window; new alerts tell when firmware is waiting.")
    #expect(prompt.options[1].detail == "Only the alerts; accept night etcd outages.")
    #expect(prompt.options.filter(\.freeText).map(\.label) == ["Type something.", "Chat about this"])
    #expect(prompt.highlighted == 1)
}

@Test func claudePermissionPromptKeepsTheCommandAsContext() throws {
    let prompt = try #require(InteractivePrompt.read(try screen("claude-permission.screen")))
    #expect(prompt.header == nil)
    #expect(prompt.question == "Do you want to proceed?")
    #expect(prompt.context == ["Bash command", "git push origin main", "Push the release commit to the remote"])
    #expect(
        prompt.options.map(\.label) == [
            "Yes", "Yes, and don't ask again for git push commands in /home/dev/src/api",
            "No, and tell Claude what to do differently (esc)",
        ])
    #expect(prompt.choices.count == 3)
    #expect(prompt.highlighted == 1)
}

@Test func codexQuestionOverlaySplitsLabelsFromWrappedDescriptions() throws {
    let prompt = try #require(InteractivePrompt.read(try screen("codex-question.screen")))
    #expect(prompt.header == "Question 2/3 (2 unanswered)")
    #expect(prompt.question == "What should the notification contain?")
    #expect(prompt.options.map(\.label) == ["Realm + count", "User identity", "None of the above"])
    #expect(prompt.options[0].detail == "Keep labels private and low-cardinality.")
    #expect(prompt.options[1].detail == "Include username/email, requiring a separate path.")
    #expect(prompt.options.allSatisfy { !$0.freeText })
    #expect(prompt.highlighted == 1)
}

@Test func codexApprovalWithoutARuleStopsAtTheQuestion() throws {
    let prompt = try #require(InteractivePrompt.read(try screen("codex-approval.screen")))
    #expect(prompt.question == "Would you like to run the following command?")
    #expect(prompt.context == ["Reason: remove stale build output", "$ rm -rf build"])
    #expect(prompt.options.count == 3)
}

@Test func numberedOutputWithoutASelectionFooterIsNoPrompt() throws {
    #expect(InteractivePrompt.read(try screen("numbered-output.screen")) == nil)
    let noHighlight = "Pick one?\n  1. a\n  2. b\n\nEnter to select · ↑/↓ to navigate · Esc to cancel"
    #expect(InteractivePrompt.read(noHighlight) == nil)
    let footerFarAbove =
        "Pick one?\n❯ 1. a\n  2. b\nEnter to select · Esc to cancel\n⏺ Done.\nmore output\n> \n? for shortcuts"
    #expect(InteractivePrompt.read(footerFarAbove) == nil)
    let gap = "Pick one?\n❯ 1. a\n  3. c\n\nEnter to select · Esc to cancel"
    #expect(InteractivePrompt.read(gap) == nil)
}
