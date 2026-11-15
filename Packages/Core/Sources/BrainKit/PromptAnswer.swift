import Foundation
import MonitorKit
import TmuxKit

extension AgentToolbox {
    func readPrompts(_ listed: [BrainAgent]) async -> [BrainAgent] {
        var agents = listed
        for index in agents.indices where agents[index].status == .waiting && agents[index].prompt == nil {
            guard case .herdr = agents[index].location,
                let screen = await io.exec(AgentControl.screenCommand(agents[index]))
            else { continue }
            agents[index].prompt = InteractivePrompt.read(screen)
        }
        return agents
    }

    public func answerPrompt(agentID: String, number: Int, expected: InteractivePrompt) async -> String {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return Self.error("That agent is gone.") }
        guard let screen = await io.exec(AgentControl.screenCommand(agent)) else {
            return Self.error("The host is not connected.")
        }
        guard let current = InteractivePrompt.read(screen), current.question == expected.question,
            current.options.map(\.label) == expected.options.map(\.label),
            current.options.contains(where: { $0.number == number })
        else { return Self.error("\(agent.spokenName) no longer asks that question.") }
        return await perform(.answer(agentID: agentID, digit: String(number)))
    }

    func answerQuestion(_ agent: BrainAgent, _ arguments: [String: Any]) async -> String {
        let name = agent.spokenName
        guard let screen = await io.exec(AgentControl.screenCommand(agent)) else {
            return Self.error("The host is not connected.")
        }
        let parsed = InteractivePrompt.read(screen)
        if parsed == nil, AgentStatus.classify(screen) == .busy {
            return Self.error("\(name) is working and shows no question. Nothing was pressed.")
        }
        guard var action = PromptChoice.Action(rawValue: (arguments["action"] as? String ?? "select").lowercased())
        else { return Self.error("action must be select, toggle, submit, or cancel") }
        var requests = (arguments["options"] as? [Any])?.map { "\($0)" } ?? []
        if let option = arguments["option"], !(option is NSNull) { requests.insert("\(option)", at: 0) }
        requests = requests.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let text = ((arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        guard let prompt = parsed else {
            guard action == .select, text == nil, requests.count == 1, AgentStatus.classify(screen) == .waiting,
                let digit = AgentControl.optionDigit(requests[0], screen: screen)
            else { return Self.error("\(name) shows no question or menu the app can read. Nothing was pressed.") }
            return await request(.answer(agentID: agent.id, digit: digit), agent: agent, screen: screen)
        }
        var options = prompt.options
        if [.select, .toggle].contains(action), prompt.moreAbove || prompt.moreBelow,
            text != nil || requests.contains(where: { PromptMatch.resolve($0, in: options) == .none })
        {
            let menu = MenuDriver(
                agent: agent, exec: io.exec, sleep: io.sleep, parse: InteractivePrompt.read,
                same: { $0.sameQuestion($1) })
            let (items, _) = await menu.collect(prompt)
            options = items + prompt.options.filter(\.isChat)
        }
        var targets: [InteractivePrompt.Option] = []
        for request in requests {
            switch PromptMatch.resolve(request, in: options) {
            case .found(let option): targets.append(option)
            case .none:
                return Self.error(
                    "No option matches «\(request)». Nothing was pressed. Options: "
                        + options.map { "\($0.number) \($0.label)" }.joined(separator: "; "))
            case .ambiguous(let matches):
                return Self.error(
                    "More than one option matches «\(request)»: " + matches.map(\.label).joined(separator: "; ")
                        + ". Nothing was pressed. Ask the user which one.")
            }
        }
        let textRow =
            options.last(where: { $0.isTypeSomething && !$0.isChat })?.number
            ?? (prompt.isMultiSelect ? prompt.items.last?.number : nil)
        if text != nil {
            guard let textRow else { return Self.error("This question has no free-text option. Nothing was pressed.") }
            targets.removeAll { $0.number == textRow }
        } else if targets.contains(where: { $0.isTypeSomething || $0.number == textRow }) {
            return Self.error("Pass the user's own words in text to type a free-text answer.")
        }
        if action == .select, prompt.isReview || prompt.isSubmitConfirmation,
            targets.map(\.label) == ["Submit answers"] || targets.map(\.label) == ["Proceed"]
        {
            action = .submit
        }
        switch action {
        case .select where prompt.isMultiSelect:
            if targets.isEmpty, text == nil { return Self.error("Name the options to check.") }
        case .select:
            guard targets.count + (text == nil ? 0 : 1) == 1 else {
                return Self.error("This question takes exactly one answer. Nothing was pressed.")
            }
        case .toggle:
            guard prompt.isMultiSelect, !targets.isEmpty else {
                return Self.error("toggle works only on the checkboxes of a multi-select question.")
            }
        case .submit, .cancel:
            break
        }
        let choice = PromptChoice(
            action: action, numbers: targets.map(\.number), labels: targets.map(\.label), text: text,
            textRow: textRow, question: prompt.question)
        let held = AgentAction.choose(agentID: agent.id, choice: choice)
        if let text, let turns = spokenTurns, !PromptFidelity.isVerbatim(text, turns: turns) {
            return hold(held, question: PromptFidelity.readBack(text, agent: name))
        }
        if userChose(choice, prompt: prompt, options: options, agent: agent) { return await perform(held) }
        return await request(held, agent: agent, screen: screen)
    }

    func choose(_ agent: BrainAgent, _ choice: PromptChoice) async -> String {
        let driver = PromptDriver(agent: agent, exec: io.exec, sleep: io.sleep)
        switch await driver.run(choice) {
        case .failure(let failure):
            return Self.error(failure.message)
        case .success(let outcome):
            handedOver[agent.id] = outcome.next
            var extra: [String: Any] = [:]
            if choice.action == .toggle { extra["checked"] = outcome.answered }
            if let next = outcome.next { extra["next"] = PromptSpeech.summary(next) }
            if !outcome.open.isEmpty { extra["unanswered"] = outcome.open }
            if let note = outcome.note { extra["note"] = note }
            let word =
                outcome.cancelled
                ? "Cancelled."
                : choice.action == .toggle ? "Done." : choice.action == .submit ? "Submitted." : "Answered."
            return Self.done(word, extra)
        }
    }

    public func noteUserTurn() {
        var seen: [String: [InteractivePrompt]] = [:]
        for agent in agents { if let prompt = agent.prompt { seen[agent.id, default: []].append(prompt) } }
        for (id, prompt) in handedOver { seen[id, default: []].append(prompt) }
        promptsAtTurn = seen
    }

    func userChose(
        _ choice: PromptChoice, prompt: InteractivePrompt, options: [InteractivePrompt.Option], agent: BrainAgent
    ) -> Bool {
        guard let turn = spokenTurns?.last,
            promptsAtTurn[agent.id]?.contains(where: { $0.sameContent(prompt) }) == true
        else { return false }
        let key = AgentResolver.normalize(turn)
        let others = agents.filter { $0.id != agent.id && promptsAtTurn[$0.id] != nil }
        if let rival = others.map({ AgentResolver.score(key, $0) }).max(), AgentResolver.score(key, agent) <= rival {
            return false
        }
        return ExplicitChoice.named(choice, by: turn, in: options)
    }

    nonisolated public static func failure(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["error"] as? String
    }
}

extension InteractivePrompt {
    public func sameContent(_ other: InteractivePrompt) -> Bool {
        sameQuestion(other) && context == other.context && options.map(\.label) == other.options.map(\.label)
    }
}

public enum ExplicitChoice {
    public static func named(
        _ choice: PromptChoice, by turn: String, in options: [InteractivePrompt.Option], plain: Bool = true
    ) -> Bool {
        let said = words(turn)
        guard !said.isEmpty, !delegates(said) else { return false }
        let picked = Set(choice.numbers)
        let typed = choice.text.map { PromptFidelity.isVerbatim($0, turns: [turn]) } ?? true
        switch choice.action {
        case .submit:
            return said.contains("submit")
        case .cancel, .toggle:
            return false
        case .select:
            guard typed else { return false }
            let named = numbers(said, in: options, plain: plain)
            let multi = options.contains { $0.checked != nil }
            if picked.isEmpty { return choice.text != nil }
            return multi ? picked.isSubset(of: named) : named == picked
        }
    }

    public static func numbers(_ said: [String], in options: [InteractivePrompt.Option], plain: Bool = true) -> Set<
        Int
    > {
        let rows = options.filter { !$0.isChat }
        var named = Set<Int>()
        for (index, word) in said.enumerated() {
            if let digit = Int(word), (1...9).contains(digit) { named.insert(digit) }
            if let digit = ordinals[word] { named.insert(digit) }
            if word == "last", let last = rows.last(where: { !$0.freeText && !$0.isTypeSomething }) {
                named.insert(last.number)
            }
            if let digit = numberWords[word], index > 0, ["option", "number", "choice"].contains(said[index - 1]) {
                named.insert(digit)
            }
        }
        let core = said.filter { !fillers.contains($0) }
        if core.count == 1, let digit = numberWords[core[0]] { named.insert(digit) }
        let labels = rows.map { Set(words($0.label)).subtracting(stopwords) }
        for (index, option) in rows.enumerated() {
            let others = labels.indices.filter { $0 != index }.reduce(into: Set<String>()) { $0.formUnion(labels[$1]) }
            let distinct = labels[index].subtracting(others)
            if !distinct.isEmpty, distinct.intersection(said).count >= min(2, distinct.count) {
                named.insert(option.number)
            }
        }
        if let effect = SafetyPolicy.effect(
            of: said.joined(separator: " ").replacingOccurrences(of: "dont", with: "don't"))
        {
            let matching = rows.filter { SafetyPolicy.effect(of: $0.label) == effect }
            named.formUnion(matching.map(\.number))
        }
        guard named.isEmpty, plain else { return named }
        var phrase = " " + said.joined(separator: " ") + " "
        for effect in effectPhrases { phrase = phrase.replacingOccurrences(of: " \(effect) ", with: " ") }
        let bare = phrase.split(separator: " ").map(String.init)
        let yes = bare.contains(where: yesWords.contains)
        let no = bare.contains(where: noWords.contains)
        let choices = rows.filter { !$0.freeText && !$0.isTypeSomething }
        let plainYes = choices.filter { words($0.label).first == "yes" && SafetyPolicy.effect(of: $0.label) == nil }
        if yes, !no, plainYes.count == 1 { named.insert(plainYes[0].number) }
        if no, !bare.contains(where: ["yes", "yeah", "yep", "yup", "sure", "ok", "okay"].contains),
            let option = choices.first(where: { words($0.label).first == "no" })
        {
            named.insert(option.number)
        }
        return named
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'").replacing(/\[app:[^\]]*\]/, with: " ")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }

    private static func delegates(_ said: [String]) -> Bool {
        let phrase = " " + said.joined(separator: " ") + " "
        return delegations.contains { phrase.contains(" \($0) ") }
    }

    private static let delegations = [
        "whatever", "whichever", "you think", "up to you", "your call", "you decide", "you choose", "you pick",
        "your choice", "handle it", "doesnt matter", "dont care", "either", "any of them", "best", "instead",
        "rather", "except", "but",
    ]

    private static let effectPhrases = [
        "dont ask again", "do not ask again", "dont ask me again", "always allow", "allow always", "auto mode",
        "auto accept", "accept edits", "bypass permissions", "bypass", "skip permissions", "full access",
    ]

    private static let yesWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "allow", "approve", "approved", "proceed", "accept",
    ]
    private static let noWords: Set<String> = ["no", "nope", "deny", "reject", "decline", "dont", "not", "never"]

    private static let numberWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let ordinals = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5,
    ]
    private static let fillers: Set<String> = [
        "the", "option", "number", "choice", "please", "pick", "choose", "select", "take", "go", "with", "i", "want",
        "lets", "its", "it", "that", "say", "answer", "is",
    ]
    private static let stopwords: Set<String> = [
        "a", "an", "and", "or", "the", "to", "for", "of", "in", "on", "at", "this", "that", "it", "with", "from",
        "what",
        "do", "is", "be", "i", "you", "me", "my", "your", "its", "esc", "tab", "shift", "ctrl", "recommended",
        "claude", "codex",
    ]
}
