import Foundation
import MonitorKit
import TmuxKit

public enum AgentAction: Equatable, Sendable {
    case sendPrompt(agentID: String, text: String)
    case answer(agentID: String, digit: String)
    case key(agentID: String, key: AgentKey)
    case focus(agentID: String)
    case start(kind: AgentKind, directory: String?)
    case close(agentID: String)
    case session(SessionAction)
}

public struct PendingConfirmation: Equatable, Sendable {
    public let action: AgentAction
    public let question: String

    public init(action: AgentAction, question: String) {
        self.action = action
        self.question = question
    }
}

public struct ConfirmationGate: Sendable {
    public enum Resolution: Equatable, Sendable {
        case none
        case confirmed(PendingConfirmation)
        case declined(PendingConfirmation)
    }

    public private(set) var pending: PendingConfirmation?

    public init() {}

    public mutating func hold(_ action: AgentAction, question: String) {
        pending = PendingConfirmation(action: action, question: question)
    }

    public mutating func resolve(userTurn: String) -> Resolution {
        guard let pending else { return .none }
        self.pending = nil
        return Self.isAffirmative(userTurn) ? .confirmed(pending) : .declined(pending)
    }

    public mutating func cancel() {
        pending = nil
    }

    public static func isAffirmative(_ text: String) -> Bool {
        let words =
            text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 7 else { return false }
        if words.contains(where: negations.contains) { return false }
        let phrase = " " + words.joined(separator: " ") + " "
        return affirmatives.contains { phrase.contains(" \($0) ") }
    }

    private static let negations: Set<String> = [
        "no", "not", "don't", "dont", "nope", "wait", "stop", "cancel", "never", "hold", "but", "instead",
        "nah", "actually", "later", "change",
    ]

    private static let affirmatives = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go ahead", "do it", "confirm", "confirmed",
        "please do", "absolutely", "correct", "affirmative", "send it", "approve it", "go for it", "right",
        "of course", "definitely", "that's right",
    ]
}

public enum SafetyPolicy {
    public static func question(for action: AgentAction, agent: BrainAgent?, screen: String?) -> String? {
        let name = agent?.spokenName ?? "the agent"
        let waiting = screen.map { AgentStatus.classify($0) == .waiting } ?? (agent?.status == .waiting)
        let approval = screen.map(isApprovalPrompt) ?? (agent?.status == .waiting)
        switch action {
        case .sendPrompt, .focus:
            return nil
        case .key(_, let key):
            switch key {
            case .esc, .ctrlC:
                let busy = screen.map { AgentStatus.classify($0) == .busy } ?? false
                guard busy || agent?.status == .busy else { return nil }
                return "Should I interrupt \(name)?"
            case .enter:
                guard waiting, approval || mentionsRisk(screen ?? "") else { return nil }
                return "Should I approve what \(name) is asking?"
            }
        case .answer(_, let digit):
            let label = AgentControl.optionLabel(digit, screen: screen)
            let choice = label.map { "option \(digit), \(Self.short($0))," } ?? "option \(digit)"
            if screen == nil || approval || mentionsRisk((screen ?? "") + " " + (label ?? "")) {
                return "Should I choose \(choice) for \(name)?"
            }
            return nil
        case .start(let kind, let directory):
            return "Should I start a new \(kind.displayName) session"
                + (directory.map { " in \(($0 as NSString).lastPathComponent)" } ?? "") + "?"
        case .close:
            return "Should I close \(name)?"
        case .session:
            return nil
        }
    }

    public static func isApprovalPrompt(_ screen: String) -> Bool {
        guard AgentStatus.classify(screen) == .waiting else { return false }
        let tail = screen.split(separator: "\n").suffix(25).joined(separator: "\n").lowercased()
        return approvalMarkers.contains(where: tail.contains)
    }

    public static func mentionsRisk(_ text: String) -> Bool {
        let tail = text.split(separator: "\n").suffix(25).joined(separator: "\n").lowercased()
        return tail.contains(/\b(push|deploy|delete|release|rm|force|publish|drop|reset --hard)\b/)
    }

    private static func short(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    private static let approvalMarkers = [
        "do you want", "would you like to run", "would you like to make", "would you like to proceed",
        "allow once", "allow always", "yes, proceed", "don't ask again", "approve", "ready to code",
        "exit plan mode", "keep planning", "auto-accept edits", "allow command", "permission",
    ]
}
