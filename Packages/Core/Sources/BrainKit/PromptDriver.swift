import Foundation
import MonitorKit
import TmuxKit

public struct PromptChoice: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable, CaseIterable {
        case select, toggle, submit, cancel
    }

    public var action: Action
    public var numbers: [Int]
    public var labels: [String]
    public var text: String?
    public var textRow: Int?
    public var question: String

    public init(
        action: Action, numbers: [Int] = [], labels: [String] = [], text: String? = nil, textRow: Int? = nil,
        question: String
    ) {
        self.action = action
        self.numbers = numbers
        self.labels = labels
        self.text = text
        self.textRow = textRow
        self.question = question
    }
}

public enum PromptMatch: Equatable, Sendable {
    case found(InteractivePrompt.Option)
    case none
    case ambiguous([InteractivePrompt.Option])

    public static func resolve(_ request: String, in options: [InteractivePrompt.Option]) -> PromptMatch {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let lowered = trimmed.lowercased()
        if ["last", "the last", "the last one", "last one"].contains(lowered),
            let last = options.last(where: { !$0.freeText && !$0.isTypeSomething })
        {
            return .found(last)
        }
        if let digit = AgentControl.optionDigit(trimmed, screen: nil).flatMap(Int.init) {
            return options.first { $0.number == digit }.map(PromptMatch.found) ?? .none
        }
        if let number = Int(lowered) {
            return options.first { $0.number == number }.map(PromptMatch.found) ?? .none
        }
        let key = AgentResolver.normalize(trimmed)
        if let exact = options.filter({ AgentResolver.normalize($0.label) == key }).only { return .found(exact) }
        let containing = options.filter {
            let label = AgentResolver.normalize($0.label)
            return label.contains(key) || (label.count >= 3 && key.contains(label))
        }
        if let one = containing.only { return .found(one) }
        if containing.count > 1 { return .ambiguous(containing) }
        let wanted = Set(key.split(separator: " ").map(String.init)).subtracting(fillers)
        guard !wanted.isEmpty else { return .none }
        let covering = options.filter {
            let words = Set(AgentResolver.normalize($0.label + " " + $0.detail).split(separator: " ").map(String.init))
            return wanted.isSubset(of: words)
        }
        if let one = covering.only { return .found(one) }
        return covering.isEmpty ? .none : .ambiguous(covering)
    }

    private static let fillers: Set<String> = ["the", "a", "an", "one", "option", "choose", "pick", "select", "please"]
}

extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
}

@MainActor
struct PromptDriver {
    struct Outcome {
        var answered: [String] = []
        var typed: String?
        var finished = false
        var cancelled = false
        var next: InteractivePrompt?
        var open: [String] = []
        var note: String?
    }

    let agent: BrainAgent
    let menu: MenuDriver<InteractivePrompt>

    init(
        agent: BrainAgent, exec: @escaping @MainActor (String) async -> String?,
        sleep: @escaping @MainActor (Duration) async -> Void
    ) {
        self.agent = agent
        menu = MenuDriver(
            agent: agent, exec: exec, sleep: sleep, parse: InteractivePrompt.read, same: { $0.sameQuestion($1) })
    }

    var name: String { agent.spokenName }

    func run(_ choice: PromptChoice) async -> Result<Outcome, PromptError> {
        guard let screen = await menu.screen() else { return .failure(.init("The host is not connected.")) }
        let parsed = InteractivePrompt.read(screen)
        if parsed == nil, AgentStatus.classify(screen) == .busy {
            return .failure(.init("\(name) is working and shows no question. Nothing was pressed."))
        }
        guard let prompt = parsed, prompt.question == choice.question else {
            return .failure(.init("\(name) no longer asks «\(choice.question)». Nothing was pressed."))
        }
        switch choice.action {
        case .cancel: return await cancel(prompt)
        case .toggle: return await toggle(prompt, choice)
        case .submit: return await submit(prompt)
        case .select:
            if prompt.isMultiSelect { return await selectMany(prompt, choice) }
            return await selectOne(prompt, choice)
        }
    }

    private func cancel(_ prompt: InteractivePrompt) async -> Result<Outcome, PromptError> {
        for _ in 0..<2 {
            guard await menu.press([.esc]) else { return .failure(.init("The host is not connected.")) }
            for _ in 0..<8 {
                await menu.sleep(.milliseconds(150))
                guard let screen = await menu.screen() else { continue }
                guard let now = InteractivePrompt.read(screen) else { return .success(Outcome(cancelled: true)) }
                if !now.sameQuestion(prompt) { return .success(Outcome(cancelled: true, next: now)) }
            }
        }
        return .failure(.init("\(name) still shows the question after Esc."))
    }

    private func selectOne(_ prompt: InteractivePrompt, _ choice: PromptChoice) async -> Result<Outcome, PromptError> {
        if let text = choice.text, let row = choice.textRow {
            guard let view = await reach(prompt, row, label: nil) else { return .failure(missed("the typed answer")) }
            if agent.kind == .codex {
                guard await menu.press([.enter]), await notesOpen() else {
                    return .failure(.init("\(name) did not open its notes field. Nothing was answered."))
                }
            }
            guard await menu.type(line(text)) else { return .failure(.init("The host is not connected.")) }
            guard await shows(text, row: agent.kind == .codex ? nil : row, in: view) else {
                return .failure(.init("The typed text did not appear in \(name)'s answer field. Nothing was answered."))
            }
            guard await menu.press([.enter]) else { return .failure(.init("The host is not connected.")) }
            return await settle(prompt, Outcome(typed: text))
        }
        guard let number = choice.numbers.first, let label = choice.labels.first else {
            return .failure(.init("Name the option to choose."))
        }
        if prompt.options.contains(where: { $0.number == number && $0.isChat }) {
            guard await menu.type(String(number)) else { return .failure(missed(label)) }
            return await settle(prompt, Outcome(answered: [label]))
        }
        guard await reach(prompt, number, label: label) != nil else { return .failure(missed(label)) }
        guard await menu.press([.enter]) else { return .failure(.init("The host is not connected.")) }
        return await settle(prompt, Outcome(answered: [label]))
    }

    private func selectMany(_ prompt: InteractivePrompt, _ choice: PromptChoice) async -> Result<Outcome, PromptError> {
        var view = prompt
        var rows = prompt.items
        if prompt.moreAbove || prompt.moreBelow {
            (rows, view) = await menu.collect(prompt)
        }
        let wanted = Set(choice.numbers)
        for row in rows where row.checked != nil && row.number != choice.textRow && !row.isTypeSomething {
            guard row.checked != wanted.contains(row.number) else { continue }
            guard let next = await flip(view, row.number, label: row.label) else { return .failure(missed(row.label)) }
            view = next
        }
        if let text = choice.text, let row = choice.textRow {
            guard let reached = await reach(view, row, label: nil),
                reached.items.first(where: { $0.number == row })?.isTypeSomething == true
            else {
                return .failure(.init("The typed answer field of \(name) already has text. Nothing was submitted."))
            }
            guard await menu.type(line(text)), await shows(text, row: row, in: reached) else {
                return .failure(
                    .init("The typed text did not appear in \(name)'s answer field. Nothing was submitted."))
            }
            view = await menu.wait { $0.sameQuestion(prompt) } ?? reached
        }
        let checked = view.items.filter { $0.checked == true }.map(\.label)
        return await pressButton(view, Outcome(answered: checked, typed: choice.text))
    }

    private func toggle(_ prompt: InteractivePrompt, _ choice: PromptChoice) async -> Result<Outcome, PromptError> {
        guard prompt.isMultiSelect else {
            return .failure(.init("This question takes one answer. Use select with one option."))
        }
        var view = prompt
        for (number, label) in zip(choice.numbers, choice.labels) {
            guard let next = await flip(view, number, label: label) else { return .failure(missed(label)) }
            view = next
        }
        let checked = view.items.filter { $0.checked == true }.map(\.label)
        var outcome = Outcome(answered: checked, next: view)
        outcome.note = "Nothing was submitted yet. Use action submit when the user is done."
        return .success(outcome)
    }

    private func submit(_ prompt: InteractivePrompt) async -> Result<Outcome, PromptError> {
        if prompt.isReview || prompt.isSubmitConfirmation {
            let label = prompt.isReview ? "Submit answers" : "Proceed"
            guard let row = prompt.options.first(where: { $0.label == label }),
                await reach(prompt, row.number, label: label) != nil, await menu.press([.enter])
            else { return .failure(missed(label)) }
            return await settle(prompt, Outcome(), submitReview: false)
        }
        guard prompt.isMultiSelect else {
            return .failure(.init("This question has no submit step: choose an option with select."))
        }
        let checked = prompt.items.filter { $0.checked == true }.map(\.label)
        return await pressButton(prompt, Outcome(answered: checked))
    }

    private func pressButton(_ view: InteractivePrompt, _ outcome: Outcome) async -> Result<Outcome, PromptError> {
        guard let last = view.items.last, let bottom = await menu.move(from: view, to: last.number) else {
            return .failure(missed("the last option"))
        }
        let label = bottom.button?.label ?? "Submit"
        guard await menu.press([.down]),
            let focused = await menu.wait({ $0.sameQuestion(view) && $0.button?.highlighted == true }),
            await menu.press([.enter])
        else { return .failure(missed(label)) }
        return await settle(focused, outcome)
    }

    private func reach(_ view: InteractivePrompt, _ number: Int, label: String?) async -> InteractivePrompt? {
        guard let moved = await menu.move(from: view, to: number) else { return nil }
        guard let label else { return moved }
        return moved.items.first(where: { $0.number == number })?.label == label ? moved : nil
    }

    private func flip(_ view: InteractivePrompt, _ number: Int, label: String) async -> InteractivePrompt? {
        guard let reached = await reach(view, number, label: label),
            let before = reached.items.first(where: { $0.number == number })?.checked,
            await menu.press([.space])
        else { return nil }
        return await menu.wait {
            $0.sameQuestion(view) && $0.items.first(where: { $0.number == number })?.checked == !before
        }
    }

    private func notesOpen() async -> Bool {
        for _ in 0..<8 {
            await menu.sleep(.milliseconds(150))
            if let screen = await menu.screen(), screen.lowercased().contains("to clear notes") { return true }
        }
        return false
    }

    private func shows(_ text: String, row: Int?, in view: InteractivePrompt) async -> Bool {
        let probe = AgentResolver.normalize(String(line(text).prefix(24)))
        for _ in 0..<10 {
            await menu.sleep(.milliseconds(150))
            guard let screen = await menu.screen() else { continue }
            if let row {
                guard let now = InteractivePrompt.read(screen), now.sameQuestion(view),
                    let option = now.items.first(where: { $0.number == row })
                else { continue }
                if AgentResolver.normalize(option.label + " " + option.detail).hasPrefix(probe) { return true }
            } else if AgentResolver.normalize(screen).contains(probe) {
                return true
            }
        }
        return false
    }

    private func settle(_ original: InteractivePrompt, _ outcome: Outcome, submitReview: Bool = true) async -> Result<
        Outcome, PromptError
    > {
        var outcome = outcome
        var other = false
        for _ in 0..<16 {
            await menu.sleep(.milliseconds(150))
            guard let screen = await menu.screen() else { continue }
            guard let next = InteractivePrompt.read(screen) else {
                other = AgentStatus.classify(screen) == .waiting
                if other { continue }
                outcome.finished = true
                return .success(outcome)
            }
            other = false
            if next.sameQuestion(original) { continue }
            if next.isReview {
                return await afterReview(next, outcome, submit: submitReview)
            }
            if next.isSubmitConfirmation {
                guard await menu.press([.esc]), let back = await menu.wait({ !$0.isSubmitConfirmation }) else {
                    return .failure(.init("\(name) asks to submit with unanswered questions. Nothing was submitted."))
                }
                outcome.next = back
                outcome.note = "Some questions are not answered yet, so nothing was submitted. This is the first one."
                return .success(outcome)
            }
            if agent.kind == .codex, submitReview, let progress = next.progress,
                !(next.header ?? "").contains("unanswered")
            {
                return await finishCodex(next, progress: progress, outcome)
            }
            outcome.next = next
            return .success(outcome)
        }
        if other {
            outcome.finished = true
            outcome.note = "\(name) now shows another prompt that the app cannot read."
            return .success(outcome)
        }
        return .failure(.init("\(name) still shows the same question. The answer did not go through."))
    }

    private func finishCodex(_ next: InteractivePrompt, progress: (index: Int, total: Int), _ outcome: Outcome) async
        -> Result<Outcome, PromptError>
    {
        var last = next
        if progress.index < progress.total {
            guard await menu.press(Array(repeating: .right, count: progress.total - progress.index)),
                let moved = await menu.wait({ $0.progress?.index == progress.total })
            else {
                var outcome = outcome
                outcome.next = next
                return .success(outcome)
            }
            last = moved
        }
        guard await menu.press([.enter]) else { return .failure(.init("The host is not connected.")) }
        return await settle(last, outcome, submitReview: false)
    }

    private func afterReview(_ review: InteractivePrompt, _ outcome: Outcome, submit: Bool) async -> Result<
        Outcome, PromptError
    > {
        var outcome = outcome
        let open = review.tabs.enumerated().filter { !$0.element.answered }
        if !review.reviewIncomplete, submit {
            guard await reach(review, 1, label: "Submit answers") != nil, await menu.press([.enter]) else {
                return .failure(missed("Submit answers"))
            }
            return await settle(review, outcome, submitReview: false)
        }
        guard let first = open.first else {
            outcome.next = review
            return .success(outcome)
        }
        outcome.open = open.map { $0.element.label }
        guard await menu.press(Array(repeating: .left, count: review.tabs.count - first.offset)),
            let back = await menu.wait({ !$0.isReview })
        else {
            outcome.next = review
            outcome.note = "Some questions are not answered yet, so nothing was submitted."
            return .success(outcome)
        }
        outcome.next = back
        outcome.note = "Some questions are not answered yet, so nothing was submitted. This is the first one."
        return .success(outcome)
    }

    private func missed(_ label: String) -> PromptError {
        PromptError("The selection in \(name)'s menu did not reach «\(label)». Nothing more was pressed.")
    }

    private func line(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

struct PromptError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
