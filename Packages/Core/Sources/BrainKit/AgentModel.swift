import Foundation
import MonitorKit
import TmuxKit

public struct ModelRow: Equatable, Sendable {
    public var number: Int
    public var label: String
    public var detail: String
    public var isCurrent: Bool
    public var isHighlighted: Bool

    public init(number: Int, label: String, detail: String = "", isCurrent: Bool = false, isHighlighted: Bool = false) {
        self.number = number
        self.label = label
        self.detail = detail
        self.isCurrent = isCurrent
        self.isHighlighted = isHighlighted
    }

    var summary: String {
        let head = ModelPicker.detailHead(detail)
        let text = head.isEmpty || head == "From gateway" ? label : "\(label): \(head)"
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}

public struct ModelPicker: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case model, effort
    }

    public var step: Step
    public var rows: [ModelRow]
    public var moreAbove = false
    public var moreBelow = false

    public var highlighted: Int? { rows.first(where: \.isHighlighted)?.number }

    public static func parse(_ screen: String) -> ModelPicker? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard
            let start = lines.lastIndex(where: {
                let line = $0.trimmingCharacters(in: .whitespaces).lowercased()
                return line.hasPrefix("select model") || line.hasPrefix("select reasoning level")
            })
        else { return nil }
        guard
            let end = lines[start...].firstIndex(where: {
                let line = $0.lowercased()
                return line.contains("esc to cancel") || line.contains("esc back")
            })
        else { return nil }
        let header = lines[start].trimmingCharacters(in: .whitespaces).lowercased()
        var picker = ModelPicker(step: header.hasPrefix("select reasoning") ? .effort : .model, rows: [])
        for line in lines[(start + 1)..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "↑" {
                picker.moreAbove = true
            } else if trimmed == "↓" || (trimmed.hasPrefix("…") && trimmed.contains("+")) {
                picker.moreBelow = true
            } else if let match = line.wholeMatch(of: /\s*([❯›↑↓])?\s*(\d+)\.\s+(.+?)(?:\s{2,}(.+?))?\s*/),
                let number = Int(match.2)
            {
                let marker = match.1.map(String.init)
                if marker == "↑" { picker.moreAbove = true }
                if marker == "↓" { picker.moreBelow = true }
                let raw = String(match.3)
                let label = raw.replacingOccurrences(of: "✔", with: "").replacingOccurrences(of: "(current)", with: "")
                    .trimmingCharacters(in: .whitespaces)
                picker.rows.append(
                    ModelRow(
                        number: number, label: label, detail: match.4.map(String.init) ?? "",
                        isCurrent: raw.contains("✔") || raw.contains("(current)"),
                        isHighlighted: marker == "❯" || marker == "›"))
            } else if !trimmed.isEmpty, !trimmed.contains("←/→"), !picker.rows.isEmpty {
                picker.rows[picker.rows.count - 1].detail += " " + trimmed
            }
        }
        guard let first = picker.rows.first else { return nil }
        if first.number > 1 { picker.moreAbove = true }
        return picker
    }

    public static func confirmation(_ screen: String) -> String? {
        screen.split(separator: "\n").reversed().lazy.compactMap {
            $0.firstMatch(of: /(?:Set model to|Model changed to) (.+?) for this session only/).map { String($0.1) }
        }.first
    }

    public static func kept(_ screen: String) -> String? {
        screen.split(separator: "\n").reversed().lazy.compactMap {
            $0.firstMatch(of: /Kept model as (.+?)\s*$/).map { String($0.1) }
        }.first
    }

    public static func effort(in screen: String, model: String) -> String? {
        let pattern =
            NSRegularExpression.escapedPattern(for: model) + "\\s+(minimal|low|medium|high|xhigh|extra high)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        for line in screen.split(separator: "\n").suffix(8).reversed() {
            let text = String(line)
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let range = Range(match.range(at: 1), in: text)
            else { continue }
            return text[range].lowercased()
        }
        return nil
    }

    static func detailHead(_ detail: String) -> String {
        detail.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("$") }.joined(separator: ", ")
    }
}

public enum ModelMatch: Equatable, Sendable {
    case found(ModelRow)
    case none
    case ambiguous([ModelRow])

    public static func resolve(_ request: String, in rows: [ModelRow]) -> ModelMatch {
        let wanted = tokens(request)
        guard !wanted.isEmpty else { return .none }
        let scored = rows.map { (row: $0, score: score(wanted, $0)) }.filter { $0.score > 0 }
        guard let best = scored.map(\.score).max() else { return .none }
        let top = scored.filter { $0.score == best }.map(\.row)
        return top.count == 1 ? .found(top[0]) : .ambiguous(top)
    }

    static func score(_ wanted: [String], _ row: ModelRow) -> Int {
        let label = tokens(row.label)
        let detail = tokens(ModelPicker.detailHead(row.detail))
        if label == wanted { return 100 }
        var score = 0
        var matched = false
        for token in wanted {
            let isVersion = token.first?.isNumber == true
            if label.contains(where: { same(token, $0) }) {
                score += 2
                matched = true
            } else if detail.contains(where: { same(token, $0) }) {
                score += 1
                matched = true
            } else if isVersion {
                return 0
            } else {
                score -= 1
            }
        }
        return matched ? max(score, 0) : 0
    }

    static func same(_ token: String, _ word: String) -> Bool {
        if token == word { return true }
        guard token.first?.isLetter == true, word.first?.isLetter == true, min(token.count, word.count) >= 3 else {
            return false
        }
        return word.hasPrefix(token) || token.hasPrefix(word)
    }

    static func tokens(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if let last = current.last, last.isNumber != character.isNumber { flush() }
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        var result: [String] = []
        var lastWasNumber = false
        for (index, word) in words.enumerated() {
            let number = numberWords[word] ?? (word.allSatisfy(\.isNumber) ? word : nil)
            if word == "one", index > 0, !lastWasNumber, !["point", "dot"].contains(words[index - 1]) {
                lastWasNumber = false
                continue
            }
            if let number {
                if lastWasNumber, let previous = result.popLast() {
                    result.append(previous + "." + number)
                } else {
                    result.append(number)
                }
                lastWasNumber = true
            } else if ["point", "dot"].contains(word), lastWasNumber {
                continue
            } else {
                lastWasNumber = false
                if !stopWords.contains(word) { result.append(word) }
            }
        }
        return result
    }

    private static let numberWords = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10",
    ]

    private static let stopWords: Set<String> = [
        "the", "a", "an", "to", "use", "model", "models", "switch", "set", "change", "please", "on", "in", "for",
        "it", "this", "that", "with", "version", "one", "and", "of",
    ]
}

public enum AgentModelSwitch {
    public enum Outcome: Equatable, Sendable {
        case current(model: String, choices: [ModelRow])
        case switched(model: String)
        case unchanged(model: String)
        case noMatch(choices: [ModelRow])
        case ambiguous([ModelRow])
        case failed(String)
    }

    @MainActor
    public struct IO {
        public var exec: @MainActor (String) async -> String?
        public var sleep: @MainActor (Duration) async -> Void

        public init(
            exec: @escaping @MainActor (String) async -> String?,
            sleep: @escaping @MainActor (Duration) async -> Void
        ) {
            self.exec = exec
            self.sleep = sleep
        }
    }

    @MainActor
    public static func read(_ agent: BrainAgent, io: IO) async -> Outcome {
        let before = await io.exec(AgentControl.screenCommand(agent)) ?? ""
        let driver = Driver(agent: agent, io: io)
        guard let opened = await driver.open() else { return .failed(driver.notOpened) }
        let (rows, _) = await driver.collect(opened)
        let current = rows.first(where: \.isCurrent) ?? opened.rows.first(where: \.isCurrent)
        let kept = await driver.cancel()
        guard let current else { return .failed("\(agent.kind.displayName) marks no model as current.") }
        return .current(model: kept ?? driver.name(current, screen: before), choices: rows)
    }

    @MainActor
    public static func set(_ agent: BrainAgent, to request: String, io: IO) async -> Outcome {
        let before = await io.exec(AgentControl.screenCommand(agent)) ?? ""
        let driver = Driver(agent: agent, io: io)
        guard let opened = await driver.open() else { return .failed(driver.notOpened) }
        let (rows, last) = await driver.collect(opened)
        let target: ModelRow
        switch ModelMatch.resolve(request, in: rows) {
        case .found(let row): target = row
        case .none:
            _ = await driver.cancel()
            return .noMatch(choices: rows)
        case .ambiguous(let options):
            _ = await driver.cancel()
            return .ambiguous(options)
        }
        if target.isCurrent {
            let kept = await driver.cancel()
            return .unchanged(model: kept ?? driver.name(target, screen: before))
        }
        guard await driver.move(from: last, to: target.number) != nil else {
            _ = await driver.cancel()
            return .failed("The model menu did not move to \(target.label). Nothing changed.")
        }
        if agent.kind == .codex {
            let effort = rows.first(where: \.isCurrent).flatMap { ModelPicker.effort(in: before, model: $0.label) }
            guard await io.exec(AgentControl.keyCommand(agent, key: .enter)) != nil,
                let levels = await driver.wait({ $0.step == .effort })
            else {
                _ = await driver.cancel()
                return .failed("Codex did not ask for the reasoning level. Nothing changed.")
            }
            let keep = effort.map(Self.effortMatcher)
            let level =
                levels.rows.first { keep?($0) == true }
                ?? levels.rows.first { $0.label.contains("(default)") } ?? levels.rows.first(where: \.isHighlighted)
            guard let level, await driver.move(from: levels, to: level.number) != nil else {
                _ = await driver.cancel()
                return .failed("The reasoning level menu did not move. Nothing changed.")
            }
        }
        guard await io.exec(AgentControl.textCommand(agent, text: "s")) != nil else {
            return .failed("The host is not connected.")
        }
        for _ in 0..<15 {
            await io.sleep(.milliseconds(200))
            guard let screen = await io.exec(AgentControl.screenCommand(agent)) else { continue }
            if ModelPicker.parse(screen) == nil, let model = ModelPicker.confirmation(screen) {
                return .switched(model: model)
            }
        }
        return .failed("\(agent.kind.displayName) did not confirm the model change. Check the session.")
    }

    static func effortMatcher(_ effort: String) -> (ModelRow) -> Bool {
        let wanted = effort == "xhigh" ? "extra high" : effort
        return { row in
            row.label.lowercased().replacingOccurrences(of: "(default)", with: "")
                .trimmingCharacters(in: .whitespaces) == wanted
        }
    }

    @MainActor
    struct Driver {
        let agent: BrainAgent
        let io: IO

        var notOpened: String { "\(agent.kind.displayName) did not open its model menu. Nothing changed." }

        func open() async -> ModelPicker? {
            guard await io.exec(AgentControl.slashCommand(agent, "/model")) != nil else { return nil }
            if let picker = await wait({ $0.step == .model }) { return picker }
            _ = await io.exec(AgentControl.keyCommand(agent, key: .esc))
            return nil
        }

        func cancel() async -> String? {
            for _ in 0..<3 {
                _ = await io.exec(AgentControl.keyCommand(agent, key: .esc))
                for _ in 0..<4 {
                    await io.sleep(.milliseconds(200))
                    guard let screen = await io.exec(AgentControl.screenCommand(agent)) else { continue }
                    if ModelPicker.parse(screen) == nil { return ModelPicker.kept(screen) }
                }
            }
            return nil
        }

        func name(_ row: ModelRow, screen: String) -> String {
            if agent.kind == .codex, let effort = ModelPicker.effort(in: screen, model: row.label) {
                return "\(row.label) \(effort)"
            }
            let head = row.detail.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return head.contains(where: \.isNumber) && !head.contains("$") ? head : row.label
        }

        func wait(_ condition: (ModelPicker) -> Bool) async -> ModelPicker? {
            for _ in 0..<12 {
                await io.sleep(.milliseconds(150))
                guard let screen = await io.exec(AgentControl.screenCommand(agent)),
                    let picker = ModelPicker.parse(screen), condition(picker)
                else { continue }
                return picker
            }
            return nil
        }

        func move(from picker: ModelPicker, to number: Int) async -> ModelPicker? {
            guard let highlighted = picker.highlighted else { return nil }
            if highlighted == number { return picker }
            let command = AgentControl.arrowCommand(
                agent, up: number < highlighted, count: abs(number - highlighted))
            guard await io.exec(command) != nil else { return nil }
            return await wait { $0.step == picker.step && $0.highlighted == number }
        }

        func collect(_ first: ModelPicker) async -> (rows: [ModelRow], last: ModelPicker) {
            var rows: [Int: ModelRow] = [:]
            func merge(_ picker: ModelPicker) {
                for row in picker.rows where rows[row.number] == nil { rows[row.number] = row }
            }
            merge(first)
            var picker = first
            func sorted() -> [ModelRow] {
                rows.values.sorted { $0.number < $1.number }.map {
                    var row = $0
                    row.isHighlighted = false
                    return row
                }
            }
            guard first.moreAbove || first.moreBelow else { return (sorted(), picker) }
            if let top = await move(from: picker, to: 1) {
                picker = top
                merge(top)
            } else {
                return (sorted(), picker)
            }
            guard await io.exec(AgentControl.arrowCommand(agent, up: true, count: 1)) != nil,
                let bottom = await wait({ $0.step == .model && $0.highlighted != 1 }),
                let total = bottom.highlighted
            else { return (sorted(), picker) }
            picker = bottom
            merge(bottom)
            var previous: Int?
            for _ in 0..<12 {
                guard let missing = (1...total).last(where: { rows[$0] == nil }) else { break }
                let target = missing == previous ? missing : max(1, missing - max(1, picker.rows.count) + 1)
                previous = missing
                guard let moved = await move(from: picker, to: target) else { break }
                picker = moved
                merge(moved)
            }
            return (sorted(), picker)
        }
    }
}

extension AgentToolbox {
    func model(_ agent: BrainAgent, request: String?) async -> String {
        guard let screen = await io.exec(AgentControl.screenCommand(agent)) else {
            return Self.error("The host is not connected.")
        }
        let name = agent.spokenName
        switch AgentStatus.classify(screen) {
        case .busy:
            return Self.error("\(name) is working. Its model can change only when it is idle. Nothing changed.")
        case .waiting:
            return Self.error("\(name) shows a question or a menu. It must be answered first. Nothing changed.")
        case .idle:
            break
        }
        if let unsent = await unsentPrompt(for: agent) {
            return Self.error(
                "\(name) has an unsent prompt in its input box: «\(String(unsent.prefix(300)))». The model changes "
                    + "only with an empty box: the user must send or clear it first. Nothing changed.")
        }
        let switchIO = AgentModelSwitch.IO(exec: io.exec, sleep: io.sleep)
        let outcome =
            if let request {
                await AgentModelSwitch.set(agent, to: request, io: switchIO)
            } else {
                await AgentModelSwitch.read(agent, io: switchIO)
            }
        switch outcome {
        case .current(let model, let choices):
            return Self.json(["agent": name, "model": model, "choices": choices.map(\.summary)])
        case .switched(let model):
            return Self.json(["agent": name, "model": model, "switched": true, "scope": "this session only"])
        case .unchanged(let model):
            return Self.json([
                "agent": name, "model": model, "switched": false, "note": "This model was already active.",
            ])
        case .noMatch(let choices):
            return Self.json([
                "error": "No model in the menu of \(name) matches «\(request ?? "")». Nothing changed. "
                    + "Ask the user to choose one of the choices.",
                "choices": choices.map(\.summary),
            ])
        case .ambiguous(let options):
            return Self.json([
                "error": "More than one model matches «\(request ?? "")». Nothing changed. Ask the user which one.",
                "choices": options.map(\.summary),
            ])
        case .failed(let message):
            return Self.error(message)
        }
    }
}
