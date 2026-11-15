import Foundation
import MonitorKit
import VoiceKit

public struct AgentReply: Equatable, Sendable {
    public let agentID: String
    public let agentName: String
    public let lead: String
    public let sent: String
    public let answer: String
    public let sentAt: TimeInterval

    public init(agentID: String, agentName: String, lead: String, sent: String, answer: String, sentAt: TimeInterval) {
        self.agentID = agentID
        self.agentName = agentName
        self.lead = lead
        self.sent = sent
        self.answer = answer
        self.sentAt = sentAt
    }

    public var spoken: String { ReplySpeech.spoken(answer) }
    public var isShort: Bool { ReplySpeech.words(spoken) <= ReplySpeech.shortWords }
    public var asks: Bool { ReplySpeech.endsWithQuestion(answer) }

    public static func lead(_ agent: BrainAgent) -> String {
        if agent.title != nil { return agent.spokenName }
        let place = agent.name.isEmpty ? (agent.cwd.map { ($0 as NSString).lastPathComponent } ?? "") : agent.name
        let word = place.isEmpty ? agent.kind.displayName : place
        return word.prefix(1).uppercased() + word.dropFirst()
    }
}

public struct ReplyTracker: Sendable {
    public struct Check: Equatable, Sendable {
        public let serial: Int
        public let agent: BrainAgent
    }

    public enum Outcome: Equatable, Sendable {
        case ready(AgentReply)
        case unread(AgentEvent)
        case notYet
        case dropped
    }

    struct Delivery: Sendable {
        let serial: Int
        let text: String
        let isPrompt: Bool
        let at: TimeInterval
        var sawBusy = false
        var idle = 0
        var checks = 0
        var fetching = false
    }

    public static let idleSamples = 2
    public static let maxChecks = 3

    private var deliveries: [String: Delivery] = [:]
    private var serial = 0

    public init() {}

    public var tracked: Set<String> { Set(deliveries.keys) }

    public func isTracking(_ agentID: String) -> Bool { deliveries[agentID] != nil }

    public mutating func delivered(agentID: String, text: String, isPrompt: Bool, at: TimeInterval) {
        serial += 1
        deliveries[agentID] = Delivery(serial: serial, text: text, isPrompt: isPrompt, at: at)
    }

    public mutating func forget(_ agentID: String) {
        deliveries[agentID] = nil
    }

    public mutating func update(_ agents: [BrainAgent], present: Set<String>) -> [Check] {
        deliveries = deliveries.filter { present.contains($0.key) }
        var checks: [Check] = []
        for agent in agents {
            guard var delivery = deliveries[agent.id], !delivery.fetching else { continue }
            switch agent.status {
            case .busy:
                delivery.sawBusy = true
                delivery.idle = 0
            case .waiting:
                delivery.idle = 0
            case .idle, .done, .unknown:
                delivery.idle += 1
            }
            if delivery.idle >= Self.idleSamples {
                if delivery.sawBusy || delivery.isPrompt {
                    delivery.fetching = true
                    checks.append(Check(serial: delivery.serial, agent: agent))
                } else {
                    deliveries[agent.id] = nil
                    continue
                }
            }
            deliveries[agent.id] = delivery
        }
        return checks
    }

    public mutating func resolve(_ check: Check, turns: [AgentTurn]?) -> Outcome {
        let agent = check.agent
        guard var delivery = deliveries[agent.id], delivery.serial == check.serial else { return .dropped }
        delivery.fetching = false
        let sent = delivery.text
        let matched = delivery.isPrompt ? turns?.last(where: { Self.matches($0.prompt, sent) }) : nil
        let last = turns?.last
        let turn = delivery.sawBusy ? matched ?? last : matched != nil && matched == last ? last : nil
        let text = turn?.answer.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            if delivery.sawBusy {
                deliveries[agent.id] = nil
                return .unread(AgentEvent(agentID: agent.id, name: agent.spokenName, kind: .done))
            }
            delivery.checks += 1
            delivery.idle = 0
            deliveries[agent.id] = delivery.checks >= Self.maxChecks ? nil : delivery
            return .notYet
        }
        deliveries[agent.id] = nil
        return .ready(
            AgentReply(
                agentID: agent.id, agentName: agent.spokenName, lead: AgentReply.lead(agent), sent: delivery.text,
                answer: text, sentAt: delivery.at))
    }

    static func matches(_ prompt: String?, _ sent: String) -> Bool {
        let prompt = AgentResolver.normalize(prompt ?? "")
        let sent = AgentResolver.normalize(sent)
        guard !prompt.isEmpty, !sent.isEmpty else { return false }
        return prompt.contains(String(sent.prefix(120))) || sent.contains(String(prompt.prefix(120)))
    }

    public static func agent(for session: BrainSession, in agents: [BrainAgent]) -> BrainAgent? {
        let matching = agents.filter { agent in
            switch (session.place, agent.location) {
            case (.tab(_, .tmux(_, _, let shown?)), .tmux(_, _, let windowID, _)),
                (.tmuxWindow(_, _, let shown, _), .tmux(_, _, let windowID, _)):
                return shown == windowID
            case (.herdrPane(let host, _, _, let pane), .herdr(let session, let paneID, _, _)):
                return host == session && pane == paneID
            case (.herdrTab(let host, _, let tab), .herdr(let session, _, let tabID, _)):
                return host == session && tab == tabID
            default:
                return false
            }
        }
        return matching.count == 1 ? matching[0] : nil
    }
}

public enum ReplySpeech {
    public static let shortWords = 60

    public static func spoken(_ text: String) -> String {
        var parts: [String] = []
        var code = false
        var table = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if !code { parts.append("There's a code block.") }
                code.toggle()
                continue
            }
            if code { continue }
            if line.hasPrefix("|") {
                if !table { parts.append("There's a table.") }
                table = true
                continue
            }
            table = false
            var sentence = SpeechChunker.clean(line)
            guard !sentence.isEmpty else { continue }
            if let last = sentence.last, !".!?:;…".contains(last) { sentence += "." }
            parts.append(sentence)
        }
        return parts.joined(separator: " ")
    }

    public static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    public static func endsWithQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_`")))
        return trimmed.hasSuffix("?")
    }

    public static func wantsFull(_ text: String) -> Bool {
        let words = AgentResolver.normalize(text).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 8, words.contains(where: assents.contains) else { return false }
        return words.allSatisfy { assents.contains($0) || fillers.contains($0) }
    }

    private static let assents: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please", "read", "full", "whole", "all", "rest",
        "everything", "more", "hear", "ahead",
    ]

    private static let fillers: Set<String> = [
        "it", "the", "me", "of", "go", "on", "tell", "answer", "reply", "thing", "let", "s", "us", "do", "that",
        "out", "loud", "thanks", "thank", "you", "um", "uh", "oh", "well", "then", "a", "bit",
    ]
}
