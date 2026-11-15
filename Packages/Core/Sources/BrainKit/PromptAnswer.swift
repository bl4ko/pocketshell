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

    nonisolated public static func failure(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["error"] as? String
    }
}
