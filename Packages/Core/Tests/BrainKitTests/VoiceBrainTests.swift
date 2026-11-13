import Foundation
import Testing
import VoiceKit

@testable import BrainKit

private final class ScriptedModel: BrainModel, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<[BrainStreamEvent], BrainError>]
    private var received: [[ChatMessage]] = []
    private var warmed = 0
    let delay: Duration

    init(_ replies: [Result<[BrainStreamEvent], BrainError>], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    var requests: [[ChatMessage]] { lock.withLock { received } }
    var warmUps: Int { lock.withLock { warmed } }

    func warmUp() {
        lock.withLock { warmed += 1 }
    }

    func stream(_ messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<BrainStreamEvent, Error> {
        let reply = lock.withLock { () -> Result<[BrainStreamEvent], BrainError> in
            received.append(messages)
            return replies.isEmpty ? .success([.text("Okay."), .finished("stop")]) : replies.removeFirst()
        }
        let delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch reply {
                case .failure(let error):
                    continuation.finish(throwing: error)
                case .success(let events):
                    for event in events {
                        if delay > .zero { try? await Task.sleep(for: delay) }
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private let busyScreen = "✻ Thinking… (12s · esc to interrupt)\n> \n  ? for shortcuts"

@MainActor
private func makeToolbox(
    herdrScreen: @escaping @MainActor () -> String = { "" }, sent: @escaping @MainActor (String) -> Void = { _ in }
) throws -> AgentToolbox {
    let list = try fixture("list-agents.txt")
    return AgentToolbox(
        io: .init(
            exec: { command in
                sent(command)
                if command.contains("list-panes") { return list }
                if command.contains("capture-pane") { return busyScreen }
                if command.contains("pane read") { return herdrScreen() }
                return ""
            },
            focus: { _ in true },
            current: { CurrentTarget(tmuxSession: "work", windowIndex: 2, windowID: "@7") }))
}

@MainActor
private final class StagedRig {
    let ears = RecordingEars()
    let mouth = StagedMouth()
    var time: TimeInterval = 0
    let model: ScriptedModel
    var brain: VoiceBrain!
    var herdrScreen = ""
    var commands: [String] = []

    init(_ model: ScriptedModel, herdrScreen: String = "") async throws {
        self.model = model
        self.herdrScreen = herdrScreen
        let toolbox = try makeToolbox(
            herdrScreen: { [weak self] in self?.herdrScreen ?? "" }, sent: { [weak self] in self?.commands.append($0) })
        brain = VoiceBrain(
            hostID: "host-1", hostName: "devbox", ears: ears, mouth: mouth, model: model, toolbox: toolbox,
            pollInterval: .seconds(60), clock: { [weak self] in self?.time ?? 0 })
        await brain.start()
        _ = await eventually { !self.brain.toolbox.agents.isEmpty }
    }

    deinit {
        MainActor.assumeIsolated { brain.end() }
    }

    var spoken: [ChatMessage] { brain.conversation.messages.filter { $0.content?.hasPrefix("[app:") != true } }
}

@MainActor
private final class Rig {
    let ears = TextEars()
    let mouth = TimedMouth(secondsPerCharacter: 0.001)
    var commands: [String] = []
    var unsent: String?
    var time: TimeInterval = 0
    let model: ScriptedModel
    var brain: VoiceBrain!

    init(
        _ model: ScriptedModel, store: ConversationStore? = nil, now: Date = Date(),
        clock: (@MainActor @Sendable () -> TimeInterval)? = nil
    ) throws {
        self.model = model
        let list = try fixture("list-agents.txt")
        let toolbox = AgentToolbox(
            io: .init(
                exec: { [weak self] command in
                    self?.commands.append(command)
                    if command.contains("list-panes") { return list }
                    if command.contains("capture-pane") { return busyScreen }
                    return ""
                },
                focus: { _ in true },
                unsentPrompt: { [weak self] agent in agent.isCurrent ? self?.unsent : nil },
                current: { CurrentTarget(tmuxSession: "work", windowIndex: 2, windowID: "@7") }))
        brain = VoiceBrain(
            hostID: "host-1", hostName: "devbox", ears: ears, mouth: mouth, model: model, toolbox: toolbox,
            store: store, pollInterval: .seconds(60), clock: clock ?? { [weak self] in self?.time ?? 0 }, now: { now })
    }

    deinit {
        MainActor.assumeIsolated { brain.end() }
    }

    func phrase(_ text: String) {
        ears.submit(text)
    }

    var spoken: [ChatMessage] { brain.conversation.messages.filter { $0.content?.hasPrefix("[app:") != true } }
}

private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> ToolCall {
    ToolCall(id: id, name: name, arguments: arguments)
}

@MainActor
@Test func phraseRunsToolsAndSpeaksTheReplySentenceBySentence() async throws {
    let rig = try Rig(
        ScriptedModel([
            .success([.text("Hmm, let me check."), .toolCalls([call("c1", "list_agents")]), .finished("tool_calls")]),
            .success([.text("Claude in api is busy. "), .text("Codex in web is idle."), .finished("stop")]),
        ]))
    await rig.brain.start()
    #expect(rig.brain.mode == .conversing)
    rig.phrase("what are my agents doing")
    #expect(await eventually { rig.mouth.spoken.contains("Codex in web is idle.") })
    #expect(rig.mouth.spoken.prefix(3) == ["Hmm, let me check.", "Claude in api is busy.", "Codex in web is idle."])
    #expect(
        await eventually {
            rig.brain.caption == VoiceBrain.Caption(.brain, "Claude in api is busy. Codex in web is idle.")
        })
    let second = try #require(rig.model.requests.last)
    #expect(second.last?.role == .tool)
    #expect(second.last?.content?.contains("Claude in api") == true)
    #expect(rig.brain.conversation.messages.map(\.role) == [.user, .user, .assistant, .tool, .assistant])
    #expect(second.first?.role == .system)
    #expect(await eventually { rig.brain.phase == .listening })
}

@MainActor
@Test func riskyToolWaitsForASpokenYes() async throws {
    let rig = try Rig(
        ScriptedModel([
            .success([.toolCalls([call("c1", "send_key", #"{"agent":"api","key":"esc"}"#)]), .finished("tool_calls")]),
            .success([.text("Should I interrupt Claude in api?"), .finished("stop")]),
            .success([.text("Done, I stopped it."), .finished("stop")]),
        ]))
    await rig.brain.start()
    rig.phrase("stop claude")
    #expect(await eventually { rig.mouth.spoken.contains("Should I interrupt Claude in api?") })
    #expect(!rig.commands.contains { $0.contains("Escape") })
    #expect(rig.brain.toolbox.gate.pending != nil)
    #expect(await eventually { rig.brain.phase == .listening })
    rig.phrase("yes, do it")
    #expect(await eventually { rig.mouth.spoken.contains("Done, I stopped it.") })
    #expect(rig.commands.contains { $0.contains("send-keys -t '%3' Escape") })
    #expect(rig.brain.conversation.messages.contains { $0.content?.contains("The user confirmed") == true })
}

@MainActor
@Test func anythingButYesCancelsTheHeldAction() async throws {
    let rig = try Rig(
        ScriptedModel([
            .success([
                .toolCalls([call("c1", "send_key", #"{"agent":"api","key":"ctrl_c"}"#)]), .finished("tool_calls"),
            ]),
            .success([.text("Should I interrupt Claude in api?"), .finished("stop")]),
            .success([.text("Okay, I left it running."), .finished("stop")]),
        ]))
    await rig.brain.start()
    rig.phrase("interrupt claude")
    #expect(await eventually { rig.mouth.spoken.contains("Should I interrupt Claude in api?") })
    #expect(await eventually { rig.brain.phase == .listening })
    rig.phrase("what is it doing first")
    #expect(await eventually { rig.mouth.spoken.contains("Okay, I left it running.") })
    #expect(!rig.commands.contains { $0.contains("C-c") })
    #expect(rig.brain.toolbox.gate.pending == nil)
}

@MainActor
@Test func unreachableBrainSaysSoAndFallsBackToDictation() async throws {
    let rig = try Rig(ScriptedModel([.failure(.unreachable("offline"))]))
    var dictated: [String] = []
    rig.brain.onDictation = { dictated.append($0) }
    await rig.brain.start()
    rig.phrase("hello there")
    #expect(await eventually { rig.brain.mode == .dictation(BrainError.unreachable("").spoken) })
    #expect(rig.mouth.spoken.contains { $0.hasPrefix("I can't reach the brain right now.") })
    rig.phrase("echo hi send")
    #expect(dictated == ["echo hi send"])
}

@MainActor
@Test func refusedModelSaysToChooseAnotherModelAndShowsTheServerMessage() async throws {
    let rig = try Rig(ScriptedModel([.failure(.modelRefused("this client key cannot use this model"))]))
    await rig.brain.start()
    rig.phrase("hello there")
    let spoken = "This key cannot use the selected model. Choose a different model in Settings."
    #expect(await eventually { rig.brain.mode == .dictation(spoken) })
    #expect(rig.mouth.spoken.contains { $0.hasPrefix(spoken) })
    #expect(
        rig.brain.caption?.text == spoken + " (this client key cannot use this model) Dictating into the draft.")
}

@MainActor
@Test func userSpeechBargesInAndCancelsTheReply() async throws {
    let words = (1...30).map { BrainStreamEvent.text("Sentence \($0). ") }
    let rig = try Rig(
        ScriptedModel(
            [.success(words + [.finished("stop")]), .success([.text("Sure, Codex."), .finished("stop")])],
            delay: .milliseconds(30)))
    await rig.brain.start()
    rig.phrase("tell me everything")
    #expect(await eventually { rig.mouth.spoken.contains("Sentence 2.") })
    rig.phrase("wait, what about codex")
    #expect(await eventually { rig.mouth.spoken.contains("Sure, Codex.") })
    #expect(!rig.mouth.spoken.contains("Sentence 30."))
    let users = rig.spoken.filter { $0.role == .user }.compactMap(\.content)
    #expect(users == ["tell me everything", "wait, what about codex"])
    let partial = try #require(rig.brain.conversation.messages.first { $0.role == .assistant }?.content)
    #expect(partial.hasPrefix("Sentence 1. Sentence 2."))
    #expect(partial.hasSuffix("…"))
    #expect(!partial.contains("Sentence 30."))
}

@MainActor
@Test func audioInterruptionCutsTheReplyHoldsAnnouncementsAndResumes() async throws {
    let rig = try await StagedRig(
        ScriptedModel([
            .success([.text("Claude in api is busy. Codex in web is idle."), .finished("stop")]),
            .success([.text("Okay."), .finished("stop")]),
        ]))
    rig.ears.phrase("what are my agents doing")
    #expect(await eventually { rig.mouth.finishes == 1 && rig.spoken.count == 2 })
    let reply = try #require(rig.mouth.reply)
    rig.mouth.hear("Claude in api ", reply: reply)

    rig.brain.audioInterrupted(true)
    #expect(rig.brain.interrupted)
    #expect(rig.mouth.stops >= 1)
    #expect(rig.brain.phase == .listening)
    #expect(rig.brain.caption == VoiceBrain.Caption(.app, VoiceBrain.pausedCaption))
    #expect(rig.spoken.map(\.content) == ["what are my agents doing", "Claude in api…"])

    let agents = HostAgents.parse(try fixture("list-agents.txt"))
    var finished = agents
    finished[0].status = .idle
    rig.brain.noteAgents(agents)
    rig.brain.noteAgents(finished)
    rig.brain.noteAgents(finished)
    rig.ears.phrase("words nobody said")
    rig.time = 60
    try await Task.sleep(for: .milliseconds(400))
    #expect(rig.mouth.spoken.isEmpty)
    #expect(rig.model.requests.count == 1)
    #expect(rig.brain.caption == VoiceBrain.Caption(.app, VoiceBrain.pausedCaption))

    rig.brain.audioInterrupted(false)
    #expect(!rig.brain.interrupted)
    #expect(rig.brain.caption == nil)
    rig.time = 62
    #expect(await eventually { rig.mouth.spoken == ["Claude in api finished."] })
    rig.mouth.settle()
    rig.ears.phrase("thanks")
    #expect(await eventually { rig.model.requests.count == 2 })
    #expect(rig.brain.isOn)
}

@MainActor
@Test func agentEventsAreAnnouncedAfterSilence() async throws {
    let rig = try Rig(ScriptedModel([]))
    await rig.brain.start()
    #expect(await eventually { !rig.brain.toolbox.agents.isEmpty })
    try await Task.sleep(for: .milliseconds(50))
    let agents = HostAgents.parse(try fixture("list-agents.txt"))
    var finished = agents
    finished[0].status = .idle
    rig.brain.noteAgents(agents)
    rig.brain.noteAgents(finished)
    rig.brain.noteAgents(finished)
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.mouth.spoken.isEmpty)
    rig.time = 2
    #expect(await eventually { rig.mouth.spoken == ["Claude in api finished."] })
    #expect(rig.brain.conversation.messages.last?.content == "Claude in api finished.")
}

@MainActor
@Test func unsentPromptInTheCurrentAgentIsMentionedAtStart() async throws {
    let rig = try Rig(ScriptedModel([.success([.text("Claude has an unsent prompt."), .finished("stop")])]))
    rig.unsent = "refactor the auth"
    await rig.brain.start()
    #expect(await eventually { rig.mouth.spoken.contains("Claude has an unsent prompt.") })
    let note = try #require(rig.model.requests.first?.last?.content)
    #expect(note.contains("Claude in api has an unsent prompt"))
    #expect(note.contains("refactor the auth"))
}

@MainActor
@Test func spokenStopEndsVoiceMode() async throws {
    let rig = try Rig(ScriptedModel([]))
    var ended = false
    rig.brain.onEnded = { ended = true }
    await rig.brain.start()
    rig.phrase("okay stop voice mode")
    #expect(rig.brain.mode == .off)
    #expect(ended)
    #expect(!rig.ears.running)
    #expect(rig.model.requests.isEmpty)
}

@MainActor
@Test func restartWithinAnHourContinuesTheConversation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConversationStore(directory: directory)
    let start = Date()
    let first = try Rig(ScriptedModel([.success([.text("Hi."), .finished("stop")])]), store: store, now: start)
    await first.brain.start()
    first.phrase("hello")
    #expect(await eventually { first.brain.phase == .listening && first.spoken.count == 2 })
    first.brain.end()
    let again = try Rig(ScriptedModel([]), store: store, now: start.addingTimeInterval(1200))
    await again.brain.start()
    #expect(again.spoken.map(\.content) == ["hello", "Hi."])
    again.brain.end()
    let later = try Rig(ScriptedModel([]), store: store, now: start.addingTimeInterval(7200))
    await later.brain.start()
    #expect(later.brain.conversation.messages.isEmpty)
}

@MainActor
@Test func missingConfigurationGoesStraightToDictation() async throws {
    let ears = TextEars()
    let mouth = TimedMouth(secondsPerCharacter: 0)
    let brain = VoiceBrain(
        hostID: "h", hostName: "devbox", ears: ears, mouth: mouth, model: nil,
        toolbox: AgentToolbox(io: .init(exec: { _ in nil }, focus: { _ in false })))
    var dictated: [String] = []
    brain.onDictation = { dictated.append($0) }
    await brain.start()
    #expect(brain.mode == .dictation(BrainError.notConfigured.spoken))
    ears.submit("hello")
    #expect(dictated == ["hello"])
}

@MainActor
@Test func turnTimingMeasuresFromTheEndOfSpeechToTextTokenAudioAndDone() async throws {
    let uptime: @MainActor @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    let rig = try Rig(
        ScriptedModel([.success([.text("Claude is idle."), .finished("stop")])], delay: .milliseconds(80)),
        clock: uptime)
    var turns: [UserTurn] = []
    var timings: [TurnTiming] = []
    rig.brain.providers = BenchmarkProviders(ears: "soniox:stt-rt-v6", mouth: "iphone", model: "gpt-test")
    rig.brain.onUserTurn = { turns.append($0) }
    rig.brain.onTurnTimed = { timings.append($0) }
    await rig.brain.start()
    #expect(await eventually { rig.brain.phase == .listening })
    let end = uptime() - 0.3
    rig.ears.onEvent?(.spoken(start: end - 1.2, end: end))
    rig.phrase("what is claude doing")
    #expect(await eventually { timings.count == 1 })
    let timing = try #require(timings.first)
    #expect(turns.count == 1)
    #expect(turns.first?.speechEnd == end)
    #expect(turns.first?.speechStart == end - 1.2)
    #expect(timing.text == "what is claude doing")
    #expect(timing.providers.ears == "soniox:stt-rt-v6")
    #expect((250...600).contains(timing.sttMs))
    let token = try #require(timing.firstTokenMs)
    let audio = try #require(timing.firstAudioMs)
    #expect(token >= timing.sttMs + 70)
    #expect(audio >= token)
    #expect(timing.totalMs >= audio)
    #expect(rig.brain.lastTiming == timing)

    rig.phrase("and codex")
    #expect(await eventually { timings.count == 2 })
    #expect(timings[1].sttMs == 0)
}

@MainActor
@Test func replyTokensStreamToTheMouthAndTheCaptionFollowsWhatWasHeard() async throws {
    let rig = try await StagedRig(
        ScriptedModel([
            .success([
                .text("Let me **look**. "), .toolCalls([call("c1", "list_agents")]), .finished("tool_calls"),
            ]),
            .success([.text("Claude in api "), .text("is busy."), .finished("stop")]),
        ]))
    rig.ears.phrase("what is claude doing")
    #expect(await eventually { rig.mouth.streamed == "Let me **look**. Claude in api is busy." })
    #expect(await eventually { rig.mouth.finishes == 2 })
    #expect(rig.brain.caption == VoiceBrain.Caption(.user, "what is claude doing"))
    let reply = try #require(rig.mouth.reply)
    rig.mouth.hear("Let me look. ", reply: reply - 1)
    #expect(rig.brain.caption == VoiceBrain.Caption(.brain, "Let me look."))
    rig.mouth.hear("Claude in ", reply: reply)
    #expect(rig.brain.caption == VoiceBrain.Caption(.brain, "Claude in"))
    rig.mouth.hear("api is busy.", reply: reply)
    #expect(rig.brain.caption == VoiceBrain.Caption(.brain, "Claude in api is busy."))
    rig.mouth.settle()
    #expect(rig.brain.phase == .listening)
    #expect(rig.spoken.last?.content == "Claude in api is busy.")
}

@MainActor
@Test func bargeInCutsTheStoredReplyToWhatTheUserHeard() async throws {
    let rig = try await StagedRig(
        ScriptedModel([
            .success([.text("Claude in api is busy. Codex in web is idle."), .finished("stop")]),
            .success([.text("Okay."), .finished("stop")]),
        ]))
    rig.ears.phrase("what are my agents doing")
    #expect(await eventually { rig.mouth.finishes == 1 && rig.spoken.count == 2 })
    #expect(rig.spoken.last?.content == "Claude in api is busy. Codex in web is idle.")
    let reply = try #require(rig.mouth.reply)
    rig.mouth.hear("Claude in api ", reply: reply)
    rig.ears.partial("stop")
    #expect(rig.mouth.stops == 1)
    #expect(rig.spoken.map(\.content) == ["what are my agents doing", "Claude in api…"])
    rig.ears.phrase("stop, tell me about codex")
    #expect(await eventually { rig.model.requests.count == 2 })
    let sent = try #require(rig.model.requests.last).filter { $0.content?.hasPrefix("[app:") != true }
    #expect(
        sent.dropFirst().map(\.content) == ["what are my agents doing", "Claude in api…", "stop, tell me about codex"])
}

@MainActor
@Test func bargeInDuringGenerationKeepsToolCallsAndDropsUnheardText() async throws {
    let rig = try await StagedRig(
        ScriptedModel(
            [
                .success([.text("Let me look. "), .toolCalls([call("c1", "list_agents")]), .finished("tool_calls")]),
                .success((1...40).map { .text("Word\($0) ") } + [.finished("stop")]),
            ], delay: .milliseconds(20)))
    rig.ears.phrase("what are my agents doing")
    #expect(await eventually { rig.mouth.streamed.contains("Word3 ") })
    let reply = try #require(rig.mouth.reply)
    rig.mouth.hear("Let me ", reply: reply - 1)
    rig.ears.partial("no wait")
    let messages = rig.spoken
    #expect(messages.map(\.role) == [.user, .assistant, .tool])
    #expect(messages[1].content == "Let me…")
    #expect(messages[1].toolCalls.count == 1)
    #expect(rig.brain.phase == .userSpeaking)
}

@MainActor
@Test func speechThatContinuesAfterAnEarlyEndpointBecomesOneUserTurn() async throws {
    let rig = try await StagedRig(
        ScriptedModel(
            [
                .success([.text("Fix what?"), .finished("stop")]),
                .success([.text("OK, asking Claude."), .finished("stop")]),
            ], delay: .milliseconds(150)))
    rig.ears.phrase("tell claude to fix the")
    #expect(await eventually { rig.model.requests.count == 1 })
    rig.ears.partial("login")
    rig.ears.phrase("login bug on mobile")
    #expect(await eventually { rig.model.requests.count == 2 })
    let users = try #require(rig.model.requests.last).filter {
        $0.role == .user && $0.content?.hasPrefix("[app:") != true
    }
    #expect(users.map(\.content) == ["tell claude to fix the login bug on mobile"])
    #expect(await eventually { rig.spoken.map(\.role) == [.user, .assistant] })

    let reply = try #require(rig.mouth.reply)
    rig.mouth.hear("OK, asking ", reply: reply)
    rig.ears.phrase("and also run the tests")
    #expect(await eventually { rig.model.requests.count == 3 })
    #expect(
        rig.spoken.prefix(3).map(\.content) == [
            "tell claude to fix the login bug on mobile", "OK, asking…", "and also run the tests",
        ])
}

@MainActor
@Test func speechThatContinuesBeforeACompleteReplyIsHeardReplacesThatReply() async throws {
    let rig = try await StagedRig(
        ScriptedModel([
            .success([.text("Fix what?"), .finished("stop")]),
            .success([.text("OK, asking Claude."), .finished("stop")]),
        ]))
    rig.ears.phrase("tell claude to fix the")
    #expect(await eventually { rig.mouth.finishes == 1 && rig.spoken.count == 2 })
    rig.ears.partial("login")
    #expect(rig.spoken.map(\.content) == ["tell claude to fix the"])
    rig.ears.phrase("login bug on mobile")
    #expect(await eventually { rig.model.requests.count == 2 })
    let users = try #require(rig.model.requests.last).filter { $0.content?.hasPrefix("[app:") != true }
    #expect(users.dropFirst().map(\.content) == ["tell claude to fix the login bug on mobile"])
}

@MainActor
@Test func echoOfTheMouthIsNotABargeInButNewWordsAre() async throws {
    let rig = try await StagedRig(
        ScriptedModel([
            .success([.text("Claude in api is busy running tests."), .finished("stop")]),
            .success([.text("Okay."), .finished("stop")]),
        ]))
    rig.time = 100
    rig.ears.phrase("what is claude doing")
    #expect(await eventually { rig.mouth.finishes == 1 })
    let reply = try #require(rig.mouth.reply)
    rig.mouth.hear("Claude in api is busy ", reply: reply)
    rig.time = 101
    rig.ears.partial("in API is busy")
    #expect(rig.mouth.stops == 0)
    #expect(rig.brain.phase == .speaking)
    #expect(rig.brain.caption?.speaker == .brain)
    rig.ears.phrase("Claude in API is busy.", start: 100.2, end: 100.9)
    #expect(rig.mouth.stops == 0)
    #expect(rig.model.requests.count == 1)
    rig.mouth.hear("running tests.", reply: reply)
    rig.mouth.settle()
    rig.time = 101.5
    rig.ears.phrase("running tests", start: 100.9, end: 101.1)
    #expect(rig.model.requests.count == 1)
    #expect(rig.brain.phase == .listening)

    rig.time = 103
    rig.ears.phrase("is busy running tests", start: 102, end: 102.8)
    #expect(await eventually { rig.model.requests.count == 2 })
    #expect(rig.spoken.last { $0.role == .user }?.content == "is busy running tests")
}

@MainActor
@Test func aNewWordWhileTheMouthSpeaksStopsItAtOnce() async throws {
    let rig = try await StagedRig(
        ScriptedModel([.success([.text("Claude in api is busy running tests."), .finished("stop")])]))
    rig.ears.phrase("what is claude doing")
    #expect(await eventually { rig.mouth.finishes == 1 })
    rig.mouth.hear("Claude in api is busy ", reply: rig.mouth.reply)
    rig.ears.partial("is busy stop")
    #expect(rig.mouth.stops == 1)
    #expect(rig.brain.phase == .userSpeaking)
    #expect(rig.brain.caption == VoiceBrain.Caption(.user, "is busy stop"))
}

@MainActor
@Test func agentSpeechGoesToTheEarsAheadOfPlaybackAndEndsWithTheTurnOrAnInterrupt() async throws {
    let rig = try await StagedRig(
        ScriptedModel([
            .success([.text("Let me look."), .toolCalls([call("c1", "list_agents")]), .finished("tool_calls")]),
            .success([.text("Claude is busy."), .finished("stop")]),
            .success([.text("Codex is idle."), .finished("stop")]),
        ]))
    rig.ears.phrase("what is claude doing")
    #expect(await eventually { rig.mouth.finishes == 2 })
    rig.mouth.onEvent?(.upcoming("Let me "))
    rig.mouth.onEvent?(.upcoming("look. Claude is busy."))
    #expect(rig.ears.said == ["Let me ", "look. Claude is busy."])
    #expect(rig.ears.ends == 0)
    rig.mouth.settle()
    #expect(rig.ears.ends == 1)

    rig.ears.phrase("and codex")
    #expect(await eventually { rig.mouth.finishes == 3 })
    rig.mouth.onEvent?(.upcoming("Codex "))
    rig.ears.partial("wait")
    #expect(rig.ears.said.last == "Codex ")
    #expect(rig.ears.ends == 2)
    #expect(rig.mouth.stops == 1)
}

@MainActor
@Test func agentSnapshotRidesWithTheUserTurnAndIsNotRepeatedWhileUnchanged() async throws {
    let rig = try await StagedRig(
        ScriptedModel([
            .success([.text("Claude is busy."), .finished("stop")]),
            .success([.text("Codex is idle."), .finished("stop")]),
        ]))
    #expect(rig.model.warmUps == 1)
    rig.ears.phrase("what is claude doing")
    #expect(await eventually { rig.mouth.finishes == 1 })
    rig.mouth.settle()
    let first = try #require(rig.model.requests.first)
    #expect(first.map(\.role) == [.system, .user, .user])
    let note = try #require(first[1].content)
    #expect(note.hasPrefix("[app: Agents now: Claude in api (busy, tmux work:2, current tab); Codex in web"))
    #expect(note.hasSuffix(".]"))
    #expect(first[2].content == "what is claude doing")
    #expect(first[0].content?.contains("Agents now") == true)

    rig.ears.phrase("and codex")
    #expect(await eventually { rig.model.requests.count == 2 })
    let second = try #require(rig.model.requests.last)
    #expect(Array(second.prefix(first.count)) == first)
    #expect(second.filter { $0.content?.hasPrefix(AgentToolbox.snapshotPrefix) == true }.count == 1)
    #expect(second.last?.content == "and codex")
}

@MainActor
@Test func fillersAreShortAndTheSameOneIsNotPlayedTwiceInARow() async throws {
    #expect(VoiceBrain.fillers.allSatisfy { $0.split(separator: " ").count <= 3 })
    #expect(Set(VoiceBrain.fillers).count == VoiceBrain.fillers.count)
    let rig = try await StagedRig(
        ScriptedModel(
            [.success([.text("One."), .finished("stop")]), .success([.text("Two."), .finished("stop")])],
            delay: .milliseconds(800)))
    rig.time = 10
    rig.ears.phrase("first")
    rig.time = 11.9
    try await Task.sleep(for: .milliseconds(200))
    #expect(rig.mouth.spoken.isEmpty)
    rig.time = 12.1
    #expect(await eventually { rig.mouth.spoken.count == 1 })
    #expect(await eventually { rig.mouth.finishes == 1 })
    rig.mouth.hear(rig.mouth.spoken[0] + " ")
    rig.mouth.settle()
    let filled = try #require(rig.brain.lastTiming)
    #expect(filled.firstAudioMs == nil)

    rig.time = 20
    rig.ears.phrase("second")
    rig.time = 22.5
    #expect(await eventually { rig.mouth.spoken.count == 2 })
    #expect(rig.mouth.spoken[0] != rig.mouth.spoken[1])
    #expect(rig.mouth.spoken.allSatisfy(VoiceBrain.fillers.contains))
    #expect(await eventually { rig.mouth.finishes == 2 })
    rig.mouth.hear("Two.", reply: rig.mouth.reply)
    rig.mouth.settle()
    #expect(rig.brain.lastTiming?.firstAudioMs == 2500)
}

@Test func benchmarkCSVQuotesTextAndLeavesMissingTimesEmpty() throws {
    let timing = TurnTiming(
        turn: 7, date: Date(timeIntervalSince1970: 0),
        providers: BenchmarkProviders(ears: "iphone", mouth: "soniox:tts-rt-v2:Hazel", model: "gpt-test"),
        text: "say \"hi\", then stop", sttMs: 310, firstTokenMs: 900, firstAudioMs: nil, totalMs: 4200)
    #expect(
        BenchmarkCSV.row(timing)
            == #"7,1970-01-01T00:00:00Z,iphone,soniox:tts-rt-v2:Hazel,gpt-test,310,900,,4200,"say ""hi"", then stop""#)
    #expect(BenchmarkCSV.header.split(separator: ",").count == 10)
    #expect(timing.summary == "STT 310 ms · first token 900 ms · first audio – · total 4.2 s")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = BenchmarkLog(directory: directory)
    log.append(timing)
    log.append(timing)
    let lines = try String(contentsOf: log.csvURL, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines.first.map(String.init) == BenchmarkCSV.header)
    #expect(log.last == timing)
    log.clear()
    #expect(!log.hasTimings)
    #expect(log.last == nil)
}

private let askScreen = (try? fixture("ask-unifi.screen.txt")) ?? ""
private let askSentence =
    "Codex in reviewer asks about UniFi site: Turn it off site-wide? Option 1, Off site-wide, recommended. "
    + "Option 2, Keep on. Which one?"

@MainActor
private func showPrompt(_ rig: StagedRig) async {
    rig.herdrScreen = askScreen
    if let agents = await rig.brain.toolbox.listAgents() { rig.brain.noteAgents(agents) }
}

@MainActor
@Test func aWaitingPromptStopsTheReplyAsksTheQuestionAndDoesNotContinueIt() async throws {
    let words = (1...40).map { BrainStreamEvent.text("Sentence \($0). ") }
    let rig = try await StagedRig(
        ScriptedModel([.success(words + [.finished("stop")])], delay: .milliseconds(20)))
    rig.ears.phrase("tell me everything")
    #expect(await eventually { rig.mouth.streamed.contains("Sentence 2.") })
    let reply = try #require(rig.mouth.reply)
    rig.mouth.hear("Sentence 1. ", reply: reply)

    await showPrompt(rig)
    #expect(rig.mouth.stops >= 1)
    #expect(rig.mouth.spoken == [askSentence])
    #expect(rig.brain.caption == VoiceBrain.Caption(.brain, askSentence))
    #expect(rig.brain.waitingPrompts.map(\.agentName) == ["Codex in reviewer"])
    #expect(rig.brain.waitingPrompts.first?.prompt.choices.map(\.label) == ["Off site-wide (Recommended)", "Keep on"])
    let streamed = rig.mouth.streamed
    try await Task.sleep(for: .milliseconds(200))
    #expect(rig.mouth.streamed == streamed, "the cancelled reply must not continue")
    #expect(rig.spoken.map(\.content) == ["tell me everything", "Sentence 1.…", askSentence])
    #expect(rig.model.requests.count == 1)
    rig.mouth.settle()
    #expect(rig.brain.phase == .listening)
}

@MainActor
@Test func aWaitingPromptWaitsUntilTheUserHasSpokenAndBeenAnswered() async throws {
    let rig = try await StagedRig(ScriptedModel([.success([.text("Codex is fine."), .finished("stop")])]))
    rig.ears.partial("so what about")
    await showPrompt(rig)
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.mouth.spoken.isEmpty)
    #expect(rig.mouth.stops == 0)
    #expect(rig.brain.waitingPrompts.count == 1, "the card shows at once")
    rig.ears.phrase("so what about codex")
    #expect(await eventually { rig.mouth.finishes == 1 && rig.spoken.last?.content == "Codex is fine." })
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.mouth.spoken.isEmpty)
    rig.mouth.settle()
    rig.time = 0.4
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.mouth.spoken.isEmpty)
    rig.time = 1
    #expect(await eventually { rig.mouth.spoken == [askSentence] })
    let request = try #require(rig.model.requests.first)
    let note = try #require(request.last { $0.content?.hasPrefix(AgentToolbox.snapshotPrefix) == true }?.content)
    #expect(note.contains("asks «UniFi site: UniFi auto-update"))
    #expect(note.contains("1 Off site-wide (Recommended); 2 Keep on; 3 Type something. (free text)"))
}

@MainActor
@Test func aPromptAlreadyWaitingWhenVoiceModeStartsIsAskedAndASpokenAnswerSendsTheOption() async throws {
    let rig = try await StagedRig(
        ScriptedModel([
            .success([
                .text("Keeping it on. "),
                .toolCalls([call("c1", "answer_question", #"{"agent":"reviewer","option":"keep on"}"#)]),
                .finished("tool_calls"),
            ]),
            .success([.text("Done."), .finished("stop")]),
        ]), herdrScreen: askScreen)
    rig.time = 1
    #expect(await eventually { rig.mouth.spoken == [askSentence] })
    rig.mouth.settle()
    rig.ears.phrase("keep it on")
    #expect(await eventually { rig.commands.contains { $0.contains("pane send-text 'w1:p3' '2'") } })
    let request = try #require(rig.model.requests.first)
    #expect(request.contains(.assistant(askSentence)))
    #expect(request.last == .user("keep it on"))
}

@MainActor
@Test func tappingAPromptOptionAnswersItAndRemovesTheCard() async throws {
    let rig = try await StagedRig(ScriptedModel([]), herdrScreen: askScreen)
    rig.time = 1
    #expect(await eventually { rig.mouth.spoken == [askSentence] })
    let waiting = try #require(rig.brain.waitingPrompts.first)
    await rig.brain.answer(waiting, option: 2)
    #expect(rig.mouth.stops >= 1, "a tap ends the spoken question")
    #expect(rig.commands.contains { $0.contains("pane send-text 'w1:p3' '2'") })
    #expect(rig.brain.waitingPrompts.isEmpty)
    #expect(rig.brain.detail == "Chose Keep on for Codex in reviewer")
    if let agents = await rig.brain.toolbox.listAgents() { rig.brain.noteAgents(agents) }
    #expect(rig.brain.waitingPrompts.isEmpty, "a stale screen does not bring the answered card back")

    rig.herdrScreen = "⏺ Done.\n> \n  ? for shortcuts"
    let card = WaitingPrompt(agentID: waiting.agentID, agentName: waiting.agentName, prompt: waiting.prompt)
    let sends = rig.commands.count
    await rig.brain.answer(card, option: 1)
    #expect(rig.brain.detail == "Codex in reviewer no longer asks that question.")
    #expect(!rig.commands.dropFirst(sends).contains { $0.contains("send-text") })
}
