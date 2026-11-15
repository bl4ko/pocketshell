import Foundation
import MonitorKit
import Testing
import TmuxKit

@testable import BrainKit

private let claudeAgent = BrainAgent(
    kind: .claude, name: "api", location: .tmux(session: "work", windowIndex: 2, windowID: "@7", paneID: "%3"),
    status: .waiting)

private func cache() -> FakeClaudeAsk.Question {
    .init(
        header: "Cache", text: "Which database should the cache use?",
        options: [
            ("Redis", "In-memory, already deployed in the cluster."), ("Postgres", "One less service; slower."),
            ("SQLite", "Local file per pod."),
        ])
}

private func regions() -> FakeClaudeAsk.Question {
    .init(
        header: "Region", text: "Which region should the new bucket live in?",
        options: [
            ("eu-central-1", "Frankfurt"), ("eu-west-1", "Ireland"), ("us-east-1", "Virginia"),
            ("ap-south-1", "Mumbai"),
        ])
}

private func checks() -> FakeClaudeAsk.Question {
    .init(
        header: "Checks", text: "Which checks should run before the build?",
        options: [
            ("Unit tests", "swift test"), ("UI tests", "Simulator e2e"), ("Lint", "swift format lint"),
            ("Coverage", "llvm-cov report"),
        ], multi: true)
}

private func tabs() -> [FakeClaudeAsk.Question] {
    [
        .init(
            header: "Auth", text: "Which auth method should the API use?",
            options: [("OAuth", "Through the identity provider"), ("API keys", "Static keys per client")]),
        .init(
            header: "Features", text: "Which features should ship in v1?",
            options: [("Search", "Full-text search"), ("Export", "CSV export"), ("Webhooks", "Outgoing events")],
            multi: true),
        .init(
            header: "Logs", text: "Where should logs go?",
            options: [("Loki", "Cluster Loki"), ("Files", "Local files")]),
    ]
}

@MainActor
private func toolbox(_ pane: FakePane, turns: [String]? = nil) -> AgentToolbox {
    let box = AgentToolbox(io: .init(exec: { pane.exec($0) }, focus: { _ in true }, sleep: { _ in }))
    box.spokenTurns = turns
    return box
}

@MainActor
private func answer(_ box: AgentToolbox, _ arguments: String) async throws -> [String: Any] {
    let result = await box.call(ToolCall(id: "1", name: "answer_question", arguments: arguments))
    return try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
}

@MainActor
@Test func menuDriverWalksAScrollingListAndCollectsEveryRow() async throws {
    let pane = FakeClaudeAsk([regions()], window: 2)
    let menu = MenuDriver(
        agent: claudeAgent, exec: { pane.exec($0) }, sleep: { _ in }, parse: InteractivePrompt.read,
        same: { $0.sameQuestion($1) })
    let first = try #require(InteractivePrompt.read(pane.screen()))
    #expect(first.items.map(\.number) == [1, 2])
    #expect(first.moreBelow && !first.moreAbove)
    let moved = try #require(await menu.move(from: first, to: 4))
    #expect(moved.highlightedNumber == 4 && moved.moreAbove && moved.moreBelow)
    #expect(pane.focus == 3)
    let (items, last) = await menu.collect(moved)
    #expect(items.map(\.label) == ["eu-central-1", "eu-west-1", "us-east-1", "ap-south-1", "Type something."])
    #expect(!last.moreBelow)
    #expect(pane.outcome == nil && pane.answered.isEmpty)
    #expect(!pane.inputs.contains(.key("Enter")))
}

@MainActor
@Test func menuDriverGivesUpWhenTheHighlightDoesNotMove() async throws {
    let pane = FakeStatic(try fixture("claude-permission.screen.txt"))
    let menu = MenuDriver(
        agent: claudeAgent, exec: { pane.exec($0) }, sleep: { _ in }, parse: InteractivePrompt.read,
        same: { $0.sameQuestion($1) })
    let prompt = try #require(InteractivePrompt.read(pane.screen()))
    #expect(await menu.move(from: prompt, to: 3) == nil)
}

@MainActor
@Test func answerQuestionMovesTheHighlightAndSelectsInsteadOfTypingADigit() async throws {
    let pane = FakeClaudeAsk([cache()])
    let result = try await answer(toolbox(pane), #"{"agent":"api","option":"postgres"}"#)
    #expect(result["done"] as? String == "Answered." && result["next"] == nil)
    #expect(pane.outcome == "answered" && pane.answered[0] == "Postgres")
    #expect(pane.pressedKeys == ["Down", "Enter"])
}

@MainActor
@Test func answerQuestionScrollsToAnOptionBelowTheVisibleRows() async throws {
    let pane = FakeClaudeAsk([regions()], window: 2)
    let result = try await answer(toolbox(pane), #"{"agent":"api","option":"Mumbai"}"#)
    #expect(result["done"] as? String == "Answered.")
    #expect(pane.answered[0] == "ap-south-1" && pane.outcome == "answered")
}

@MainActor
@Test func multiSelectChecksExactlyTheNamedOptionsThenSubmits() async throws {
    let pane = FakeClaudeAsk([checks()])
    pane.checked[0] = [3]
    let result = try await answer(toolbox(pane), #"{"agent":"api","options":["ui tests","lint"]}"#)
    #expect(result["done"] as? String == "Answered." && result["next"] == nil)
    #expect(pane.outcome == "answered")
    #expect(pane.answered[0] == "UI tests, Lint")
    #expect(pane.pressedKeys.filter { $0 == "Space" }.count == 3)
    #expect(!pane.pressedKeys.contains { $0.hasPrefix("«") })
}

@MainActor
@Test func toggleFlipsCheckboxesWithoutSubmitting() async throws {
    let pane = FakeClaudeAsk([checks()])
    let box = toolbox(pane)
    let result = try await answer(box, #"{"agent":"api","options":["coverage","unit tests"],"action":"toggle"}"#)
    #expect(result["checked"] as? [String] == ["Unit tests", "Coverage"])
    #expect(pane.outcome == nil && !pane.onButton)
    #expect(pane.checked[0] == [0, 3])
    #expect(box.handedOver[claudeAgent.id]?.question == "Which checks should run before the build?")
    let single = try await answer(
        toolbox(FakeClaudeAsk([cache()])), #"{"agent":"api","option":"redis","action":"toggle"}"#)
    #expect((single["error"] as? String)?.contains("multi-select") == true)
}

@MainActor
@Test func multiQuestionDialogsAnswerOneQuestionAtATimeAndSubmitOnlyWhenAllAreAnswered() async throws {
    let pane = FakeClaudeAsk(tabs())
    let box = toolbox(pane)
    let first = try await answer(box, #"{"agent":"api","option":"oauth"}"#)
    #expect((first["next"] as? String)?.contains("Which features should ship in v1?") == true)
    #expect((first["next"] as? String)?.contains("several answers allowed") == true)
    #expect(first["done"] as? String == "Answered." && pane.outcome == nil)
    #expect(box.handedOver[claudeAgent.id]?.question == "Which features should ship in v1?")
    let second = try await answer(box, #"{"agent":"api","options":["search","webhooks"]}"#)
    #expect((second["next"] as? String)?.contains("Where should logs go?") == true)
    #expect(pane.outcome == nil)
    let third = try await answer(box, #"{"agent":"api","option":"files"}"#)
    #expect(third["done"] as? String == "Answered." && third["next"] == nil)
    #expect(pane.outcome == "answered")
    #expect(pane.answered == [0: "OAuth", 1: "Search, Webhooks", 2: "Files"])
    #expect(box.handedOver[claudeAgent.id] == nil)
}

@MainActor
@Test func answeringTheLastQuestionFirstGoesBackToTheOpenOnesInsteadOfSubmitting() async throws {
    let pane = FakeClaudeAsk(tabs())
    pane.index = 2
    let box = toolbox(pane)
    let result = try await answer(box, #"{"agent":"api","option":"loki"}"#)
    #expect(result["unanswered"] as? [String] == ["Auth", "Features"])
    #expect((result["next"] as? String)?.contains("Which auth method should the API use?") == true)
    #expect(pane.outcome == nil && pane.index == 0)
    pane.index = 3
    let submit = try await answer(box, #"{"agent":"api","action":"submit"}"#)
    #expect(submit["status"] as? String == "needs_confirmation")
    #expect((submit["question"] as? String)?.contains("Auth, Features still open") == true)
    #expect(pane.outcome == nil)
}

@MainActor
@Test func freeTextOptionsTypeTheUsersOwnWordsAndSubmit() async throws {
    let pane = FakeClaudeAsk([cache()])
    let result = try await answer(
        toolbox(pane, turns: ["use the redis cluster in eu"]),
        #"{"agent":"api","text":"use the redis cluster in eu"}"#)
    #expect(result["done"] as? String == "Answered.")
    #expect(pane.outcome == "answered" && pane.answered[0] == "use the redis cluster in eu")
    #expect(pane.pressedKeys == ["Down", "Down", "Down", "«use the redis cluster in eu»", "Enter"])

    let multi = FakeClaudeAsk([checks()])
    let typed = try await answer(
        toolbox(multi, turns: ["lint and also fuzz the parser"]),
        #"{"agent":"api","options":["lint"],"text":"fuzz the parser"}"#)
    #expect(typed["done"] as? String == "Answered.")
    #expect(multi.outcome == "answered" && multi.answered[0] == "Lint, fuzz the parser")
}

@MainActor
@Test func freeTextThatIsNotTheUsersWordsIsReadBackFirst() async throws {
    let pane = FakeClaudeAsk([cache()])
    let box = toolbox(pane, turns: ["redis please"])
    let result = try await answer(box, #"{"agent":"api","text":"Use Redis with a 5 minute TTL and eviction"}"#)
    #expect(result["status"] as? String == "needs_confirmation")
    #expect((result["question"] as? String)?.hasPrefix(PromptFidelity.readBackPrefix) == true)
    #expect(pane.inputs.isEmpty)
    guard case .choose(_, let choice)? = box.gate.pending?.action else {
        Issue.record("the typed answer should be held")
        return
    }
    #expect(choice.text == "Use Redis with a 5 minute TTL and eviction" && choice.textRow == 4)
    _ = await box.perform(.choose(agentID: claudeAgent.id, choice: choice))
    #expect(pane.answered[0] == "Use Redis with a 5 minute TTL and eviction")
}

@MainActor
@Test func cancelPressesEscAndReportsTheDialogClosed() async throws {
    let pane = FakeClaudeAsk(tabs())
    let result = try await answer(toolbox(pane), #"{"agent":"api","action":"cancel"}"#)
    #expect(result["done"] as? String == "Cancelled.")
    #expect(pane.outcome == "declined" && pane.pressedKeys == ["Escape"])
}

@MainActor
@Test func permissionPromptsNeedConfirmationAndNameLastingEffects() async throws {
    let screen = try fixture("claude-permission-auto.screen.txt")
    let pane = FakeStatic(screen)
    let box = toolbox(pane)
    let yes = try await answer(box, #"{"agent":"api","option":"yes"}"#)
    #expect(yes["status"] as? String == "needs_confirmation")
    #expect(yes["question"] as? String == "Should I choose «Yes» for Claude in api?")
    let auto = try await answer(box, #"{"agent":"api","option":"switch to auto mode"}"#)
    #expect((auto["question"] as? String)?.contains("auto mode: from then on it decides by itself") == true)
    let always = try await answer(box, #"{"agent":"api","option":"2"}"#)
    #expect((always["question"] as? String)?.contains("It will not ask again before actions like this one.") == true)
    #expect(pane.inputs.isEmpty)
    let dontAsk = try #require(
        SafetyPolicy.question(
            for: .answer(agentID: "a", digit: "2"), agent: claudeAgent,
            screen: try fixture("claude-permission.screen.txt")))
    #expect(dontAsk.contains("will not ask again"))
    #expect(SafetyPolicy.effect(of: "Yes, and bypass permissions")?.contains("without asking") == true)
    #expect(SafetyPolicy.effect(of: "Yes, and switch to default (ask each time) for this session") == nil)
}

@MainActor
@Test func busyAgentsAndScreensWithoutAQuestionAreRefused() async throws {
    let busy = FakeStatic("⏺ Working\n\n✻ Thinking… (12s · esc to interrupt)\n> \n  ? for shortcuts")
    let refused = try await answer(toolbox(busy), #"{"agent":"api","option":"1"}"#)
    #expect((refused["error"] as? String)?.contains("is working") == true)
    let idle = FakeStatic("⏺ Done.\n\n────\n❯ \n────\n  ? for shortcuts")
    let none = try await answer(toolbox(idle), #"{"agent":"api","option":"yes"}"#)
    #expect((none["error"] as? String)?.contains("shows no question") == true)
    #expect(busy.inputs.isEmpty && idle.inputs.isEmpty)
}

@MainActor
@Test func aQuestionThatChangedBeforeTheKeysAreSentIsNotAnswered() async throws {
    let pane = FakeClaudeAsk([cache()])
    let choice = PromptChoice(action: .select, numbers: [2], labels: ["Postgres"], question: "Something else?")
    let box = toolbox(pane)
    await box.listAgents()
    let result = await box.perform(.choose(agentID: claudeAgent.id, choice: choice))
    #expect(AgentToolbox.failure(result)?.contains("no longer asks") == true)
    #expect(pane.inputs.isEmpty)
}

@MainActor
@Test func codexQuestionsAdvanceAndGoBackInsteadOfSubmittingWithOpenQuestions() async throws {
    let pane = FakeCodexAsk([
        .init(text: "Which realm?", options: [("Home", "home realm"), ("Lab", "lab realm")]),
        .init(text: "What should the alert contain?", options: [("Count", "only counts"), ("Names", "user names")]),
    ])
    pane.index = 1
    let box = toolbox(pane)
    let early = try await answer(box, #"{"agent":"Codex in web","option":"names"}"#)
    #expect((early["next"] as? String)?.contains("Which realm?") == true)
    #expect((early["note"] as? String)?.contains("nothing was submitted") == true)
    #expect(pane.outcome == nil && pane.index == 0)
    let last = try await answer(box, #"{"agent":"Codex in web","option":"lab"}"#)
    #expect(last["done"] as? String == "Answered." && last["next"] == nil)
    #expect(pane.outcome == "submitted" && pane.answer(0) == "Lab" && pane.answer(1) == "Names")
}

@MainActor
@Test func codexNoneOfTheAboveTakesTheTextAsNotes() async throws {
    let pane = FakeCodexAsk([.init(text: "Which realm?", options: [("Home", "home realm"), ("Lab", "lab realm")])])
    let result = try await answer(
        toolbox(pane, turns: ["neither, use the staging realm"]),
        #"{"agent":"Codex in web","text":"use the staging realm"}"#)
    #expect(result["done"] as? String == "Answered.")
    #expect(pane.outcome == "submitted" && pane.answer(0) == "None of the above: use the staging realm")
    #expect(pane.pressedKeys == ["Down", "Down", "Enter", "«use the staging realm»", "Enter"])
}

@MainActor
@Test func theReviewTabSubmitsOnlyThroughSubmit() async throws {
    let pane = FakeClaudeAsk(tabs())
    pane.answered = [0: "OAuth", 1: "Search", 2: "Loki"]
    pane.index = 3
    let result = try await answer(toolbox(pane), #"{"agent":"api","option":"submit answers"}"#)
    #expect(result["done"] as? String == "Submitted.")
    #expect(pane.outcome == "answered")
}

@MainActor
final class FakeStatic: FakePane {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    override func screen() -> String { text }
}

@MainActor
final class FakePermission: FakePane {
    var command = "git push origin main"
    var status = "Running…"
    var labels = [
        "Yes", "Yes, and don't ask again for git push commands in /home/dev/src/api",
        "No, and tell Claude what to do differently (esc)",
    ]
    var focus = 0
    var chosen: String?

    override func press(_ key: String) {
        guard chosen == nil else { return }
        switch key {
        case "Down": focus = min(focus + 1, labels.count - 1)
        case "Up": focus = max(focus - 1, 0)
        case "Enter": chosen = labels[focus]
        default: if let digit = Int(key), labels.indices.contains(digit - 1) { chosen = labels[digit - 1] }
        }
    }

    override func screen() -> String {
        if chosen != nil { return "⏺ Done.\n\n────\n❯ \n────\n  ? for shortcuts" }
        let rows = labels.enumerated().map { "\($0.offset == focus ? " ❯" : "  ") \($0.offset + 1). \($0.element)" }
        return
            ([
                "⏺ Bash(\(command))", "  ⎿  \(status)", "", String(repeating: "─", count: 72), " Bash command", "",
                "   \(command)", "   Run it", "", " Do you want to proceed?",
            ] + rows
            + ["", " Esc to cancel · Tab to amend · ctrl+e to explain"]).joined(separator: "\n")
    }
}

@MainActor
private func spoke(_ pane: FakePane, _ turn: String) async -> AgentToolbox {
    pane.listsScreen = true
    let box = toolbox(pane)
    await box.listAgents()
    box.spokenTurns = ["what is it asking", "  ", turn]
    box.noteUserTurn()
    return box
}

@MainActor
@Test func anOptionTheUserNamedIsChosenWithoutAskingAgain() async throws {
    for (turn, option, label) in [
        ("the first one", "1", "Yes"), ("yes", "yes", "Yes"), ("yes, allow it", "1", "Yes"),
        ("option 3", "no", "No, and tell Claude what to do differently (esc)"),
        ("no", "3", "No, and tell Claude what to do differently (esc)"),
        ("yes, and don't ask again", "2", "Yes, and don't ask again for git push commands in /home/dev/src/api"),
        ("always allow", "don't ask again", "Yes, and don't ask again for git push commands in /home/dev/src/api"),
    ] {
        let pane = FakePermission()
        let result = try await answer(await spoke(pane, turn), #"{"agent":"api","option":"\#(option)"}"#)
        #expect(result["done"] as? String == "Answered.", "\(turn)")
        #expect(pane.chosen == label, "\(turn)")
    }
}

@MainActor
@Test func aChoiceTheUserDidNotNameStillNeedsConfirmation() async throws {
    for (turn, option) in [
        ("yes", "2"), ("do what you think is best", "1"), ("handle it", "yes"), ("the first one", "2"),
        ("not the first one, the second", "2"), ("yes", "3"),
    ] {
        let pane = FakePermission()
        let box = await spoke(pane, turn)
        let result = try await answer(box, #"{"agent":"api","option":"\#(option)"}"#)
        #expect(result["status"] as? String == "needs_confirmation", "\(turn)")
        #expect(pane.inputs.isEmpty && box.gate.pending != nil, "\(turn)")
    }
    let unspoken = FakePermission()
    let box = toolbox(unspoken)
    await box.listAgents()
    box.spokenTurns = ["yes"]
    let result = try await answer(box, #"{"agent":"api","option":"1"}"#)
    #expect(result["status"] as? String == "needs_confirmation", "no prompt was on screen when the user spoke")
}

@MainActor
@Test func aScreenThatChangedSinceTheUserSpokeNeedsConfirmation() async throws {
    let pane = FakePermission()
    let box = await spoke(pane, "the first one")
    pane.command = "git push --force origin main"
    let result = try await answer(box, #"{"agent":"api","option":"1"}"#)
    #expect(result["status"] as? String == "needs_confirmation")
    #expect(pane.inputs.isEmpty)
}

@MainActor
@Test func multiSelectSkipsConfirmationOnlyWhenEveryOptionWasNamed() async throws {
    let risky = FakeClaudeAsk.Question(
        header: "Cleanup", text: "What should the cleanup do?",
        options: [
            ("Delete old branches", "merged ones"), ("Force push main", "rewrite history"),
            ("Prune tags", "local only"),
        ], multi: true)
    let all = FakeClaudeAsk([risky])
    let named = try await answer(
        await spoke(all, "delete the old branches and prune tags"),
        #"{"agent":"api","options":["delete old branches","prune tags"]}"#)
    #expect(named["done"] as? String == "Answered.")
    #expect(all.answered[0] == "Delete old branches, Prune tags")

    let one = FakeClaudeAsk([risky])
    let box = await spoke(one, "delete the old branches")
    let held = try await answer(box, #"{"agent":"api","options":["delete old branches","force push main"]}"#)
    #expect(held["status"] as? String == "needs_confirmation")
    #expect(one.inputs.isEmpty)
}

@Test func explicitChoiceReadsNumbersLabelsAndPlainAnswers() throws {
    let options = [
        "Yes", "Yes, and always allow access to /tmp from this project", "Yes, and switch to auto mode", "No",
    ].enumerated().map { InteractivePrompt.Option(number: $0.offset + 1, label: $0.element) }
    func named(_ turn: String) -> Set<Int> { ExplicitChoice.numbers(ExplicitChoice.words(turn), in: options) }
    #expect(named("the second one") == [2])
    #expect(named("option four") == [4])
    #expect(named("three") == [3])
    #expect(named("the last one") == [4])
    #expect(named("yes") == [1])
    #expect(named("yeah go ahead") == [1])
    #expect(named("no, don't allow it") == [4])
    #expect(named("switch to auto mode") == [3])
    #expect(named("yes always allow") == [2])
    #expect(named("hmm") == [])
    let choice = PromptChoice(action: .select, numbers: [1], labels: ["Yes"], question: "Do you want to proceed?")
    #expect(ExplicitChoice.named(choice, by: "yes [app: Agents now: x]", in: options))
    #expect(!ExplicitChoice.named(choice, by: "whatever you think", in: options))
    #expect(!ExplicitChoice.named(choice, by: "yes but only once", in: options))
    let submit = PromptChoice(action: .submit, question: "Review your answers")
    #expect(ExplicitChoice.named(submit, by: "submit them", in: options))
    #expect(!ExplicitChoice.named(submit, by: "sure", in: options))
    let typed = PromptChoice(action: .select, text: "use redis", textRow: 4, question: "q")
    #expect(ExplicitChoice.named(typed, by: "use redis please", in: options))
    let invented = PromptChoice(action: .select, text: "Use Redis with a five minute TTL", textRow: 4, question: "q")
    #expect(!ExplicitChoice.named(invented, by: "redis", in: options))
}

@MainActor
@Test func cosmeticScreenChangesDoNotStopANamedOrConfirmedChoice() async throws {
    let pane = FakePermission()
    let box = await spoke(pane, "the first one")
    pane.status = "Running… (4s)"
    pane.focus = 1
    let result = try await answer(box, #"{"agent":"api","option":"1"}"#)
    #expect(result["done"] as? String == "Answered.")
    #expect(pane.chosen == "Yes")

    let held = FakePermission()
    let gated = toolbox(held)
    let asked = try await answer(gated, #"{"agent":"api","option":"1"}"#)
    #expect(asked["status"] as? String == "needs_confirmation")
    held.status = "Running… (9s)"
    held.focus = 2
    let pending = try #require(gated.gate.pending)
    let done = await gated.perform(pending.action)
    #expect(done == #"{"done":"Answered."}"#)
    #expect(held.chosen == "Yes")
}
