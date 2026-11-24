import Foundation
import MonitorKit
import TmuxKit

@MainActor
public final class AgentToolbox {
    public struct IO {
        public var exec: @MainActor (String) async -> String?
        public var focus: @MainActor (BrainAgent) async -> Bool
        public var unsentPrompt: @MainActor (BrainAgent) async -> String?
        public var current: @MainActor () -> CurrentTarget?
        public var tmuxSession: @MainActor () -> String?
        public var sleep: @MainActor (Duration) async -> Void

        public init(
            exec: @escaping @MainActor (String) async -> String?,
            focus: @escaping @MainActor (BrainAgent) async -> Bool,
            unsentPrompt: @escaping @MainActor (BrainAgent) async -> String? = { _ in nil },
            current: @escaping @MainActor () -> CurrentTarget? = { nil },
            tmuxSession: @escaping @MainActor () -> String? = { nil },
            sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        ) {
            self.exec = exec
            self.focus = focus
            self.unsentPrompt = unsentPrompt
            self.current = current
            self.tmuxSession = tmuxSession
            self.sleep = sleep
        }
    }

    public private(set) var agents: [BrainAgent] = []
    public internal(set) var handedOver: [String: InteractivePrompt] = [:]
    public internal(set) var promptsAtTurn: [String: [InteractivePrompt]] = [:]
    public private(set) var listed = false
    public var gate = ConfirmationGate()
    public var onSent: ((BrainAgent, String) -> Void)?
    public var onReconfirmed: ((PendingConfirmation, String) -> Void)?
    public var sessions: SessionToolbox?
    public var spokenTurns: [String]? {
        didSet { sessions?.spokenTurns = spokenTurns }
    }
    let io: IO

    public init(io: IO) {
        self.io = io
    }

    public var currentAgent: BrainAgent? { agents.first(where: \.isCurrent) }

    public static let snapshotPrefix = "[app: Agents now: "

    public var snapshot: String? {
        guard let agents = agentSnapshot else { return nil }
        return sessions?.snapshot.map { agents + "\n" + $0 } ?? agents
    }

    private var agentSnapshot: String? {
        guard listed else { return nil }
        guard !agents.isEmpty else { return Self.snapshotPrefix + "none.]" }
        let items = agents.map { agent in
            "\(agent.spokenName) (\(agent.status.rawValue), \(agent.where_)\(agent.isCurrent ? ", current tab" : "")"
                + (agent.prompt.map { ", " + PromptSpeech.summary($0) } ?? "") + ")"
        }
        return Self.snapshotPrefix + items.joined(separator: "; ") + ".]"
    }

    @discardableResult
    public func listAgents() async -> [BrainAgent]? {
        guard let output = await io.exec(HostAgents.listCommand()) else { return nil }
        agents = await readPrompts(HostAgents.parse(output, current: io.current()))
        listed = true
        sessions?.ingest(output, agents: agents)
        return agents
    }

    public func unsentPrompt(for agent: BrainAgent) async -> String? {
        let text = await io.unsentPrompt(agent)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    public func call(_ call: ToolCall) async -> String {
        let arguments = call.argumentObject
        let name = (arguments["agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch call.name {
        case "list_agents":
            guard let agents = await listAgents() else { return Self.error("The host is not connected.") }
            return Self.json(["agents": agents.map(Self.summary)])
        case "read_answer":
            return await withAgent(name) { await self.readAnswer($0, arguments) }
        case "send_prompt":
            let text = (arguments["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return Self.error("text is empty") }
            return await withAgent(name) { agent in
                let action = AgentAction.sendPrompt(agentID: agent.id, text: text)
                if let turns = self.spokenTurns, !PromptFidelity.isVerbatim(text, turns: turns) {
                    return await self.hold(action, question: PromptFidelity.readBack(text, agent: agent.spokenName))
                }
                return await self.request(action, agent: agent)
            }
        case "answer_question":
            return await withAgent(name) { await self.answerQuestion($0, arguments) }
        case "send_key":
            if let sessions, arguments["target"] != nil || AgentKey(rawValue: arguments["key"] as? String ?? "") == nil
            {
                return await settle(sessions.call(call) { await self.listAgents() })
            }
            guard let key = AgentKey(rawValue: arguments["key"] as? String ?? "") else {
                return Self.error("key must be esc, ctrl_c, or enter")
            }
            return await withAgent(name) { agent in
                let screen = await self.io.exec(AgentControl.screenCommand(agent))
                return await self.request(.key(agentID: agent.id, key: key), agent: agent, screen: screen)
            }
        case "focus_agent":
            return await withAgent(name) { await self.request(.focus(agentID: $0.id), agent: $0) }
        case "unsent_prompt":
            return await withAgent(name) { agent in
                guard let text = await self.unsentPrompt(for: agent) else {
                    return Self.json(["agent": agent.spokenName, "unsent": ""])
                }
                return Self.json(["agent": agent.spokenName, "unsent": text])
            }
        case "start_agent":
            let kind = AgentKind(rawValue: (arguments["kind"] as? String ?? "claude").lowercased()) ?? .claude
            let directory = (arguments["directory"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return await request(.start(kind: kind, directory: directory), agent: nil)
        case "close_agent":
            return await withAgent(name) { await self.request(.close(agentID: $0.id), agent: $0) }
        case "get_model":
            return await withAgent(name) { await self.model($0, request: nil) }
        case "set_model":
            let model = (arguments["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return Self.error("model is empty") }
            return await withAgent(name) { await self.model($0, request: model) }
        default:
            guard let sessions, SessionToolbox.toolNames.contains(call.name) else {
                return Self.error("Unknown tool \(call.name)")
            }
            return await settle(sessions.call(call) { await self.listAgents() })
        }
    }

    public func perform(_ action: AgentAction) async -> String {
        if case .session(let sessionAction) = action {
            guard let sessions else { return Self.error("unreachable") }
            return await sessions.perform(sessionAction) { await self.listAgents() }
        }
        if case .start(let kind, let directory) = action {
            if let herdr = await sessions?.herdrStart(
                kind: kind, directory: directory, current: io.current(), hasTmux: io.tmuxSession() != nil,
                refresh: { await self.listAgents() })
            {
                return herdr
            }
            guard let session = io.tmuxSession() ?? agents.compactMap(Self.tmuxSession).first else {
                return Self.error("There is no tmux session to start an agent in.")
            }
            guard
                await io.exec(AgentControl.startCommand(kind: kind, tmuxSession: session, directory: directory)) != nil
            else { return Self.error("The host is not connected.") }
            return Self.done("Started \(kind.displayName).")
        }
        guard let id = Self.agentID(action), let agent = agents.first(where: { $0.id == id }) else {
            return Self.error("That agent is gone.")
        }
        let command: String
        let done: String
        switch action {
        case .sendPrompt(_, let text):
            command = AgentControl.promptCommand(agent, text: text)
            done = "Sent."
        case .answer(_, let digit):
            command = AgentControl.textCommand(agent, text: digit)
            done = "Answered."
        case .choose(_, let choice):
            return await choose(agent, choice)
        case .key(_, let key):
            command = AgentControl.keyCommand(agent, key: key)
            done = "Done."
        case .close:
            command = AgentControl.exitCommand(agent)
            done = "Closed."
        case .focus:
            guard await io.focus(agent) else { return Self.error("Could not switch to \(agent.spokenName).") }
            return Self.done("Done.")
        case .start, .session:
            return Self.error("unreachable")
        }
        guard let raw = await io.exec(AgentControl.checked(command)) else {
            return Self.error("The host is not connected.")
        }
        let (output, status) = AgentControl.splitExit(raw)
        if status != 0 {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
            return Self.error("The command failed with status \(status). \(detail)")
        }
        if case .herdr = agent.location, let failure = AgentControl.herdrFailure(output) {
            return Self.error(failure)
        }
        if case .sendPrompt(_, let text) = action { onSent?(agent, text) }
        return Self.done(done)
    }

    func request(_ action: AgentAction, agent: BrainAgent?, screen: String? = nil) async -> String {
        if let question = SafetyPolicy.question(for: action, agent: agent, screen: screen) {
            return await hold(action, question: question)
        }
        return await perform(action)
    }

    func hold(_ action: AgentAction, question: String) async -> String {
        if let confirmed = gate.takeReconfirmed(action) {
            let result = await perform(action)
            onReconfirmed?(confirmed, result)
            return result
        }
        gate.hold(action, question: question)
        let instruction =
            question.hasPrefix(PromptFidelity.readBackPrefix)
            ? "This is not the user's own words. Say the question word for word, then wait. Do not call the tool again."
            : "Ask the user this question and wait. Do not call the tool again."
        return Self.json(["status": "needs_confirmation", "question": question, "instruction": instruction])
    }

    private func settle(_ outcome: SessionToolbox.Outcome) async -> String {
        switch outcome {
        case .done(let result): result
        case .confirm(let action, let question): await hold(.session(action), question: question)
        }
    }

    private func withAgent(_ name: String?, _ body: (BrainAgent) async -> String) async -> String {
        if agents.isEmpty { await listAgents() }
        switch AgentResolver.resolve(name, in: agents) {
        case .found(let agent): return await body(agent)
        case .none:
            await listAgents()
            if case .found(let agent) = AgentResolver.resolve(name, in: agents) { return await body(agent) }
            return Self.error(
                "No agent matches \(name ?? "the current tab"). Agents: "
                    + (agents.isEmpty ? "none" : agents.map(\.spokenName).joined(separator: ", ")))
        case .ambiguous(let options):
            return Self.error("Which one? " + options.map(\.spokenName).joined(separator: ", "))
        }
    }

    private func readAnswer(_ agent: BrainAgent, _ arguments: [String: Any]) async -> String {
        let name = agent.spokenName
        let which = (arguments["which"] as? String ?? "last").lowercased()
        let back = max(0, Self.integer(arguments["back"]) ?? 0)
        let query = ((arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        let listing = which == "list" || query != nil
        guard let output = await io.exec(AgentControl.transcriptCommand(agent, wide: listing || back > 0)) else {
            return Self.error("The host is not connected.")
        }
        guard let turns = AgentTranscript.turns(kind: agent.kind, output: output) else {
            return Self.error("No transcript found for \(name).")
        }
        if listing {
            var indexed = turns.indices.reversed().map { (back: turns.count - 1 - $0, turn: turns[$0]) }
            if let query {
                let words = AgentResolver.normalize(query).split(separator: " ")
                indexed = indexed.filter { entry in
                    let text = AgentResolver.normalize((entry.turn.prompt ?? "") + " " + (entry.turn.answer.full ?? ""))
                    return words.allSatisfy { text.contains($0) }
                }
                guard !indexed.isEmpty else {
                    return Self.error(
                        "No turn of \(name) mentions «\(query)» in the part of the transcript the app read.")
                }
            }
            let count = min(max(Self.integer(arguments["count"]) ?? 5, 1), 20)
            return Self.json([
                "agent": name, "total": turns.count, "turns": indexed.prefix(count).map(Self.entry),
                "note": "Read one turn in full with back.",
            ])
        }
        guard back < turns.count else {
            return Self.error("The app read \(turns.count) turns of \(name); back must be below \(turns.count).")
        }
        let turn = turns[turns.count - 1 - back]
        let full = which == "full"
        let clipped = Self.clip((full ? turn.answer.full : turn.answer.last) ?? "", limit: full ? 12000 : 6000)
        var result: [String: Any] = [
            "agent": name, "status": agent.status.rawValue, "back": back,
            "prompt": String((turn.prompt ?? "").prefix(600)), "answer": clipped.text,
        ]
        if let time = turn.time { result["time"] = time }
        if turn.afterCompaction { result["after_compaction"] = true }
        if clipped.truncated {
            result["truncated"] = true
            result["note"] = "The middle of the answer was cut to fit."
        }
        return Self.json(result)
    }

    static func entry(_ item: (back: Int, turn: AgentTurn)) -> [String: Any] {
        var entry: [String: Any] = [
            "back": item.back,
            "prompt": clip(item.turn.prompt ?? "(started before the part the app read)", limit: 120).text,
            "answer": clip(item.turn.answer.last ?? "", limit: 200).text,
        ]
        if let time = item.turn.time { entry["time"] = time }
        if item.turn.afterCompaction { entry["after_compaction"] = true }
        return entry
    }

    static func clip(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        let head = limit * 2 / 5
        return (
            String(text.prefix(head)) + " …[\(text.count - limit) characters cut]… "
                + String(text.suffix(limit - head)),
            true
        )
    }

    static func integer(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? Double).map(Int.init) ?? (value as? String).flatMap { Int($0) }
    }

    static func summary(_ agent: BrainAgent) -> [String: Any] {
        var item: [String: Any] = [
            "agent": agent.spokenName, "id": agent.id, "kind": agent.kind.rawValue, "status": agent.status.rawValue,
            "where": agent.where_, "preview": agent.preview,
        ]
        if let cwd = agent.cwd { item["cwd"] = cwd }
        if let title = agent.title { item["title"] = title }
        if agent.isCurrent { item["current"] = true }
        return item
    }

    static func agentID(_ action: AgentAction) -> String? {
        switch action {
        case .sendPrompt(let id, _), .answer(let id, _), .choose(let id, _), .key(let id, _), .focus(let id),
            .close(let id):
            id
        case .start, .session: nil
        }
    }

    static func tmuxSession(_ agent: BrainAgent) -> String? {
        if case .tmux(let session, _, _, _) = agent.location { return session }
        return nil
    }

    nonisolated public static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated public static func error(_ message: String) -> String {
        json(["error": message])
    }

    nonisolated public static func done(_ acknowledgement: String, _ extra: [String: Any] = [:]) -> String {
        json(extra.merging(["done": acknowledgement]) { _, new in new })
    }

    nonisolated public static let definitions: [ToolDefinition] = [
        tool(
            "list_agents",
            "Refresh the agent list: status, working directory, and a short preview of each agent's screen.", [:]),
        tool(
            "read_answer",
            "Read an agent's answers from its session transcript. By default the latest answer; back 1 is the "
                + "answer before the latest, back 2 the one before that. which full returns the whole turn. which "
                + "list returns recent turns (back, time, prompt, start of the answer) so you can pick one and read it "
                + "with back; query finds turns whose prompt or answer contain the words. For \"the answer before "
                + "that\", \"what did it say about X earlier\", or a summary of several answers: list or query first, "
                + "then read with back.",
            [
                "agent": agentParameter,
                "which": .object(["type": "string", "enum": .array(["last", "full", "list"])]),
                "back": .object(["type": "integer", "description": "0 is the latest turn, 1 the one before."]),
                "count": .object(["type": "integer", "description": "Turns to list, at most 20."]),
                "query": .object(["type": "string", "description": "Words to find in earlier prompts or answers."]),
            ]),
        tool(
            "send_prompt",
            "Type the user's own words into an agent's input box and submit them. Text that is not near verbatim is "
                + "read back to the user first.",
            [
                "agent": agentParameter,
                "text": .object([
                    "type": "string",
                    "description": .string(
                        "The user's words: drop only fillers and the addressing part (\"tell Claude to\"), fix "
                            + "obvious speech recognition errors. Never add goals, context, a prefix, or paraphrase."),
                ]),
            ],
            required: ["text"]),
        tool(
            "answer_question",
            "Answer the question, permission, or selection menu an agent shows, the way the user would with the keys. "
                + "select chooses one option, or on a multi-select question checks exactly the options named and "
                + "submits; toggle only flips the named checkboxes; submit sends a multi-select question or the "
                + "final review; cancel presses Esc. text types the user's own words into the free-text option "
                + "(Type something / None of the above) and submits them. One call answers the current question; "
                + "the result shows the next question of a multi-question dialog, which the app submits only once "
                + "every question is answered.",
            [
                "agent": agentParameter,
                "option": .object(["type": "string", "description": "Option number, or words from its label."]),
                "options": .object([
                    "type": "array", "items": .object(["type": "string"]),
                    "description": "Several options for a multi-select question.",
                ]),
                "text": .object([
                    "type": "string", "description": "The user's own words for the free-text option, not a paraphrase.",
                ]),
                "action": .object([
                    "type": "string", "enum": .array(PromptChoice.Action.allCases.map { .string($0.rawValue) }),
                ]),
            ]),
        tool(
            "send_key",
            "Press a key in an agent, or with target in any tab, window, or pane: esc cancels or interrupts, ctrl_c "
                + "interrupts, enter accepts, tab and arrows move, shift_tab cycles modes, ctrl_d ends input.",
            [
                "agent": agentParameter,
                "key": .object(["type": "string", "enum": .array(SessionKey.allCases.map { .string($0.rawValue) })]),
                "target": SessionToolbox.targetParameter,
            ],
            required: ["key"]),
        tool("focus_agent", "Show an agent on the phone screen.", ["agent": agentParameter]),
        tool(
            "unsent_prompt", "Read the text typed in an agent's input box that was not sent yet.",
            ["agent": agentParameter]),
        tool(
            "start_agent", "Start a new Claude or Codex session in a new tmux window.",
            [
                "kind": .object(["type": "string", "enum": .array(["claude", "codex"])]),
                "directory": .object(["type": "string", "description": "Working directory."]),
            ]),
        tool("close_agent", "Exit an agent session.", ["agent": agentParameter]),
        tool(
            "get_model", "Read which model an agent session uses now and the models its menu offers.",
            ["agent": agentParameter]),
        tool(
            "set_model",
            "Switch the model of a running agent session for this session only, through the agent's own model "
                + "menu. Works only when the agent is idle with an empty input box. The result says which model is "
                + "active now.",
            [
                "agent": agentParameter,
                "model": .object([
                    "type": "string",
                    "description": "The model as the user said it, for example sonnet, opus 5.5, or the fast one.",
                ]),
            ], required: ["model"]),
    ]

    nonisolated private static let agentParameter: JSONValue = .object([
        "type": "string",
        "description": "Agent name as the app lists it. Omit for the agent in the current tab.",
    ])

    nonisolated private static func tool(
        _ name: String, _ description: String, _ properties: [String: JSONValue], required: [String] = []
    ) -> ToolDefinition {
        ToolDefinition(
            name: name, description: description,
            parameters: .object([
                "type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
            ]))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

public enum AgentResolver {
    public enum Match: Equatable, Sendable {
        case found(BrainAgent)
        case none
        case ambiguous([BrainAgent])
    }

    public static func resolve(_ name: String?, in agents: [BrainAgent]) -> Match {
        let key = normalize(name ?? "")
        if key.isEmpty || ["current", "this", "this one", "the current one", "current tab", "it"].contains(key) {
            if let current = agents.first(where: \.isCurrent) { return .found(current) }
            return agents.count == 1 ? .found(agents[0]) : agents.isEmpty ? .none : .ambiguous(agents)
        }
        if let exact = agents.first(where: { $0.id == name }) { return .found(exact) }
        let scored = agents.map { (agent: $0, score: score(key, $0)) }.filter { $0.score > 0 }
        guard let best = scored.map(\.score).max() else { return .none }
        let top = scored.filter { $0.score == best }.map(\.agent)
        if top.count == 1 { return .found(top[0]) }
        if let current = top.first(where: \.isCurrent) { return .found(current) }
        return .ambiguous(top)
    }

    static func score(_ key: String, _ agent: BrainAgent) -> Int {
        let spoken = normalize(agent.spokenName)
        let name = normalize(agent.name)
        let title = normalize(agent.title ?? "")
        let folder = normalize(agent.cwd.map { ($0 as NSString).lastPathComponent } ?? "")
        if key == spoken || (!name.isEmpty && key == name) || (!title.isEmpty && key == title) { return 100 }
        var score = 0
        let words = Set(key.split(separator: " ").map(String.init))
        if !name.isEmpty, key.contains(name) || name.contains(key) { score += 40 }
        if !title.isEmpty, key.contains(title) || (key.count >= 3 && title.contains(key)) { score += 45 }
        if !folder.isEmpty, words.contains(folder) || key.contains(folder) { score += 30 }
        if words.contains(agent.kind.rawValue) { score += 20 }
        if case .tmux(_, let index, _, _) = agent.location,
            key.firstMatch(of: /(?:tab|window)\s+(\d+)/).map({ Int($0.1) == index }) == true
        {
            score += 50
        }
        return score
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
