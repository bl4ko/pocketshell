import Foundation
import MonitorKit
import Testing

@testable import BrainKit

private let busyScreen = "⏺ Working\n\n✻ Thinking… (12s · esc to interrupt)\n> \n  ? for shortcuts"
private let permissionScreen = """
    Bash command
      git status
    Do you want to proceed?
    ❯ 1. Yes
      2. Yes, and don't ask again for git commands
      3. No, and tell Claude what to do differently (esc)
    """
private let questionScreen = """
    Which database should I use?
    ❯ 1. Postgres
      2. SQLite
    Enter to select · ↑/↓ to navigate · Esc to cancel
    """
private let pushQuestionScreen = """
    The branch is ready. What next?
    ❯ 1. Push to origin and open a PR
      2. Keep it local
    Enter to select · Esc to cancel
    """

private func agent(_ status: BrainAgent.Status, name: String = "api", pane: String = "%3") -> BrainAgent {
    BrainAgent(
        kind: .claude, name: name, location: .tmux(session: "work", windowIndex: 2, windowID: "@7", paneID: pane),
        status: status)
}

@Test(arguments: ["yes", "Yes.", "yeah do it", "go ahead", "Sure, go ahead please", "OK", "yep, send it", "Do it!"])
func affirmativeRepliesConfirm(_ reply: String) {
    #expect(ConfirmationGate.isAffirmative(reply))
}

@Test(arguments: [
    "no", "wait", "yes but change the text first", "don't", "what did it say", "hmm", "stop", "not yet",
    "yes I think we should actually do something else entirely here",
])
func otherRepliesDoNotConfirm(_ reply: String) {
    #expect(!ConfirmationGate.isAffirmative(reply))
}

@Test func gateRunsOnlyOnTheNextAffirmativeTurn() {
    var gate = ConfirmationGate()
    #expect(gate.resolve(userTurn: "yes") == .none)
    let action = AgentAction.key(agentID: "tmux:%3", key: .esc)
    gate.hold(action, question: "Should I interrupt Claude in api?")
    #expect(
        gate.resolve(userTurn: "what is it doing?")
            == .declined(PendingConfirmation(action: action, question: "Should I interrupt Claude in api?")))
    #expect(gate.resolve(userTurn: "yes") == .none)
    gate.hold(action, question: "q")
    #expect(gate.resolve(userTurn: "yes, do it") == .confirmed(PendingConfirmation(action: action, question: "q")))
    #expect(gate.pending == nil)
}

@Test func interruptingABusyAgentNeedsConfirmation() {
    #expect(
        SafetyPolicy.question(for: .key(agentID: "a", key: .esc), agent: agent(.busy), screen: busyScreen)
            == "Should I interrupt Claude in api?")
    #expect(SafetyPolicy.question(for: .key(agentID: "a", key: .ctrlC), agent: agent(.idle), screen: busyScreen) != nil)
    #expect(
        SafetyPolicy.question(for: .key(agentID: "a", key: .esc), agent: agent(.idle), screen: "> \n? for shortcuts")
            == nil)
}

@Test func approvingAPermissionPromptNeedsConfirmation() {
    #expect(
        SafetyPolicy.question(for: .answer(agentID: "a", digit: "1"), agent: agent(.waiting), screen: permissionScreen)
            == "Should I choose option 1, Yes, for Claude in api?")
    #expect(
        SafetyPolicy.question(for: .key(agentID: "a", key: .enter), agent: agent(.waiting), screen: permissionScreen)
            != nil)
    #expect(
        SafetyPolicy.question(for: .key(agentID: "a", key: .esc), agent: agent(.waiting), screen: permissionScreen)
            == nil)
}

@Test func plainQuestionsDoNotNeedConfirmationButRiskyOnesDo() {
    #expect(
        SafetyPolicy.question(for: .answer(agentID: "a", digit: "2"), agent: agent(.waiting), screen: questionScreen)
            == nil)
    #expect(
        SafetyPolicy.question(
            for: .answer(agentID: "a", digit: "2"), agent: agent(.waiting), screen: pushQuestionScreen) != nil)
    #expect(SafetyPolicy.question(for: .answer(agentID: "a", digit: "1"), agent: agent(.waiting), screen: nil) != nil)
}

@Test func startingAndClosingAgentsAlwaysNeedConfirmation() {
    #expect(
        SafetyPolicy.question(for: .start(kind: .codex, directory: "/src/web"), agent: nil, screen: nil)
            == "Should I start a new Codex session in web?")
    #expect(
        SafetyPolicy.question(for: .close(agentID: "a"), agent: agent(.idle), screen: nil)
            == "Should I close Claude in api?")
    #expect(
        SafetyPolicy.question(for: .sendPrompt(agentID: "a", text: "deploy it"), agent: agent(.idle), screen: nil)
            == nil)
    #expect(SafetyPolicy.question(for: .focus(agentID: "a"), agent: agent(.busy), screen: nil) == nil)
}

@MainActor
@Test func toolboxHoldsRiskyActionsAndRunsThemOnlyAfterConfirmation() async throws {
    let list = try fixture("list-agents.txt")
    var commands: [String] = []
    let toolbox = AgentToolbox(
        io: .init(
            exec: { command in
                commands.append(command)
                if command.contains("list-panes") { return list }
                if command.contains("capture-pane") { return busyScreen }
                return ""
            }, focus: { _ in true }))
    let held = await toolbox.call(
        ToolCall(id: "1", name: "send_key", arguments: #"{"agent":"Claude in api","key":"esc"}"#))
    #expect(held.contains("needs_confirmation"))
    #expect(held.contains("Should I interrupt Claude in api?"))
    #expect(!commands.contains { $0.contains("send-keys") })
    guard case .confirmed(let pending) = toolbox.gate.resolve(userTurn: "yes") else {
        Issue.record("expected a confirmed action")
        return
    }
    let result = await toolbox.perform(pending.action)
    #expect(result.contains("esc"))
    #expect(commands.last?.contains("send-keys -t '%3' Escape") == true)
}

@MainActor
@Test func toolboxSendsPromptsWithoutConfirmation() async throws {
    let list = try fixture("list-agents.txt")
    var commands: [String] = []
    var sent: String?
    let toolbox = AgentToolbox(
        io: .init(
            exec: { command in
                commands.append(command)
                return command.contains("list-panes") ? list : ""
            }, focus: { _ in true }))
    toolbox.onSent = { _, text in sent = text }
    let result = await toolbox.call(
        ToolCall(id: "1", name: "send_prompt", arguments: #"{"agent":"web","text":"Run the login tests"}"#))
    #expect(result.contains("\"sent\":\"Run the login tests\""))
    #expect(sent == "Run the login tests")
    #expect(commands.last?.contains("send-keys -t '%9' -l -- 'Run the login tests'") == true)
}

@Test func waitingEventsComeFirstAndMergeIntoOneSentence() {
    var queue = AgentEventQueue()
    queue.push(AgentEvent(agentID: "a", name: "Claude in api", kind: .done))
    queue.push(AgentEvent(agentID: "b", name: "Codex in web", kind: .waiting))
    #expect(queue.drain() == "Codex in web needs your input, and Claude in api finished.")
    #expect(queue.isEmpty)
    #expect(queue.drain() == nil)
}

@Test func latestEventPerAgentWins() {
    var queue = AgentEventQueue()
    queue.push(AgentEvent(agentID: "a", name: "Claude in api", kind: .waiting))
    queue.push(AgentEvent(agentID: "a", name: "Claude in api", kind: .done))
    queue.push(AgentEvent(agentID: "b", name: "Codex in web", kind: .done))
    #expect(queue.drain() == "Claude in api and Codex in web finished.")
}

@Test func manyEventsStayShort() {
    let events = [
        AgentEvent(agentID: "1", name: "Claude in api", kind: .waiting),
        AgentEvent(agentID: "2", name: "Codex in web", kind: .done),
        AgentEvent(agentID: "3", name: "Claude in docs", kind: .done),
        AgentEvent(agentID: "4", name: "Claude in infra", kind: .done),
    ]
    #expect(AgentEventQueue.announcement(for: events) == "Claude in api needs your input, and 3 other agents finished.")
}

@Test func detectorReportsFinishedAndWaitingAgentsAfterTwoPolls() {
    var detector = AgentEventDetector()
    #expect(detector.update([agent(.busy), agent(.busy, name: "web", pane: "%9")]).isEmpty)
    #expect(detector.update([agent(.done), agent(.waiting, name: "web", pane: "%9")]).isEmpty)
    let events = detector.update([agent(.done), agent(.waiting, name: "web", pane: "%9")])
    #expect(
        events == [
            AgentEvent(agentID: "tmux:%3", name: "Claude in api", kind: .done),
            AgentEvent(agentID: "tmux:%9", name: "Claude in web", kind: .waiting),
        ])
    #expect(detector.update([agent(.done), agent(.waiting, name: "web", pane: "%9")]).isEmpty)
}
