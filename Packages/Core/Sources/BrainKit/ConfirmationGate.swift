import Foundation
import MonitorKit
import TmuxKit

public enum AgentAction: Equatable, Sendable {
    case sendPrompt(agentID: String, text: String)
    case answer(agentID: String, digit: String)
    case choose(agentID: String, choice: PromptChoice)
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
    private var unanswered: PendingConfirmation?
    private var reconfirmed: PendingConfirmation?

    public init() {}

    public mutating func hold(_ action: AgentAction, question: String) {
        pending = PendingConfirmation(action: action, question: question)
    }

    public mutating func resolve(userTurn: String) -> Resolution {
        let words = Self.words(userTurn)
        guard !words.allSatisfy(Self.fillers.contains) else { return .none }
        reconfirmed = nil
        guard let pending else {
            if let unanswered, Self.isAffirmative(userTurn) { reconfirmed = unanswered }
            unanswered = nil
            return .none
        }
        self.pending = nil
        if Self.confirms(userTurn, pending.action) {
            unanswered = nil
            return .confirmed(pending)
        }
        unanswered = words.contains(where: Self.negations.contains) ? nil : pending
        return .declined(pending)
    }

    public mutating func takeReconfirmed(_ action: AgentAction) -> PendingConfirmation? {
        guard let reconfirmed, reconfirmed.action == action else { return nil }
        self.reconfirmed = nil
        return reconfirmed
    }

    public static func confirms(_ text: String, _ action: AgentAction) -> Bool {
        if isAffirmative(text) { return true }
        guard case .choose(_, let choice) = action, !choice.labels.isEmpty else { return false }
        let label = Set(words(choice.labels.joined(separator: " ")))
        let said = words(text)
        if isAffirmative(said.filter { !(negations.contains($0) && label.contains($0)) }.joined(separator: " ")) {
            return true
        }
        guard !said.contains(where: { negations.contains($0) && !label.contains($0) }) else { return false }
        let options = zip(choice.numbers, choice.labels).map { InteractivePrompt.Option(number: $0, label: $1) }
        return ExplicitChoice.named(choice, by: text, in: options, plain: false)
    }

    public mutating func cancel() {
        pending = nil
        unanswered = nil
        reconfirmed = nil
    }

    public static func isAffirmative(_ text: String) -> Bool {
        let words = words(text)
        guard !words.isEmpty, words.count <= 7 else { return false }
        if words.contains(where: negations.contains) { return false }
        let phrase = " " + words.joined(separator: " ") + " "
        return affirmatives.contains { phrase.contains(" \($0) ") }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    private static let fillers: Set<String> = [
        "uh", "um", "uhm", "umm", "er", "erm", "ah", "hmm", "hm", "mm", "so", "well",
    ]

    private static let negations: Set<String> = [
        "no", "not", "don't", "dont", "nope", "wait", "stop", "cancel", "never", "hold", "but", "instead",
        "nah", "actually", "later", "change",
    ]

    private static let affirmatives = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go ahead", "do it", "confirm", "confirmed",
        "please do", "absolutely", "correct", "affirmative", "send it", "approve it", "go for it", "right",
        "of course", "definitely", "that's right", "allow", "allow it", "approve", "proceed", "choose it", "pick it",
        "select it", "that one", "alright", "all right",
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
            if let label, let effect = effect(of: label) {
                return "Should I choose «\(Self.short(label))» for \(name)? \(effect)"
            }
            let choice = label.map { "option \(digit), \(Self.short($0))," } ?? "option \(digit)"
            if screen == nil || approval || mentionsRisk((screen ?? "") + " " + (label ?? "")) {
                return "Should I choose \(choice) for \(name)?"
            }
            return nil
        case .choose(_, let choice):
            return question(for: choice, name: name, approval: approval, screen: screen)
        case .start(let kind, let directory):
            return "Should I start a new \(kind.displayName) session"
                + (directory.map { " in \(($0 as NSString).lastPathComponent)" } ?? "") + "?"
        case .close:
            return "Should I close \(name)?"
        case .session:
            return nil
        }
    }

    static func question(for choice: PromptChoice, name: String, approval: Bool, screen: String?) -> String? {
        switch choice.action {
        case .cancel, .toggle:
            return nil
        case .submit:
            guard let prompt = screen.flatMap(InteractivePrompt.read),
                prompt.reviewIncomplete || prompt.isSubmitConfirmation
            else { return nil }
            let open = prompt.tabs.filter { !$0.answered }.map(\.label)
            return "Not every question is answered"
                + (open.isEmpty ? "" : " (\(open.joined(separator: ", ")) still open)")
                + ". Should I submit \(name)'s answers anyway?"
        case .select:
            for label in choice.labels {
                if let effect = effect(of: label) { return "Should I choose «\(short(label))» for \(name)? \(effect)" }
            }
            let picked =
                choice.labels.map { "«\(short($0))»" } + (choice.text.map { ["the answer «\(short($0))»"] } ?? [])
            let words = choice.labels.joined(separator: " ") + " " + (choice.text ?? "")
            guard screen == nil || approval || mentionsRisk((screen ?? "") + " " + words) else { return nil }
            return "Should I choose \(picked.joined(separator: " and ")) for \(name)?"
        }
    }

    public static func effect(of label: String) -> String? {
        let text = label.lowercased().replacingOccurrences(of: "’", with: "'")
        if ["bypass", "skip permissions", "dangerously", "full access"].contains(where: text.contains) {
            return "From then on it runs every action without asking."
        }
        if text.contains("auto mode") {
            return "It switches to auto mode: from then on it decides by itself which actions run without asking."
        }
        if text.contains("auto-accept") || text.contains("accept edits") {
            return "From then on it edits files without asking."
        }
        if ["don't ask again", "always allow", "allow always", "remember"].contains(where: text.contains) {
            return "It will not ask again before actions like this one."
        }
        if text.contains("allow") && text.contains("session") {
            return "It will not ask again before actions like this one for the rest of this session."
        }
        return nil
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
