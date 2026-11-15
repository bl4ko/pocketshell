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

@Test func claudeSingleQuestionFromVersion322ReadsTheTypedAnswerRow() throws {
    let prompt = try #require(InteractivePrompt.read(try screen("claude-ask-single.screen")))
    #expect(prompt.header == "Cache" && prompt.question == "Which database should the cache use?")
    #expect(prompt.options.map(\.label) == ["Redis", "Postgres", "SQLite", "Type something.", "Chat about this"])
    #expect(prompt.listed.map(\.number) == [1, 2, 3, 4])
    #expect(prompt.options[3].isTypeSomething && !prompt.isMultiSelect && prompt.tabs.isEmpty)
    #expect(!prompt.moreAbove && !prompt.moreBelow)
    let typed = try #require(InteractivePrompt.read(try screen("claude-ask-single-typed.screen")))
    #expect(typed.highlighted == 4 && typed.options[3].label == "use the redis cluster in eu")
    #expect(typed.sameQuestion(prompt) && !typed.options[3].isTypeSomething)
}

@Test func claudeScrolledListsReadTheVisibleWindowAndKnowRowsAreHidden() throws {
    let top = try #require(InteractivePrompt.read(try screen("claude-ask-scroll-top.screen")))
    #expect(top.listed.map(\.number) == [1, 2, 3, 4])
    #expect(top.options.last?.isChat == true && top.options.last?.number == 6)
    #expect(!top.moreAbove && top.moreBelow && top.highlighted == 1)
    let bottom = try #require(InteractivePrompt.read(try screen("claude-ask-scroll-bottom.screen")))
    #expect(bottom.listed.map(\.number) == [2, 3, 4, 5])
    #expect(bottom.moreAbove && !bottom.moreBelow && bottom.highlighted == 5)
    #expect(bottom.listed.last?.isTypeSomething == true)
}

@Test func claudeMultiSelectReadsCheckboxesAndTheSubmitButton() throws {
    let fresh = try #require(InteractivePrompt.read(try screen("claude-ask-multi.screen")))
    #expect(fresh.isMultiSelect && fresh.tabs == [.init(label: "Checks", answered: false)] && fresh.header == "Checks")
    #expect(fresh.listed.map(\.label) == ["Unit tests", "UI tests", "Lint", "Coverage", "Type something"])
    #expect(fresh.listed.allSatisfy { $0.checked == false })
    #expect(fresh.options[0].detail == "swift test")
    #expect(fresh.button == .init(label: "Submit", highlighted: false))
    let submit = try #require(InteractivePrompt.read(try screen("claude-ask-multi-submit.screen")))
    #expect(submit.highlighted == nil && submit.button == .init(label: "Submit", highlighted: true))
    #expect(submit.listed.filter { $0.checked == true }.map(\.label) == ["UI tests", "Lint", "fuzz the parser"])
    #expect(submit.tabs == [.init(label: "Checks", answered: true)])
}

@Test func claudeMultiQuestionTabsAndTheReviewStep() throws {
    let second = try #require(InteractivePrompt.read(try screen("claude-ask-tabs-q2.screen")))
    #expect(second.question == "Which features should ship in v1?" && second.header == nil)
    #expect(second.tabs.map(\.label) == ["Auth", "Features", "Logs"])
    #expect(second.tabs.map(\.answered) == [true, false, false])
    #expect(second.button?.label == "Next")
    let next = try #require(InteractivePrompt.read(try screen("claude-ask-tabs-q2-next.screen")))
    #expect(next.button?.highlighted == true && next.sameQuestion(second))

    let open = try #require(InteractivePrompt.read(try screen("claude-ask-review-unanswered.screen")))
    #expect(open.isReview && open.reviewIncomplete)
    #expect(open.options.map(\.label) == ["Submit answers", "Cancel"] && open.highlighted == 1)
    #expect(open.tabs.map(\.answered) == [true, true, false])
    #expect(open.context.contains("Which features should ship in v1?"))
    let done = try #require(InteractivePrompt.read(try screen("claude-ask-review-complete.screen")))
    #expect(done.isReview && !done.reviewIncomplete && done.tabs.allSatisfy(\.answered))
    #expect(!done.sameQuestion(second))
}

@Test func unnumberedArrowListsReadTheHighlightedRow() throws {
    let trust = try #require(InteractivePrompt.read(try screen("claude-trust.screen")))
    #expect(!trust.numbered && trust.options.map(\.label) == ["No, exit", "Yes, I trust this folder"])
    #expect(trust.highlighted == 1)
    let key = try #require(InteractivePrompt.read(try screen("claude-apikey.screen")))
    #expect(key.question == "Do you want to use this API key?")
    #expect(key.options.map(\.label) == ["Yes", "No (recommended)"] && key.highlighted == 2)
}

@Test func claudePermissionFromVersion322AndTheCodexSubmitConfirmation() throws {
    let permission = try #require(InteractivePrompt.read(try screen("claude-permission-auto.screen")))
    #expect(permission.question == "Do you want to proceed?")
    #expect(permission.options.map(\.number) == [1, 2, 3, 4] && permission.options.last?.label == "No")
    let confirm = try #require(InteractivePrompt.read(try screen("codex-unanswered.screen")))
    #expect(confirm.isSubmitConfirmation && confirm.options.map(\.label) == ["Proceed", "Go back"])
    let codex = try #require(InteractivePrompt.read(try screen("codex-question.screen")))
    #expect(codex.progress?.index == 2 && codex.progress?.total == 3)
    #expect(codex.options.last?.isTypeSomething == true)
}

extension InteractivePrompt {
    fileprivate var listed: [Option] { options.filter { !$0.isChat } }
}

@Test func codexQuestionsFromVersion169ReadProgressAndNotes() throws {
    let question = try #require(InteractivePrompt.read(try screen("codex-question-169.screen")))
    #expect(question.header == "Question 1/2 (2 unanswered)" && question.progress?.total == 2)
    #expect(question.question == "Which realm should the alert watch?")
    #expect(question.options.map(\.label) == ["Home", "Lab", "None of the above"] && question.highlighted == 1)
    let notes = try #require(InteractivePrompt.read(try screen("codex-notes.screen")))
    #expect(notes.highlighted == 3 && notes.sameQuestion(question))
    #expect(notes.progress?.index == 1 && notes.question == question.question)
    #expect(try screen("codex-notes.screen").contains("to clear notes"))
}
