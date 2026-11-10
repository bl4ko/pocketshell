import Foundation
import Testing
import VoiceKit

@testable import BrainKit

private final class ScriptedModel: BrainModel, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<[BrainStreamEvent], BrainError>]
    private var received: [[ChatMessage]] = []
    let delay: Duration

    init(_ replies: [Result<[BrainStreamEvent], BrainError>], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    var requests: [[ChatMessage]] { lock.withLock { received } }

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
private func makeToolbox() throws -> AgentToolbox {
    let list = try fixture("list-agents.txt")
    return AgentToolbox(
        io: .init(
            exec: { command in
                if command.contains("list-panes") { return list }
                if command.contains("capture-pane") { return busyScreen }
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

    init(_ model: ScriptedModel) async throws {
        self.model = model
        brain = VoiceBrain(
            hostID: "host-1", hostName: "devbox", ears: ears, mouth: mouth, model: model, toolbox: try makeToolbox(),
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
    #expect(rig.brain.conversation.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
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
