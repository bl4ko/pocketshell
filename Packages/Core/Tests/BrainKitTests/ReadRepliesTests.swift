import Foundation
import MonitorKit
import Testing
import VoiceKit

@testable import BrainKit

@MainActor
private final class ReplyRig {
    let ears = RecordingEars()
    let mouth = StagedMouth()
    var time: TimeInterval = 0
    let model: ScriptedModel
    var brain: VoiceBrain!
    var transcript = ""
    var screen = "⏺ Done.\n> \n  ? for shortcuts"
    var commands: [String] = []

    init(_ model: ScriptedModel, readsReplies: Bool = true) async throws {
        self.model = model
        let list = try fixture("list-agents.txt")
        let toolbox = AgentToolbox(
            io: .init(
                exec: { [weak self] command in
                    self?.commands.append(command)
                    if command.contains("@@psh-file:") { return self?.transcript }
                    if command.contains("list-panes") { return list }
                    if command.contains("capture-pane") { return self?.screen }
                    return ""
                },
                focus: { _ in true },
                current: { CurrentTarget(tmuxSession: "work", windowIndex: 2, windowID: "@7") }))
        brain = VoiceBrain(
            hostID: "host-1", hostName: "devbox", ears: ears, mouth: mouth, model: model, toolbox: toolbox,
            pollInterval: .seconds(60), clock: { [weak self] in self?.time ?? 0 })
        brain.readsReplies = readsReplies
        await brain.start()
        _ = await eventually { !self.brain.toolbox.agents.isEmpty }
    }

    deinit {
        MainActor.assumeIsolated { brain.end() }
    }

    var transcriptReads: Int { commands.filter { $0.contains("@@psh-file:") }.count }

    func send(_ phrase: String) async {
        ears.phrase(phrase)
        _ = await eventually { self.model.requests.count == 2 && self.mouth.finishes == 2 }
        mouth.settle()
        time = 10
    }

    func agents(api: BrainAgent.Status) throws -> [BrainAgent] {
        var agents = HostAgents.parse(try fixture("list-agents.txt"))
        agents[0].status = api
        return agents
    }

    func finishAPI() throws {
        brain.noteAgents(try agents(api: .busy))
        brain.noteAgents(try agents(api: .idle))
        brain.noteAgents(try agents(api: .idle))
    }
}

private let sentText = "Run the migration tests again."

private func sendScript(_ text: String = sentText) throws -> [Result<[BrainStreamEvent], BrainError>] {
    let data = try JSONSerialization.data(withJSONObject: ["agent": "api", "text": text])
    return [
        .success([
            .text("Sending. "),
            .toolCalls([ToolCall(id: "s1", name: "send_prompt", arguments: String(decoding: data, as: UTF8.self))]),
            .finished("tool_calls"),
        ]),
        .success([.text("Sent."), .finished("stop")]),
    ]
}

private func claudeTranscript(prompt: String, answer: String) throws -> String {
    let user: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
    let assistant: [String: Any] = [
        "type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": answer]]],
    ]
    let lines = try [user, assistant].map {
        String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }
    return (["@@psh-file:/home/dev/.claude/projects/-home-dev-src-api/s.jsonl@@"] + lines).joined(separator: "\n")
}

private let longAnswer = """
    I changed the migration runner so that every test now gets its own schema, which stops the tests from \
    sharing tables and failing in random order when they run in parallel on the build machine.

    ```swift
    let schema = Schema.isolated(for: test)
    ```

    | Suite | Result |
    |---|---|
    | migrations | 42 passed |

    - The slow seed step now runs once per suite instead of once per test, so the whole run takes about half the time.
    - Two warnings remain about deprecated column types in the legacy billing tables, and they do not fail the build.
    """

@MainActor
@Test func aReplyToAPromptTheBrainSentIsReadAloudWithoutBeingAsked() async throws {
    let rig = try await ReplyRig(ScriptedModel(try sendScript()))
    rig.transcript = try claudeTranscript(prompt: sentText, answer: "All **42** migration tests pass.")
    await rig.send("tell claude to run the migration tests again")
    rig.brain.noteAgents(try rig.agents(api: .busy))
    rig.brain.noteAgents(try rig.agents(api: .idle))
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.transcriptReads == 0, "one idle frame is not the end of the turn")
    rig.brain.noteAgents(try rig.agents(api: .idle))
    #expect(await eventually { rig.mouth.spoken == ["Api: All 42 migration tests pass."] })
    #expect(rig.transcriptReads == 1)
    #expect(rig.model.requests.count == 2)
    #expect(rig.brain.conversation.messages.last?.content == "Api: All 42 migration tests pass.")
}

@MainActor
@Test func theReplyAfterATappedOptionIsReadAloud() async throws {
    let rig = try await ReplyRig(ScriptedModel([]))
    let screen = try fixture("ask-unifi.screen.txt")
    rig.screen = screen
    rig.transcript = try claudeTranscript(prompt: sentText, answer: "Turned it off site-wide.")
    rig.time = 10
    var asking = try rig.agents(api: .waiting)
    let prompt = try #require(InteractivePrompt.read(screen))
    asking[0].prompt = prompt
    rig.brain.noteAgents(asking)
    let waiting = try #require(rig.brain.waitingPrompts.first { $0.agentID == asking[0].id })
    await rig.brain.answer(waiting, option: 1)
    #expect(rig.commands.contains { $0.contains("send-keys -t '%3' -l -- '1'") })
    rig.mouth.settle()
    rig.time = 20
    try rig.finishAPI()
    #expect(await eventually { rig.mouth.spoken.last == "Api: Turned it off site-wide." })
}

@MainActor
@Test func aFastReplyWithoutABusyFrameIsReadOnceTheTranscriptShowsThePrompt() async throws {
    let rig = try await ReplyRig(ScriptedModel(try sendScript()))
    rig.transcript = try claudeTranscript(prompt: "Something older.", answer: "Old answer.")
    await rig.send("tell claude to run the migration tests again")
    rig.brain.noteAgents(try rig.agents(api: .idle))
    rig.brain.noteAgents(try rig.agents(api: .idle))
    #expect(await eventually { rig.transcriptReads == 1 })
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.mouth.spoken.isEmpty, "an older turn in the transcript is not the reply")
    rig.transcript = try claudeTranscript(prompt: sentText, answer: "Done, all green.")
    rig.brain.noteAgents(try rig.agents(api: .idle))
    rig.brain.noteAgents(try rig.agents(api: .idle))
    #expect(await eventually { rig.mouth.spoken == ["Api: Done, all green."] })
}

@MainActor
@Test func aLongReplyIsSummarizedByTheModelAndAYesReadsItAllForSpeech() async throws {
    let summary = "Api: the migration runner now gives each test its own schema. Want the full answer?"
    let rig = try await ReplyRig(
        ScriptedModel(try sendScript() + [.success([.text(summary), .finished("stop")])]))
    rig.transcript = try claudeTranscript(prompt: sentText, answer: longAnswer)
    await rig.send("tell claude to run the migration tests again")
    try rig.finishAPI()
    #expect(await eventually { rig.model.requests.count == 3 && rig.mouth.streamed.hasSuffix(summary) })
    #expect(rig.mouth.spoken.isEmpty)
    let note = try #require(rig.model.requests.last?.last?.content)
    #expect(note.hasPrefix("[app: Claude in api finished the prompt you sent, «\(sentText)»"))
    #expect(note.contains("own schema, which stops the tests"))
    #expect(note.contains("two to four sentences that uses only what the reply says"))
    #expect(note.contains("Want the full answer?"))
    rig.mouth.settle()

    rig.ears.phrase("yes please read it all")
    let full = ReplySpeech.spoken(longAnswer)
    #expect(await eventually { rig.mouth.streamed.hasSuffix(full) })
    #expect(full.contains("There's a code block."))
    #expect(full.contains("There's a table."))
    #expect(!full.contains("Schema.isolated"))
    #expect(!full.contains("42 passed"))
    #expect(full.contains("half the time. Two warnings remain"))
    #expect(rig.model.requests.count == 3, "the app reads the full answer itself")
    #expect(rig.brain.conversation.messages.suffix(2).map(\.content) == ["yes please read it all", full])
}

@MainActor
@Test func aLongReplyThatEndsInAQuestionAsksItAndAYesGoesToTheModel() async throws {
    let question = longAnswer + "\n\nShould I also fix the two warnings?"
    let rig = try await ReplyRig(
        ScriptedModel(
            try sendScript() + [
                .success([.text("Api: tests pass. Should I also fix the two warnings?"), .finished("stop")]),
                .success([.text("Okay."), .finished("stop")]),
            ]))
    rig.transcript = try claudeTranscript(prompt: sentText, answer: question)
    await rig.send("tell claude to run the migration tests again")
    try rig.finishAPI()
    #expect(await eventually { rig.model.requests.count == 3 })
    let note = try #require(rig.model.requests.last?.last?.content)
    #expect(note.contains("end with its question to the user, word for word"))
    #expect(!note.contains("Want the full answer?"))
    #expect(await eventually { rig.mouth.finishes == 3 })
    rig.mouth.settle()
    rig.ears.phrase("yes")
    #expect(await eventually { rig.model.requests.count == 4 })
}

@MainActor
@Test func anAgentTheBrainDidNotPromptIsOnlyAnnouncedAsFinished() async throws {
    let rig = try await ReplyRig(ScriptedModel([]))
    rig.transcript = try claudeTranscript(prompt: sentText, answer: "All tests pass.")
    rig.time = 10
    try rig.finishAPI()
    #expect(await eventually { rig.mouth.spoken == ["Claude in api finished."] })
    #expect(rig.transcriptReads == 0)
}

@MainActor
@Test func readingRepliesOffKeepsTheFinishedAnnouncement() async throws {
    let rig = try await ReplyRig(ScriptedModel(try sendScript()), readsReplies: false)
    rig.transcript = try claudeTranscript(prompt: sentText, answer: "All tests pass.")
    await rig.send("tell claude to run the migration tests again")
    try rig.finishAPI()
    #expect(await eventually { rig.mouth.spoken == ["Claude in api finished."] })
    #expect(rig.transcriptReads == 0)
}

@MainActor
@Test func theUserSpeakingDefersTheReplyUntilTheirTurnIsAnswered() async throws {
    let rig = try await ReplyRig(
        ScriptedModel(try sendScript() + [.success([.text("Codex is fine."), .finished("stop")])]))
    rig.transcript = try claudeTranscript(prompt: sentText, answer: "All tests pass.")
    await rig.send("tell claude to run the migration tests again")
    rig.ears.partial("so what about")
    try rig.finishAPI()
    #expect(await eventually { rig.transcriptReads == 1 })
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.mouth.spoken.isEmpty)
    rig.ears.phrase("so what about codex")
    #expect(await eventually { rig.mouth.finishes == 3 })
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.mouth.spoken.isEmpty, "the reply waits until the answer to the user is done")
    rig.mouth.settle()
    rig.time = 12
    #expect(await eventually { rig.mouth.spoken == ["Api: All tests pass."] })
}

@MainActor
@Test func aReplyTheUserAlreadyAskedForIsDropped() async throws {
    let rig = try await ReplyRig(
        ScriptedModel(
            try sendScript() + [
                .success([
                    .text("Let me look. "),
                    .toolCalls([ToolCall(id: "r1", name: "read_answer", arguments: #"{"agent":"api"}"#)]),
                    .finished("tool_calls"),
                ]),
                .success([.text("All tests pass."), .finished("stop")]),
            ]))
    rig.transcript = try claudeTranscript(prompt: sentText, answer: "All tests pass.")
    await rig.send("tell claude to run the migration tests again")
    rig.ears.partial("what did")
    try rig.finishAPI()
    #expect(await eventually { rig.transcriptReads == 1 })
    rig.ears.phrase("what did claude say")
    #expect(await eventually { rig.model.requests.count == 4 && rig.mouth.finishes == 4 })
    rig.mouth.settle()
    rig.time = 30
    try await Task.sleep(for: .milliseconds(400))
    #expect(rig.mouth.spoken.isEmpty)
}

@MainActor
@Test func aWaitingQuestionOutranksAQueuedReply() async throws {
    let rig = try await ReplyRig(ScriptedModel(try sendScript()))
    rig.transcript = try claudeTranscript(prompt: sentText, answer: "All tests pass.")
    await rig.send("tell claude to run the migration tests again")
    var asking = try rig.agents(api: .idle)
    asking[2].prompt = InteractivePrompt.read(try fixture("ask-unifi.screen.txt"))
    rig.brain.noteAgents(try rig.agents(api: .busy))
    rig.brain.noteAgents(try rig.agents(api: .idle))
    rig.brain.noteAgents(asking)
    #expect(await eventually { rig.transcriptReads == 1 })
    #expect(rig.mouth.spoken.count == 1)
    #expect(rig.mouth.spoken.first?.hasPrefix("Codex in reviewer asks about UniFi site") == true)
    rig.mouth.settle()
    rig.time = 20
    try await Task.sleep(for: .milliseconds(400))
    #expect(rig.mouth.spoken.count == 1, "an open question holds the reply")
    rig.brain.noteAgents(try rig.agents(api: .idle))
    #expect(await eventually { rig.mouth.spoken.last == "Api: All tests pass." })
}

@MainActor
@Test func anAgentThatStopsOnAQuestionCardIsAskedInsteadOfRead() async throws {
    let rig = try await ReplyRig(ScriptedModel(try sendScript()))
    rig.transcript = try claudeTranscript(prompt: sentText, answer: "Which option?")
    await rig.send("tell claude to run the migration tests again")
    var asking = try rig.agents(api: .waiting)
    asking[0].prompt = InteractivePrompt.read(try fixture("ask-unifi.screen.txt"))
    rig.brain.noteAgents(try rig.agents(api: .busy))
    rig.brain.noteAgents(asking)
    rig.brain.noteAgents(asking)
    #expect(await eventually { rig.mouth.spoken.first?.hasPrefix("Claude in api asks about UniFi site") == true })
    rig.mouth.settle()
    rig.time = 30
    try await Task.sleep(for: .milliseconds(400))
    #expect(rig.mouth.spoken.count == 1)
    #expect(rig.transcriptReads == 0)
}

@Test func spokenRepliesSayCodeAndTablesInsteadOfReadingThem() {
    let spoken = ReplySpeech.spoken(
        "## Result\n**Done.** See `main.swift`\n```\nrm -rf /\n```\n| a | b |\n|---|---|\n- first item\n- second")
    #expect(spoken == "Result. Done. See main.swift. There's a code block. There's a table. first item. second.")
    #expect(ReplySpeech.words(ReplySpeech.spoken(longAnswer)) > ReplySpeech.shortWords)
    #expect(ReplySpeech.endsWithQuestion("All done. Should I push?\n"))
    #expect(!ReplySpeech.endsWithQuestion("Why? Because it failed."))
}

@Test func onlyAPlainYesOrReadItAllAsksForTheFullReply() {
    for yes in ["yes", "Yeah, read it all.", "sure, the whole thing", "tell me more", "go ahead", "read the rest"] {
        #expect(ReplySpeech.wantsFull(yes), "\(yes)")
    }
    for no in ["no", "no thanks", "don't read it", "okay tell codex to deploy", "what about codex", "right"] {
        #expect(!ReplySpeech.wantsFull(no), "\(no)")
    }
}

@Test func newestSendIsReadFirstAndAQuestionBeforeIt() {
    func reply(_ id: String, _ at: TimeInterval, _ answer: String = "Done.") -> AgentReply {
        AgentReply(agentID: id, agentName: id, lead: id, sent: "", answer: answer, sentAt: at)
    }
    var queue = AgentEventQueue()
    queue.push(AgentEvent(agentID: "b", name: "b", kind: .done))
    queue.push(reply("a", 1))
    queue.push(reply("b", 2))
    queue.push(reply("c", 0, "Push it?"))
    #expect(queue.drain() == nil, "a reply replaces the finished announcement for its agent")
    #expect(queue.nextReply()?.agentID == "c")
    #expect(queue.nextReply()?.agentID == "b")
    queue.removeReply(agentID: "a")
    #expect(queue.nextReply() == nil)
}

@Test func trackerReadsOnlyAfterTwoIdleFramesAndDropsWhatItCannotVerify() throws {
    var agents = HostAgents.parse(try fixture("list-agents.txt"))
    let present = Set(agents.map(\.id))
    let api = agents[0].id
    var tracker = ReplyTracker()
    tracker.delivered(agentID: api, text: "2", isPrompt: false, at: 1)
    agents[0].status = .idle
    #expect(tracker.update(agents, present: present).isEmpty)
    #expect(tracker.update(agents, present: present).isEmpty)
    #expect(!tracker.isTracking(api), "an answer the agent never worked on is not read")

    tracker.delivered(agentID: api, text: "Run it", isPrompt: true, at: 2)
    agents[0].status = .busy
    _ = tracker.update(agents, present: present)
    agents[0].status = .idle
    _ = tracker.update(agents, present: present)
    let check = try #require(tracker.update(agents, present: present).first)
    #expect(tracker.update(agents, present: present).isEmpty, "one read per finish")
    #expect(
        tracker.resolve(check, turns: nil) == .unread(AgentEvent(agentID: api, name: "Claude in api", kind: .done)))

    tracker.delivered(agentID: api, text: "Run it", isPrompt: true, at: 3)
    #expect(tracker.update([], present: []).isEmpty)
    #expect(!tracker.isTracking(api), "a closed agent is forgotten")
}

@Test func offerKeepsTheNextAnnouncementBackLongEnoughToAnswer() {
    var machine = TurnTaking(now: 0)
    machine.openOffer()
    _ = machine.handle(.mouthIdle, at: 1)
    #expect(machine.handle(.eventQueued, at: 3).isEmpty)
    #expect(machine.handle(.tick, at: 6.9).isEmpty)
    #expect(machine.handle(.tick, at: 7) == [.announce])
    #expect(!machine.offerOpen)
    machine.openOffer()
    _ = machine.handle(.userPhrase("no thanks"), at: 8)
    #expect(!machine.offerOpen)
}

@Test func theLeadIsTheSessionTitleNameOrElseThePlace() throws {
    var agent = HostAgents.parse(try fixture("list-agents.txt"))[0]
    #expect(AgentReply.lead(agent) == "Api")
    agent.title = "CPAMC"
    #expect(AgentReply.lead(agent) == "Claude CPAMC")
}
