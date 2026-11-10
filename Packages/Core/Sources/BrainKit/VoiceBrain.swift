import Combine
import Foundation
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
    public var onDictation: ((String) -> Void)?
    public var onEnded: (() -> Void)?
    public var onUserTurn: ((UserTurn) -> Void)?
    public var onTurnTimed: ((TurnTiming) -> Void)?
    public var providers = BenchmarkProviders(ears: "", mouth: "", model: "")

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
    private var mouthQuiet: TimeInterval? = -.infinity
    private var agentSegment = false

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

    public func end() {
        guard mode != .off else { return }
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
        phase = .listening
        inputLevel = 0
        outputLevel = 0
        onEnded?()
    }

    public func notice(_ text: String) {
        detail = text
    }

    public func setMuted(_ on: Bool) {
        muted = on
        ears.muted = on
        feed(.muted(on))
    }

    public func audioInterrupted(_ began: Bool) {
        guard isOn, began != interrupted else { return }
        interrupted = began
        feed(.interrupted(began))
        if began {
            mouth.stop()
            caption = Caption(.app, Self.pausedCaption)
        } else if caption == Caption(.app, Self.pausedCaption) {
            caption = nil
        }
    }

    public func noteAgents(_ agents: [BrainAgent]) {
        for event in detector.update(agents) {
            events.push(event)
            feed(.eventQueued)
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
            let echoed = isEcho(text, since: span?.start ?? partialSince, until: span?.end ?? clock() - 2)
            partialSince = nil
            guard !echoed else {
                feed(.userPartial(""))
                break
            }
            heard = (clock(), span?.start, span?.end)
            feed(.userPhrase(text))
            heard = nil
        case .spoken(let start, let end):
            spoken = (start, end)
        case .level(let level):
            inputLevel = level
        case .failed(let message):
            caption = Caption(.app, message)
        }
    }

    private func isEcho(_ text: String, since: TimeInterval?, until: TimeInterval) -> Bool {
        if let mouthQuiet, until > mouthQuiet + 0.3 { return false }
        return echo.matches(text, since: (since ?? clock()) - 2)
    }

    private func mouthChanged(_ event: MouthEvent) {
        switch event {
        case .started:
            mouthQuiet = nil
            feed(.mouthStarted)
        case .upcoming(let text):
            agentSegment = true
            ears.agentSaid(text, end: false)
        case .heard(let text, let reply):
            echo.heard(text, at: clock())
            guard let index = replies.firstIndex(where: { $0.id == reply }) else { break }
            replies[index].heard += text
            caption = Caption(.brain, replies[index].heard.trimmingCharacters(in: .whitespacesAndNewlines))
            if timing?.firstAudio == nil { timing?.firstAudio = clock() }
        case .idle:
            mouthQuiet = clock()
            outputLevel = 0
            feed(.mouthIdle)
            if !turnActive { settleTurn() }
            completeTiming()
        case .level(let level): outputLevel = level
        }
    }

    private func settleTurn() {
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
                mouth.speak(Self.fillers[fillerIndex % Self.fillers.count])
                fillerIndex += 1
            case .announce:
                guard let sentence = events.drain() else { break }
                caption = Caption(.brain, sentence)
                append(.assistant(sentence))
                mouth.speak(sentence)
            }
        }
        phase = machine.phase
    }

    private func respond(_ text: String) {
        caption = Caption(.user, text)
        if Self.isStopCommand(text) {
            end()
            return
        }
        turnID += 1
        let id = turnID
        if case .dictation = mode {
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
        var text = phrase
        if let carry, conversation.messages.last == .user(carry) {
            conversation.removeLast()
            text = carry + " " + phrase
        }
        carry = nil
        turnText = nil
        switch toolbox.gate.resolve(userTurn: text) {
        case .confirmed(let pending):
            let result = await toolbox.perform(pending.action)
            appendUser(
                "\(text)\n\n[app: The user confirmed \"\(pending.question)\". The action ran. Result: \(result)]")
        case .declined(let pending):
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
        for _ in 0..<6 {
            var reply = ""
            var calls: [ToolCall] = []
            streamingReply = ""
            replyID += 1
            let segment = replyID
            replies.append(Reply(id: segment))
            do {
                let stream = model.stream(conversation.request(system: systemPrompt), tools: AgentToolbox.definitions)
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
            appendReply(reply, calls: calls)
            guard !calls.isEmpty else { return }
            for call in calls {
                let result = await toolbox.call(call)
                guard id == turnID, !Task.isCancelled else { return }
                append(.tool(call.id, result))
            }
        }
    }

    private func appendReply(_ reply: String, calls: [ToolCall]) {
        append(.assistant(reply, toolCalls: calls))
        if !reply.isEmpty, let index = replies.indices.last { replies[index].appended = true }
    }

    private func appendUser(_ text: String) {
        let noted = conversation.messages.last { $0.content?.hasPrefix(AgentToolbox.snapshotPrefix) == true }
        if let note = toolbox.snapshot, noted?.content != note { append(.user(note)) }
        append(.user(text))
    }

    private func sealTurn(speaking: Bool) {
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
        onTurnTimed?(result)
    }

    private func fallBack(_ error: Error) {
        let message = (error as? BrainError)?.spoken ?? "Something went wrong with the brain."
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

public enum BrainPrompt {
    public static func system(hostName: String) -> String {
        """
        You are the voice assistant in PocketShell, an SSH terminal app on the user's iPhone. You talk with the user \
        out loud and help them run their coding agents (Claude Code and Codex) on the host "\(hostName)".

        Everything you write is spoken aloud. Talk like a person in a relaxed conversation: short sentences, plain \
        words, usually one to three sentences per reply. Start with the answer. Do not repeat the question and do \
        not end with an offer of more help. Never use markdown, lists, headings, code, or URLs. Do not read code, \
        paths, or long identifiers aloud; describe them. Write numbers and symbols the way a person says them.

        The app lists the agents in notes like "[app: Agents now: ...]": name, status, place, and which one is in \
        the current tab. The newest note is current. Answer from it and act on it directly; call list_agents only \
        for a screen preview, a working directory, or when the user asks you to check again. When the user names no \
        agent, act on the agent in the current tab: omit the agent argument. Read answers with read_answer and \
        summarize them in plain speech; give details only when asked.

        Before any tool call, first say a short lead-in in the same reply, for example "Let me look." or "OK, \
        asking Claude." Keep it under six words and do not use the same one twice in a row. Then call the tool.

        When the user dictates a message for an agent ("tell Claude: ..."), send their words almost verbatim: remove \
        only filler words and false starts. When the user discussed a task with you and then says "do that" or "go \
        ahead", write a clear, complete prompt yourself. After every send, say in one short sentence what you sent.

        Some tool results have status needs_confirmation and a question. Ask the user that question in natural words \
        and stop. The app runs the action only if the user's next reply is a yes. Never say an action ran unless a \
        tool result says so.

        The user's words come from speech recognition, which can mishear a word or cut a message off in the middle \
        of a thought. If a message is clearly unfinished, do not call a tool: say "Go on." and wait for the rest. \
        One of your earlier replies that ends with "…" was interrupted: the user did not hear the rest of it.

        Text in square brackets that starts with "app:" comes from the app, not from the user; never say it aloud. \
        When the user says "stop voice mode", the app ends the conversation.
        """
    }
}
