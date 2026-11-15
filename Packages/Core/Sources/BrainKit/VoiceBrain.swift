import Combine
import Foundation
import MonitorKit
import VoiceKit

@MainActor
public final class VoiceBrain: ObservableObject {
    public enum Mode: Equatable, Sendable {
        case off
        case starting
        case conversing
        case dictation(String)
    }

    public enum Speaker: Equatable, Sendable {
        case user, brain, app
    }

    public struct Caption: Equatable, Sendable {
        public var speaker: Speaker
        public var text: String

        public init(_ speaker: Speaker, _ text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    public struct Audio {
        public var start: @MainActor () async throws -> Void
        public var stop: @MainActor () -> Void

        public init(start: @escaping @MainActor () async throws -> Void, stop: @escaping @MainActor () -> Void) {
            self.start = start
            self.stop = stop
        }

        public static var none: Audio { Audio(start: {}, stop: {}) }
    }

    @Published public private(set) var mode: Mode = .off
    @Published public private(set) var phase: TurnTaking.Phase = .listening
    @Published public private(set) var caption: Caption?
    @Published public private(set) var detail: String?
    @Published public private(set) var inputLevel: Float = 0
    @Published public private(set) var outputLevel: Float = 0
    @Published public private(set) var muted = false
    @Published public private(set) var interrupted = false
    @Published public private(set) var lastTiming: TurnTiming?
    @Published public private(set) var waitingPrompts: [WaitingPrompt] = []
    @Published public private(set) var pendingSend: PendingSend?
    public var onDictation: ((String) -> Void)?
    public var onEnded: (() -> Void)?
    public var onUserTurn: ((UserTurn) -> Void)?
    public var onTurnTimed: ((TurnTiming) -> Void)?
    public var providers = BenchmarkProviders(ears: "", mouth: "", model: "")
    public var readsReplies = true
    public var log: ConversationLog?

    public let toolbox: AgentToolbox
    public let hostID: String
    public let hostName: String
    public private(set) var conversation: Conversation
    private let ears: VoiceEars
    private let mouth: VoiceMouth
    private let model: BrainModel?
    private let store: ConversationStore?
    private let audio: Audio
    private let clock: @MainActor () -> TimeInterval
    private let now: @MainActor () -> Date
    private let pollInterval: Duration
    private var machine: TurnTaking
    private var events = AgentEventQueue()
    private var detector = AgentEventDetector()
    private var turnTask: Task<Void, Never>?
    private var turnID = 0
    private var tickTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var fillerIndex = 0
    private var streamingReply: String?
    private var heard: (at: TimeInterval, start: TimeInterval?, end: TimeInterval?)?
    private var spoken: (start: TimeInterval, end: TimeInterval)?
    private var timing: TurnClock?
    private var replies: [Reply] = []
    private var replyID = 0
    private var turnActive = false
    private var turnText: String?
    private var carry: String?
    private var echo = EchoGuard()
    private var partialSince: TimeInterval?
    private var asking: (heard: String, total: Int, done: TimeInterval?)?
    private var mouthQuiet: TimeInterval? = -.infinity
    private var agentSegment = false
    private var answered: [String: InteractivePrompt] = [:]
    private var notes: [String] = []
    private var driving: [String: TimeInterval] = [:]
    private var replyTracker = ReplyTracker()
    private var replyOffer: AgentReply?
    private var logNotes: [String] = []

    private struct Reply {
        let id: Int
        var heard = ""
        var appended = false
    }

    public static let pausedCaption = "Paused by another audio session"
    public static let fillers = ["Hmm.", "One moment.", "Let me think."]

    public init(
        hostID: String, hostName: String, ears: VoiceEars, mouth: VoiceMouth, model: BrainModel?,
        toolbox: AgentToolbox, store: ConversationStore? = nil, audio: Audio = .none,
        pollInterval: Duration = .seconds(5),
        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.ears = ears
        self.mouth = mouth
        self.model = model
        self.toolbox = toolbox
        self.store = store
        self.audio = audio
        self.pollInterval = pollInterval
        self.clock = clock
        self.now = now
        conversation = Conversation(hostID: hostID, now: now())
        machine = TurnTaking(now: clock())
        toolbox.onSent = { [weak self] agent, text in
            self?.detail = "Sent to \(agent.spokenName): \(text)"
            self?.delivered(agent.id, text: text, isPrompt: true)
            self?.record(.sent(agent: agent.spokenName, text: text))
        }
    }

    public var isOn: Bool { mode != .off }

    public func start() async {
        guard mode == .off else { return }
        mode = .starting
        caption = nil
        detail = nil
        conversation = store?.load(hostID: hostID, now: now()) ?? Conversation(hostID: hostID, now: now())
        machine = TurnTaking(now: clock())
        events = AgentEventQueue()
        detector = AgentEventDetector()
        replies = []
        turnActive = false
        turnText = nil
        carry = nil
        echo = EchoGuard()
        partialSince = nil
        mouthQuiet = -.infinity
        agentSegment = false
        interrupted = false
        waitingPrompts = []
        pendingSend = nil
        answered = [:]
        notes = []
        driving = [:]
        replyTracker = ReplyTracker()
        replyOffer = nil
        ears.onEvent = { [weak self] in self?.hear($0) }
        mouth.onEvent = { [weak self] in self?.mouthChanged($0) }
        ears.muted = muted
        do {
            try await ears.start()
            guard mode == .starting else { return }
            try await audio.start()
        } catch {
            guard mode == .starting else { return }
            ears.stop()
            audio.stop()
            mode = .off
            caption = Caption(.app, error.localizedDescription)
            return
        }
        guard mode == .starting else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.feed(.tick)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        guard model != nil else {
            fallBack(BrainError.notConfigured)
            return
        }
        mode = .conversing
        model?.warmUp()
        pollTask = Task { [weak self] in await self?.poll() }
        turnID += 1
        let id = turnID
        turnTask = Task { [weak self] in await self?.greet(id) }
    }

    public func end(reason: String = "ended") {
        guard mode != .off else { return }
        if let held = toolbox.gate.pending {
            record(.confirmation(.dropped, question: held.question, action: Self.describe(held.action)))
        }
        mode = .off
        turnTask?.cancel()
        turnTask = nil
        sealTurn(speaking: mouth.isSpeaking)
        tickTask?.cancel()
        pollTask?.cancel()
        mouth.stop()
        endAgentSegment()
        ears.stop()
        audio.stop()
        toolbox.gate.cancel()
        conversation.touch(now())
        store?.save(conversation)
        caption = nil
        detail = nil
        timing = nil
        interrupted = false
        waitingPrompts = []
        pendingSend = nil
        phase = .listening
        inputLevel = 0
        outputLevel = 0
        record(.sessionEnd(reason: reason))
        onEnded?()
    }

    public func notice(_ text: String) {
        detail = text
    }

    public func record(_ event: ConversationEvent) {
        log?.record(event)
    }

    public func setMuted(_ on: Bool) {
        muted = on
        ears.muted = on
        feed(.muted(on))
    }

    public func audioInterrupted(_ began: Bool) {
        guard isOn, began != interrupted else { return }
        interrupted = began
        record(.interruption(began: began))
        feed(.interrupted(began))
        if began {
            mouth.stop()
            caption = Caption(.app, Self.pausedCaption)
        } else if caption == Caption(.app, Self.pausedCaption) {
            caption = nil
        }
    }

    public static let toolGrace: TimeInterval = 3

    public func noteAgents(_ listed: [BrainAgent]) {
        let now = clock()
        driving = driving.filter { $0.value > now }
        let agents = listed.filter { driving[$0.id] == nil }
        answered = answered.filter { id, prompt in
            agents.contains { $0.id == id && $0.prompt?.sameContent(prompt) == true }
        }
        let current = agents.compactMap { agent -> WaitingPrompt? in
            guard agent.status == .waiting, let prompt = agent.prompt, answered[agent.id]?.sameContent(prompt) != true
            else { return nil }
            return WaitingPrompt(agentID: agent.id, agentName: agent.spokenName, prompt: prompt)
        }
        let kept = waitingPrompts.compactMap { old in current.first { $0.agentID == old.agentID } }
        let shown = kept + current.filter { new in !kept.contains { $0.agentID == new.agentID } }
        if shown != waitingPrompts { waitingPrompts = shown }
        if shown.isEmpty, machine.promptOpen { feed(.promptClosed) }
        if readsReplies {
            for check in replyTracker.update(agents, present: Set(listed.map(\.id))) { fetchReply(check) }
        }
        for event in detector.update(agents) {
            if let prompt = event.prompt, answered[event.agentID]?.sameContent(prompt) == true { continue }
            if let prompt = event.prompt, toolbox.handedOver[event.agentID]?.sameQuestion(prompt) == true { continue }
            if event.kind == .done,
                replyTracker.isTracking(event.agentID)
                    || events.replies.contains(where: { $0.agentID == event.agentID })
            {
                continue
            }
            record(
                .agentEvent(
                    agent: event.name, kind: event.kind == .waiting ? "waiting" : "done",
                    question: event.prompt?.question, options: event.prompt?.options.map(\.label) ?? []))
            events.push(event)
            feed(event.prompt != nil ? .promptQueued : .eventQueued)
        }
    }

    public func answer(_ waiting: WaitingPrompt, option number: Int) async {
        guard isOn else { return }
        if machine.promptSpeaking { mouth.stop() }
        let result = await toolbox.answerPrompt(agentID: waiting.agentID, number: number, expected: waiting.prompt)
        guard isOn else { return }
        let label = waiting.prompt.options.first { $0.number == number }?.label ?? "option \(number)"
        let failure = AgentToolbox.failure(result)
        record(.promptAnswered(agent: waiting.agentName, option: number, label: label, failure: failure))
        if let failure {
            detail = failure
            return
        }
        answered[waiting.agentID] = waiting.prompt
        delivered(waiting.agentID, text: label, isPrompt: false)
        events.remove(agentID: waiting.agentID)
        waitingPrompts.removeAll { $0.agentID == waiting.agentID }
        if waitingPrompts.isEmpty { feed(.promptClosed) }
        detail = "Chose \(label) for \(waiting.agentName)"
        notes.append(
            "[app: The user tapped option \(number), «\(label)», for \(waiting.agentName)'s question "
                + "«\(waiting.prompt.question)» on screen. It was sent.]")
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            if let agents = await self?.toolbox.listAgents(), !Task.isCancelled { self?.noteAgents(agents) }
            await self?.poll()
        }
    }

    static func isStopCommand(_ text: String) -> Bool {
        let words = AgentResolver.normalize(text)
        return ["stop voice mode", "end voice mode", "exit voice mode", "turn off voice mode", "quit voice mode"]
            .contains { words.contains($0) }
    }

    private func hear(_ event: EarsEvent) {
        guard isOn else { return }
        switch event {
        case .partial, .phrase:
            if interrupted { return }
        default:
            break
        }
        switch event {
        case .partial(let text):
            if text.isEmpty {
                partialSince = nil
            } else {
                if partialSince == nil { partialSince = clock() }
                if isEcho(text, since: partialSince, until: clock() - 1) { break }
                caption = Caption(.user, text)
            }
            feed(.userPartial(text))
        case .phrase(let text):
            let span = spoken
            spoken = nil
            let echoed =
                isEcho(text, since: span?.start ?? partialSince, until: span?.end ?? clock() - 2)
                && !answersPrompt(text, start: span?.start)
            partialSince = nil
            guard !echoed else {
                record(.echoDropped(text: text))
                feed(.userPartial(""))
                break
            }
            record(.userPhrase(text: text, speechStart: span?.start, speechEnd: span?.end))
            heard = (clock(), span?.start, span?.end)
            feed(.userPhrase(text))
            heard = nil
        case .spoken(let start, let end):
            spoken = (start, end)
        case .level(let level):
            inputLevel = level
        case .failed(let message):
            record(.earsFailed(message))
            caption = Caption(.app, message)
        }
    }

    private func answersPrompt(_ text: String, start: TimeInterval?) -> Bool {
        guard let start, let done = asking?.done, start >= done else { return false }
        let said = ExplicitChoice.words(text)
        return waitingPrompts.contains { ExplicitChoice.numbers(said, in: $0.prompt.options).count == 1 }
    }

    private func isEcho(_ text: String, since: TimeInterval?, until: TimeInterval) -> Bool {
        if let mouthQuiet, until > mouthQuiet + 0.3 { return false }
        return echo.matches(text, since: (since ?? clock()) - 2)
    }

    private func mouthChanged(_ event: MouthEvent) {
        switch event {
        case .started:
            mouthQuiet = nil
            record(.mouth(speaking: true))
            feed(.mouthStarted)
        case .upcoming(let text):
            agentSegment = true
            ears.agentSaid(text, end: false)
        case .heard(let text, let reply):
            echo.heard(text, at: clock())
            if var ask = asking, ask.done == nil {
                ask.heard += text
                if ask.heard.components(separatedBy: PromptSpeech.closing).count > ask.total { ask.done = clock() }
                asking = ask
            }
            guard let index = replies.firstIndex(where: { $0.id == reply }) else { break }
            replies[index].heard += text
            caption = Caption(.brain, replies[index].heard.trimmingCharacters(in: .whitespacesAndNewlines))
            if timing?.firstAudio == nil { timing?.firstAudio = clock() }
        case .idle:
            mouthQuiet = clock()
            record(.mouth(speaking: false))
            outputLevel = 0
            feed(.mouthIdle)
            if !events.replies.isEmpty { feed(.eventQueued) }
            if !turnActive { settleTurn() }
            completeTiming()
        case .level(let level): outputLevel = level
        }
    }

    private func settleTurn() {
        logHeard(cut: false)
        replies = []
        turnText = nil
        endAgentSegment()
    }

    private func endAgentSegment() {
        guard agentSegment else { return }
        agentSegment = false
        ears.agentSaid("", end: true)
    }

    private func feed(_ input: TurnTaking.Input) {
        guard isOn else { return }
        let effects = machine.handle(input, at: clock())
        phase = machine.phase
        logCut(input, effects)
        if effects.contains(.cancelBrain) {
            turnTask?.cancel()
            turnTask = nil
            timing = nil
            sealTurn(speaking: mouth.isSpeaking)
        }
        for effect in effects {
            switch effect {
            case .stopMouth:
                mouth.stop()
                endAgentSegment()
            case .cancelBrain:
                break
            case .respond(let text):
                respond(text)
            case .playFiller:
                record(.spoken(.filler, text: Self.fillers[fillerIndex % Self.fillers.count]))
                mouth.speak(Self.fillers[fillerIndex % Self.fillers.count])
                fillerIndex += 1
            case .announce:
                if let sentence = events.drain() {
                    record(.spoken(.announcement, text: sentence))
                    caption = Caption(.brain, sentence)
                    append(.assistant(sentence))
                    mouth.speak(sentence)
                } else if let reply = events.nextReply() {
                    announce(reply)
                }
            case .announcePrompt:
                guard let sentence = events.drainPrompts() else {
                    _ = machine.handle(.promptClosed, at: clock())
                    break
                }
                record(.spoken(.prompt, text: sentence))
                caption = Caption(.brain, sentence)
                append(.assistant(sentence))
                asking = ("", sentence.components(separatedBy: PromptSpeech.closing).count - 1, nil)
                mouth.speak(sentence)
            }
        }
        phase = machine.phase
    }

    private func respond(_ text: String) {
        caption = Caption(.user, text)
        if Self.isStopCommand(text) {
            end(reason: "voice command")
            return
        }
        turnID += 1
        let id = turnID
        if case .dictation = mode {
            record(.dictation(text: text))
            onDictation?(text)
            feed(.brainDone)
            return
        }
        let at = heard?.at ?? clock()
        let end = heard?.end ?? at
        timing = TurnClock(turn: id, text: text, speechEnd: end, phrase: at)
        onUserTurn?(
            UserTurn(turn: id, text: text, speechStart: heard?.start, speechEnd: end, providers: providers))
        turnActive = true
        turnTask = Task { [weak self] in await self?.runTurn(text, id: id) }
    }

    private func greet(_ id: Int) async {
        await toolbox.listAgents()
        noteAgents(toolbox.agents)
        guard id == turnID, !Task.isCancelled, machine.phase == .listening, let current = toolbox.currentAgent,
            let draft = await toolbox.unsentPrompt(for: current), id == turnID, !Task.isCancelled,
            machine.phase == .listening, !interrupted
        else { return }
        machine.startTurn(at: clock())
        phase = machine.phase
        turnActive = true
        appendUser(
            "[app: Voice mode started. \(current.spokenName) has an unsent prompt in its input box: «\(draft)». "
                + "Mention it in one short sentence and offer to finish or send it.]")
        await converse(id)
        finish(id)
    }

    private func runTurn(_ phrase: String, id: Int) async {
        toolbox.noteUserTurn()
        var text = phrase
        if let carry, conversation.messages.last == .user(carry) {
            conversation.removeLast()
            text = carry + " " + phrase
        }
        carry = nil
        turnText = nil
        record(.turn(id: id, text: text))
        defer { refreshPendingSend() }
        let offer = replyOffer
        replyOffer = nil
        if let offer, toolbox.gate.pending == nil, ReplySpeech.wantsFull(text) {
            appendUser(text)
            readFull(offer, id: id)
            finish(id)
            return
        }
        switch toolbox.gate.resolve(userTurn: text) {
        case .confirmed(let pending):
            let driven = AgentToolbox.agentID(pending.action)
            if let driven { driving[driven] = .infinity }
            let result = await toolbox.perform(pending.action)
            if let driven { driving[driven] = clock() + Self.toolGrace }
            noteDelivery(pending.action, result: result)
            record(
                .confirmation(
                    .accepted, question: pending.question, action: Self.describe(pending.action), by: "voice",
                    result: result))
            appendUser(
                "\(text)\n\n[app: The user confirmed \"\(pending.question)\". The action ran. Result: \(result)]")
        case .declined(let pending):
            record(
                .confirmation(
                    .declined, question: pending.question, action: Self.describe(pending.action), by: "voice"))
            appendUser("\(text)\n\n[app: The user did not confirm \"\(pending.question)\". Nothing was done.]")
        case .none:
            appendUser(text)
            turnText = text
        }
        guard id == turnID, !Task.isCancelled else { return }
        await converse(id)
        finish(id)
    }

    private func converse(_ id: Int) async {
        guard let model else { return }
        for round in 1...6 {
            var reply = ""
            var calls: [ToolCall] = []
            streamingReply = ""
            replyID += 1
            let segment = replyID
            replies.append(Reply(id: segment))
            record(.request(turn: id, round: round, messages: conversation.messages.count + 1, notes: logNotes))
            logNotes = []
            do {
                let stream = model.stream(
                    conversation.request(system: systemPrompt),
                    tools: AgentToolbox.definitions + SessionToolbox.definitions + [ConversationRecall.definition])
                for try await event in stream {
                    guard id == turnID, !Task.isCancelled else { return }
                    if timing?.turn == id, timing?.firstToken == nil { timing?.firstToken = clock() }
                    switch event {
                    case .text(let delta):
                        reply += delta
                        streamingReply = reply
                        mouth.stream(delta, reply: segment)
                    case .toolCalls(let assembled):
                        calls = assembled
                    case .finished:
                        break
                    }
                }
            } catch {
                guard id == turnID, !Task.isCancelled, !(error is CancellationError) else { return }
                streamingReply = nil
                mouth.finish()
                if !reply.isEmpty { appendReply(reply, calls: []) }
                fallBack(error)
                return
            }
            guard id == turnID, !Task.isCancelled else { return }
            streamingReply = nil
            mouth.finish()
            record(.reply(turn: id, reply: segment, generated: reply, toolCalls: calls.map(\.name)))
            appendReply(reply, calls: calls)
            guard !calls.isEmpty else { return }
            for call in calls {
                toolbox.spokenTurns = spokenTurns
                let driven = drivenAgent(call)
                if let driven { driving[driven] = .infinity }
                if call.name == "read_answer", let driven { answerAsked(driven) }
                let started = clock()
                let held = toolbox.gate.pending
                let result =
                    call.name == ConversationRecall.name ? await recall(call, turn: id) : await toolbox.call(call)
                if let driven { driving[driven] = clock() + Self.toolGrace }
                noteDelivery(call, result: result)
                record(
                    .toolCall(
                        turn: id, id: call.id, name: call.name, arguments: call.arguments, result: result,
                        ms: Int(((clock() - started) * 1000).rounded())))
                logHold(after: held)
                refreshPendingSend()
                guard id == turnID, !Task.isCancelled else { return }
                append(.tool(call.id, result))
            }
        }
    }

    public func resolvePendingSend(send: Bool) async {
        guard let pending = toolbox.gate.pending, case .sendPrompt = pending.action else { return }
        toolbox.gate.cancel()
        refreshPendingSend()
        if machine.phase == .speaking { mouth.stop() }
        guard send else {
            record(
                .confirmation(
                    .declined, question: pending.question, action: Self.describe(pending.action), by: "tap"))
            notes.append("[app: The user tapped Cancel for \"\(pending.question)\". Nothing was sent.]")
            return
        }
        let result = await toolbox.perform(pending.action)
        record(
            .confirmation(
                .accepted, question: pending.question, action: Self.describe(pending.action), by: "tap",
                result: result))
        if let failure = AgentToolbox.failure(result) { detail = failure }
        notes.append("[app: The user tapped Send for \"\(pending.question)\". Result: \(result)]")
    }

    private var spokenTurns: [String] {
        let turns = conversation.messages.filter { $0.role == .user }.compactMap(\.content).map { content in
            let draft = content.contains("has an unsent prompt in its input box")
            let quoted = draft ? content.matches(of: /«([^»]*)»/).map { String($0.1) }.joined(separator: " ") : ""
            return content.replacing(/\[app:[^\]]*\]/, with: " ") + " " + quoted
        }
        return Array(turns.suffix(4))
    }

    private func refreshPendingSend() {
        guard let pending = toolbox.gate.pending, case .sendPrompt(let id, let text) = pending.action else {
            if pendingSend != nil { pendingSend = nil }
            return
        }
        let name = toolbox.agents.first { $0.id == id }?.spokenName ?? "the agent"
        pendingSend = PendingSend(agentName: name, text: text)
    }

    private func drivenAgent(_ call: ToolCall) -> String? {
        guard !["list_agents", "list_sessions", "view", ConversationRecall.name].contains(call.name) else {
            return nil
        }
        let arguments = call.argumentObject
        let name = (arguments["agent"] as? String) ?? (arguments["target"] as? String)
        guard case .found(let agent) = AgentResolver.resolve(name, in: toolbox.agents) else { return nil }
        return agent.id
    }

    private func delivered(_ agentID: String, text: String, isPrompt: Bool) {
        guard isOn, readsReplies else { return }
        events.removeReply(agentID: agentID)
        replyTracker.delivered(agentID: agentID, text: text, isPrompt: isPrompt, at: clock())
    }

    private func noteDelivery(_ call: ToolCall, result: String) {
        guard AgentToolbox.failure(result) == nil, !result.contains("needs_confirmation") else { return }
        let arguments = call.argumentObject
        switch call.name {
        case "answer_question":
            if let agent = drivenAgent(call) { delivered(agent, text: "\(arguments["option"] ?? "")", isPrompt: false) }
        case "send_text":
            guard let text = arguments["text"] as? String, arguments["enter"] as? Bool == true,
                let sessions = toolbox.sessions
            else { return }
            let target = (arguments["target"] as? String) ?? (arguments["agent"] as? String)
            let agent: BrainAgent?
            if case .found(let session) = SessionResolver.resolve(target, in: sessions.sessions) {
                agent = ReplyTracker.agent(for: session, in: toolbox.agents)
            } else if case .found(let named) = AgentResolver.resolve(target, in: toolbox.agents) {
                agent = named
            } else {
                agent = nil
            }
            if let agent { delivered(agent.id, text: text, isPrompt: true) }
        default:
            break
        }
    }

    private func noteDelivery(_ action: AgentAction, result: String) {
        guard AgentToolbox.failure(result) == nil else { return }
        switch action {
        case .answer(let agentID, let digit):
            delivered(agentID, text: digit, isPrompt: false)
        case .session(.send(let target, let text, true)):
            guard let session = toolbox.sessions?.sessions.first(where: { $0.id == target }),
                let agent = ReplyTracker.agent(for: session, in: toolbox.agents)
            else { return }
            delivered(agent.id, text: text, isPrompt: true)
        default:
            break
        }
    }

    private func answerAsked(_ agentID: String) {
        events.removeReply(agentID: agentID)
        if replyOffer?.agentID == agentID { replyOffer = nil }
        if toolbox.agents.first(where: { $0.id == agentID })?.status != .busy { replyTracker.forget(agentID) }
    }

    private func fetchReply(_ check: ReplyTracker.Check) {
        Task { [weak self] in
            guard let self else { return }
            let output = await toolbox.io.exec(AgentControl.transcriptCommand(check.agent))
            let turns = output.flatMap { AgentTranscript.turns(kind: check.agent.kind, output: $0) }
            guard isOn else { return }
            switch replyTracker.resolve(check, turns: turns) {
            case .ready(let reply):
                events.push(reply)
                feed(.eventQueued)
            case .unread(let event):
                events.push(event)
                feed(.eventQueued)
            case .notYet, .dropped:
                break
            }
        }
    }

    private func announce(_ reply: AgentReply) {
        guard !waitingPrompts.contains(where: { $0.agentID == reply.agentID }) else {
            if !events.replies.isEmpty { feed(.eventQueued) }
            return
        }
        replyOffer = nil
        if reply.isShort {
            let sentence = "\(reply.lead): \(reply.spoken)"
            record(.spoken(.reply, text: sentence))
            caption = Caption(.brain, sentence)
            append(.assistant(sentence))
            mouth.speak(sentence)
            if reply.asks {
                notes.append(
                    "[app: That question came from \(reply.agentName). The user's answer to it goes to that agent.]")
            }
            return
        }
        if !reply.asks {
            replyOffer = reply
            machine.openOffer()
        }
        turnID += 1
        let id = turnID
        machine.startTurn(at: clock())
        turnActive = true
        appendUser(Self.replyNote(reply))
        turnTask = Task { [weak self] in
            await self?.converse(id)
            self?.finish(id)
        }
    }

    static func replyNote(_ reply: AgentReply) -> String {
        func plain(_ text: String, _ limit: Int) -> String {
            let clipped = text.count > limit ? String(text.prefix(limit)) + "…" : text
            return clipped.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        }
        let ending =
            reply.asks
            ? "end with its question to the user, word for word" : "ask \"Want the full answer?\""
        return "[app: \(reply.agentName) finished the prompt you sent, «\(plain(reply.sent, 200))». The user has not "
            + "heard its reply yet: «\(plain(reply.answer, 6000))». Tell the user now: start with \"\(reply.lead):\", "
            + "give a faithful spoken summary in two to four sentences that uses only what the reply says, then "
            + "\(ending). Do not call tools.]"
    }

    private func readFull(_ reply: AgentReply, id: Int) {
        let text = reply.spoken
        replyID += 1
        replies.append(Reply(id: replyID))
        if timing?.turn == id { timing?.firstToken = clock() }
        mouth.stream(text, reply: replyID)
        mouth.finish()
        record(.reply(turn: id, reply: replyID, generated: text, toolCalls: []))
        appendReply(text, calls: [])
    }

    private func appendReply(_ reply: String, calls: [ToolCall]) {
        append(.assistant(reply, toolCalls: calls))
        if !reply.isEmpty, let index = replies.indices.last { replies[index].appended = true }
    }

    private func appendUser(_ text: String) {
        let noted = conversation.messages.last { $0.content?.hasPrefix(AgentToolbox.snapshotPrefix) == true }
        if let note = toolbox.snapshot, noted?.content != note {
            append(.user(note))
            logNotes.append(note)
        }
        for note in notes { append(.user(note)) }
        logNotes += notes
        if text.contains("[app:") { logNotes.append(text) }
        notes = []
        append(.user(text))
    }

    private func sealTurn(speaking: Bool) {
        if let partial = streamingReply, let last = replies.last {
            record(.reply(turn: turnID, reply: last.id, generated: partial, toolCalls: []))
        }
        logHeard(cut: true)
        let inFlight = streamingReply != nil
        streamingReply = nil
        let messages = conversation.messages
        let turnStart = (messages.lastIndex { $0.role == .user } ?? -1) + 1
        var spoken = Array(
            messages.indices.filter {
                $0 >= turnStart && messages[$0].role == .assistant && messages[$0].content?.isEmpty == false
            }.suffix(replies.filter(\.appended).count))
        let current = replies.lastIndex { !$0.heard.isEmpty }
        var cut: String?
        for (offset, reply) in replies.enumerated().reversed() {
            let text = reply.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = text.isEmpty ? nil : text + "…"
            if reply.appended {
                guard let index = spoken.popLast() else { continue }
                let complete = current.map { offset < $0 || (offset == $0 && !speaking) } ?? false
                if !complete { conversation.setContent(content, at: index) }
            } else if inFlight, offset == replies.count - 1 {
                cut = content
            }
        }
        if let cut { append(.assistant(cut)) }
        sealToolCalls()
        if let turnText, conversation.messages.last == .user(turnText) { carry = turnText }
        turnText = nil
        turnActive = false
        replies = []
    }

    private func sealToolCalls() {
        guard let index = conversation.messages.lastIndex(where: { $0.role == .assistant && !$0.toolCalls.isEmpty })
        else { return }
        let answered = Set(conversation.messages[(index + 1)...].compactMap(\.toolCallID))
        for call in conversation.messages[index].toolCalls where !answered.contains(call.id) {
            append(.tool(call.id, AgentToolbox.error("Cancelled: the user interrupted.")))
        }
    }

    private func finish(_ id: Int) {
        guard id == turnID else { return }
        turnActive = false
        store?.save(conversation)
        feed(.brainDone)
        if timing?.turn == id { timing?.brainDone = true }
        if !mouth.isSpeaking { settleTurn() }
        completeTiming()
    }

    private func completeTiming() {
        guard let clockState = timing, clockState.brainDone, !mouth.isSpeaking else { return }
        timing = nil
        let result = clockState.timing(done: clock(), date: now(), providers: providers)
        lastTiming = result
        record(.timing(result))
        onTurnTimed?(result)
    }

    private func fallBack(_ error: Error) {
        let message = (error as? BrainError)?.spoken ?? "Something went wrong with the brain."
        record(.brainError("\(error)"))
        timing = nil
        mode = .dictation(message)
        pollTask?.cancel()
        caption = Caption(.app, ((error as? BrainError)?.caption ?? message) + " Dictating into the draft.")
        mouth.speak(message + " I'll type what you say into the draft instead.")
        feed(.brainDone)
    }

    private func append(_ message: ChatMessage) {
        conversation.append(message, at: now())
    }

    static func describe(_ action: AgentAction) -> String {
        if case .sendPrompt(let agent, let text) = action { return "sendPrompt(\(agent)): \(text)" }
        return String(describing: action)
    }

    private func recall(_ call: ToolCall, turn: Int) async -> String {
        guard let log else {
            return AgentToolbox.error("Conversation logs are off in Settings, so earlier replies cannot be read.")
        }
        let host = hostID
        let date = now()
        let exchanges = await Task.detached {
            log.drain()
            return ConversationRecall.exchanges(
                ConversationRecall.files(store: log.store, host: host, now: date, current: log.fileURL))
        }.value
        return ConversationRecall.answer(call.argumentObject, exchanges: exchanges, excluding: (log.sessionID, turn))
    }

    private func logHeard(cut: Bool) {
        let open = streamingReply != nil ? replies.last?.id : nil
        for reply in replies where !reply.heard.isEmpty || (cut && (reply.appended || reply.id == open)) {
            record(.heard(reply: reply.id, text: reply.heard.trimmingCharacters(in: .whitespacesAndNewlines), cut: cut))
        }
    }

    private func logHold(after previous: PendingConfirmation?) {
        guard let held = toolbox.gate.pending, held != previous else { return }
        record(.confirmation(.held, question: held.question, action: Self.describe(held.action)))
    }

    private func logCut(_ input: TurnTaking.Input, _ effects: [TurnTaking.Effect]) {
        let stopped = effects.contains(.stopMouth)
        let cancelled = effects.contains(.cancelBrain)
        guard stopped || cancelled else { return }
        var partial: String?
        if case .userPartial(let text) = input { partial = text }
        let cause = String(describing: input).prefix { $0 != "(" }
        record(.bargeIn(cause: String(cause), partial: partial, stoppedMouth: stopped, cancelledBrain: cancelled))
    }

    private func poll() async {
        while !Task.isCancelled, mode == .conversing {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled, mode == .conversing, let agents = await toolbox.listAgents() else { continue }
            noteAgents(agents)
        }
    }

    public var systemPrompt: String {
        BrainPrompt.system(hostName: hostName)
    }
}

public struct PendingSend: Equatable, Sendable {
    public let agentName: String
    public let text: String
}

public enum BrainPrompt {
    public static func system(hostName: String) -> String {
        """
        You are the voice assistant in PocketShell, an SSH terminal app on the user's iPhone. You talk with the user \
        out loud and help them run their coding agents (Claude Code and Codex) and their terminal sessions on the host \
        "\(hostName)".

        Everything you write is spoken aloud. Talk like a person in a relaxed conversation: short sentences, plain \
        words, usually one to three sentences per reply. Start with the answer. Do not repeat the question and do \
        not end with an offer of more help. Never use markdown, lists, headings, code, or URLs. Do not read code, \
        paths, or long identifiers aloud; describe them. Write numbers and symbols the way a person says them.

        The app lists the agents in notes like "[app: Agents now: ...]": name, status, place, and which one is in \
        the current tab. The newest note is current. Answer from it and act on it directly; call list_agents only \
        for a screen preview, a working directory, or when the user asks you to check again. When the user names no \
        agent, act on the agent in the current tab: omit the agent argument. Read answers with read_answer and \
        summarize them in plain speech; give details only when asked.

        When a note says the user has not heard an agent's reply, tell that reply as the note asks, from it only; \
        it is not an acknowledgement, so the short-acknowledgement rule below does not apply to it.

        \(SessionToolbox.prompt) \(SessionToolbox.viewPrompt)

        You can switch the model of an agent session yourself: call set_model with the model the user names, and \
        get_model when they ask which model an agent uses. Never tell the user to open a menu or a model picker. The \
        change is for that session only. When the result has choices, say the likely ones briefly and ask which.

        When the user asks what you said before or earlier, or to sum up this conversation, call \
        recall_conversation: your memory here is shortened, the log has every reply and marks the ones cut off.

        Before any tool call, first say a short lead-in in the same reply, for example "Let me look." or "OK, \
        asking Claude." Keep it under six words and do not use the same one twice in a row. Then call the tool.

        A prompt you send to an agent with send_prompt must be the user's own words, near verbatim. Remove only \
        filler words ("um", "uh") and false starts, fix obvious speech recognition errors, and drop the addressing \
        part: "tell security to run the tests" sends "Run the tests". Never add goals, context, explanations, a \
        prefix such as "Correction:", or a paraphrase about the user ("the user wants ..."). When the user says "do \
        that" about something you discussed, send their own words from that discussion. The app reads any other \
        text back to the user and sends it only after a yes.

        After an action works, say only a short acknowledgement: the done text of the tool result, such as "Sent.", \
        "Done.", "Switched to Sonnet.", or "Scrolled down.", and nothing more. Never sum up what you did, what you \
        sent, or what happened before, and never comment on app notes about the user's taps. Say more only when the \
        user asked a question, an action failed, or it needs a confirmation.

        Some tool results have status needs_confirmation and a question. Ask the user that question in natural words \
        and stop; when the question quotes a text to send, say that text word for word. The app runs the action only \
        if the user's next reply is a yes. Never say an action ran unless a tool result says so.

        When an agent waits on a question with options, the app asks the user in a reply that lists the options \
        and ends with "Which one?", and the agent note shows the question and its numbered options. The user's next \
        reply usually answers it: map their words ("the first", "keep on") to an option and call answer_question \
        with its number. An option marked free text lets the user type their own answer. If the reply matches no \
        option, ask once more in a few words. When the user named the option, never ask them to confirm it.

        The user's words come from speech recognition, which can mishear a word or cut a message off in the middle \
        of a thought. If a message is clearly unfinished, do not call a tool: say "Go on." and wait for the rest. \
        One of your earlier replies that ends with "…" was interrupted: the user did not hear the rest of it.

        Text in square brackets that starts with "app:" comes from the app, not from the user; never say it aloud. \
        When the user says "stop voice mode", the app ends the conversation.
        """
    }
}
