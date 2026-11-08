import Foundation

/// Text an agent holds in its input box but has not submitted yet, read from the screen.
public struct UnsentPrompt: Equatable, Sendable {
    public enum Agent: String, Sendable {
        case claude
        case codex
    }

    public var agent: Agent
    public var text: String
    public var rows: Int
    /// False when the box shows tokens like `[Pasted text #1 +14 lines]` that stand for text not on screen.
    public var isComplete: Bool

    public init(agent: Agent, text: String, rows: Int, isComplete: Bool = true) {
        self.agent = agent
        self.text = text
        self.rows = rows
        self.isComplete = isComplete
    }

    public var isEmpty: Bool { text.isEmpty && isComplete }

    /// Ctrl+K/Ctrl+U pairs: they empty the box from any cursor position without interrupting a busy agent.
    public var clearSequence: [UInt8] {
        Self.clearSequence(rows: rows)
    }

    public static func clearSequence(rows: Int) -> [UInt8] {
        Array(repeating: [0x0B, 0x15], count: 2 * max(1, rows) + 1).flatMap { $0 }
    }

    public static func read(screenLines: [String], columns: Int? = nil) -> UnsentPrompt? {
        let lines = screenLines.map(normalized)
        return readClaude(lines) ?? readCodex(lines, columns: columns)
    }

    /// Faint text is blanked: agents draw placeholders and suggestions faint.
    public static func plainLines(ansi: String, hidingFaint: Bool = true) -> [String] {
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        var faint = false
        var scalars = ansi.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            switch scalar {
            case "\u{1B}":
                guard let kind = scalars.next() else { break }
                if kind == "[" {
                    var parameters = ""
                    while let next = scalars.next() {
                        if (0x40...0x7E).contains(next.value) {
                            if next == "m" { faint = sgrFaint(parameters, current: faint) }
                            break
                        }
                        parameters.unicodeScalars.append(next)
                    }
                } else if kind == "]" {
                    var previous: Unicode.Scalar = " "
                    while let next = scalars.next() {
                        if next == "\u{07}" || (previous == "\u{1B}" && next == "\\") { break }
                        previous = next
                    }
                }
            case "\r":
                break
            case "\n":
                lines.append(String(line))
                line = String.UnicodeScalarView()
            default:
                line.append(faint && hidingFaint && !scalar.properties.isWhitespace ? " " : scalar)
            }
        }
        if !line.isEmpty { lines.append(String(line)) }
        return lines
    }

    private static func sgrFaint(_ parameters: String, current: Bool) -> Bool {
        let codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map {
            Int($0.split(separator: ":").first ?? "") ?? 0
        }
        var faint = current
        var index = 0
        while index < codes.count {
            switch codes[index] {
            case 0, 22: faint = false
            case 2: faint = true
            case 38, 48, 58:
                if index + 1 < codes.count {
                    index += codes[index + 1] == 5 ? 2 : codes[index + 1] == 2 ? 4 : 1
                }
            default: break
            }
            index += 1
        }
        return faint
    }

    private static func normalized(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            scalars.append(scalar == "\u{A0}" || scalar == "\u{0}" ? " " : scalar)
        }
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }

    private static func isRule(_ line: String) -> Bool {
        line.count >= 8 && line.allSatisfy { $0 == "─" }
    }

    private static func promptBody(_ line: String, marker: Character) -> String? {
        guard line.first == marker else { return nil }
        let rest = line.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }

    private static func readClaude(_ lines: [String]) -> UnsentPrompt? {
        for index in lines.indices.reversed() where index > 0 && isRule(lines[index - 1]) {
            guard let first = promptBody(lines[index], marker: "❯") else { continue }
            var rows = [lines[index]]
            var end = index + 1
            while end < lines.count, !isRule(lines[end]) {
                guard lines[end].isEmpty || lines[end].hasPrefix("  ") else { break }
                rows.append(lines[end])
                end += 1
            }
            guard end < lines.count, isRule(lines[end]) else { continue }
            let text = joined(rows, first: first, maxLine: lines[index - 1].count - 2)
            return prompt(.claude, text: text, rows: rows.count)
        }
        return nil
    }

    private static func readCodex(_ lines: [String], columns: Int?) -> UnsentPrompt? {
        guard let index = lines.lastIndex(where: { promptBody($0, marker: "›") != nil }),
            let first = promptBody(lines[index], marker: "›"),
            index == 0 || lines[index - 1].isEmpty,
            first.range(of: #"^\d+\.\s"#, options: .regularExpression) == nil,
            let last = lines.lastIndex(where: { !$0.isEmpty })
        else { return nil }
        var footer = last
        while footer > index, !lines[footer - 1].isEmpty { footer -= 1 }
        var end = last + 1
        if footer > index + 1 {
            guard last - footer < 3 else { return nil }
            end = footer - 1
        }
        while end > index + 1, lines[end - 1].isEmpty { end -= 1 }
        let rows = Array(lines[index..<end])
        guard rows.dropFirst().allSatisfy({ $0.isEmpty || $0.hasPrefix("  ") }) else { return nil }
        let width = columns ?? ((lines.map(\.count).max() ?? 0) + 1)
        return prompt(.codex, text: joined(rows, first: first, maxLine: width - 1), rows: rows.count)
    }

    private static func prompt(_ agent: Agent, text: String, rows: Int) -> UnsentPrompt {
        let incomplete = text.range(
            of: #"\[(Pasted text #\d+|Image #\d+|Pasted Content \d+ chars)"#, options: .regularExpression)
        return UnsentPrompt(
            agent: agent, text: isPlaceholder(text, agent: agent) ? "" : text, rows: rows,
            isComplete: incomplete == nil)
    }

    private static func isPlaceholder(_ text: String, agent: Agent) -> Bool {
        guard !text.contains("\n") else { return false }
        switch agent {
        case .claude:
            return text.range(of: #"^Try ".+"$"#, options: .regularExpression) != nil
                || text.hasPrefix("Press up to ") || text == "describe a task for a new session"
        case .codex:
            return ["Ask Codex to do anything", "Ask a follow-up question", "Waiting for startup"].contains {
                text.hasPrefix($0)
            }
        }
    }

    private static func joined(_ rows: [String], first: String, maxLine: Int) -> String {
        var text = first
        var previous = rows[0]
        for row in rows.dropFirst() {
            let body = String(row.dropFirst(2))
            text += separator(after: previous, before: body, maxLine: maxLine) + body
            previous = row
        }
        return text
    }

    private static func separator(after previous: String, before body: String, maxLine: Int) -> String {
        guard let head = body.first, head != " " else { return "\n" }
        let firstWord = body.prefix { $0 != " " }
        guard previous.count + 1 + firstWord.count > maxLine else { return "\n" }
        let lastWord = previous.reversed().prefix { $0 != " " }
        return previous.count >= maxLine && lastWord.count + firstWord.count > maxLine - 2 ? "" : " "
    }
}

/// What the composer starts with when it opens over an agent tab.
public struct ComposerPrefill: Equatable, Sendable {
    public var draft: String
    public var replacesBox: Bool

    public init(draft: String, replacesBox: Bool) {
        self.draft = draft
        self.replacesBox = replacesBox
    }

    public static func resolve(draft: String, replacesBox: Bool, box: UnsentPrompt?) -> ComposerPrefill {
        guard let box, box.isComplete, !box.text.isEmpty else {
            return ComposerPrefill(draft: draft, replacesBox: replacesBox && box?.isEmpty != true)
        }
        if draft.isEmpty || draft == box.text { return ComposerPrefill(draft: box.text, replacesBox: true) }
        return ComposerPrefill(draft: draft, replacesBox: replacesBox)
    }

    /// An untouched prefill is dropped on close: the text still sits in the agent's box.
    public static func closing(draft: String, replacesBox: Bool, prefilled: String?) -> ComposerPrefill {
        guard replacesBox, draft == prefilled else { return ComposerPrefill(draft: draft, replacesBox: replacesBox) }
        return ComposerPrefill(draft: "", replacesBox: false)
    }
}
