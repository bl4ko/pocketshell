import Foundation

public struct InteractivePrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var number: Int
        public var label: String
        public var detail: String
        public var highlighted: Bool
        public var freeText: Bool
        public var checked: Bool?

        public init(
            number: Int, label: String, detail: String = "", highlighted: Bool = false, freeText: Bool = false,
            checked: Bool? = nil
        ) {
            self.number = number
            self.label = label
            self.detail = detail
            self.highlighted = highlighted
            self.freeText = freeText
            self.checked = checked
        }

        public var isChat: Bool { label.lowercased() == "chat about this" }
        public var isTypeSomething: Bool {
            ["type something", "none of the above"].contains(
                label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
    }

    public struct Tab: Equatable, Sendable {
        public var label: String
        public var answered: Bool

        public init(label: String, answered: Bool) {
            self.label = label
            self.answered = answered
        }
    }

    public struct Button: Equatable, Sendable {
        public var label: String
        public var highlighted: Bool

        public init(label: String, highlighted: Bool) {
            self.label = label
            self.highlighted = highlighted
        }
    }

    public var header: String?
    public var question: String
    public var context: [String]
    public var options: [Option]
    public var tabs: [Tab] = []
    public var button: Button?
    public var isReview = false
    public var reviewIncomplete = false
    public var moreAbove = false
    public var moreBelow = false
    public var numbered = true

    public init(header: String? = nil, question: String, context: [String] = [], options: [Option]) {
        self.header = header
        self.question = question
        self.context = context
        self.options = options
    }

    public var choices: [Option] { options.filter { !$0.freeText } }
    public var highlighted: Int? { options.first(where: \.highlighted)?.number }
    public var isMultiSelect: Bool { options.contains { $0.checked != nil } }
    public var isSubmitConfirmation: Bool { question.hasPrefix("Submit with unanswered questions?") }

    public var progress: (index: Int, total: Int)? {
        guard let match = header?.firstMatch(of: /^Question (\d+)\/(\d+)/), let index = Int(match.1),
            let total = Int(match.2)
        else { return nil }
        return (index, total)
    }

    public func sameQuestion(_ other: InteractivePrompt) -> Bool {
        question == other.question && isReview == other.isReview && progress?.index == other.progress?.index
            && tabs.map(\.label) == other.tabs.map(\.label)
    }

    public static func read(_ screen: String) -> InteractivePrompt? {
        read(lines: screen.components(separatedBy: "\n"))
    }

    public static func read(lines raw: [String]) -> InteractivePrompt? {
        var lines = raw.map(clean)
        while lines.last?.isEmpty == true { lines.removeLast() }
        let tail = lines.indices.filter { !lines[$0].isEmpty }.suffix(3)
        guard let footer = tail.last(where: { isFooter(lines[$0]) }) else { return review(lines) }
        guard let found = numberedRows(lines, footer: footer) ?? plainRows(lines, footer: footer) else { return nil }
        let rows = found.rows
        var options: [Option] = []
        var button: Button?
        for (offset, entry) in rows.enumerated() {
            let end = offset + 1 < rows.count ? rows[offset + 1].index : footer
            var option = entry.option
            var extra: [String] = []
            for line in lines[(entry.index + 1)..<end] where !line.isEmpty && !isRule(line) {
                if let found = Self.button(line) {
                    button = found
                } else {
                    extra.append(line.trimmingCharacters(in: .whitespaces))
                }
            }
            option.detail = ([option.detail] + extra).filter { !$0.isEmpty }.joined(separator: " ")
            options.append(option)
        }
        guard options.contains(where: \.highlighted) || button?.highlighted == true else { return nil }
        guard let block = questionBlock(lines, above: rows[0].index) else { return nil }
        var prompt = InteractivePrompt(
            header: block.header, question: block.question, context: block.context, options: options)
        prompt.tabs = block.tabs
        prompt.button = button
        prompt.moreAbove = found.moreAbove || (options.first?.number ?? 1) > 1
        prompt.moreBelow = found.moreBelow
        prompt.numbered = found.numbered
        return prompt
    }

    private typealias Rows = (rows: [(index: Int, option: Option)], moreAbove: Bool, moreBelow: Bool, numbered: Bool)

    private static func numberedRows(_ lines: [String], footer: Int) -> Rows? {
        var rows: [(index: Int, option: Option, marker: String?, column: Int)] = []
        var row = footer - 1
        var bounded = false
        while row >= max(0, footer - 40) {
            let line = lines[row]
            if case let (option, marker)? = optionRow(line) {
                if let top = rows.first, option.number >= top.option.number { break }
                let column = line.prefix { !$0.isNumber }.count
                rows.insert((row, option, marker, column), at: 0)
                if option.number == 1 || marker == "↑" { break }
            } else if let top = rows.first, !line.isEmpty, !isRule(line), button(line) == nil,
                line.prefix(while: { $0 == " " }).count < top.column
            {
                bounded = true
                break
            }
            row -= 1
        }
        let total = lines[footer].firstMatch(of: /option \d+\/(\d+)/).flatMap { Int($0.1) }
        guard rows.count >= 2, let first = rows.first else { return nil }
        if first.option.number > 1, first.marker != "↑", total == nil, !bounded { return nil }
        for (previous, next) in zip(rows, rows.dropFirst()) where next.option.number != previous.option.number + 1 {
            guard next.option.isChat else { return nil }
        }
        let listed = rows.filter { !$0.option.isChat }
        let last = listed.last?.option.number ?? 0
        let end = total ?? rows.first { $0.option.isChat }.map { $0.option.number - 1 } ?? last
        return (
            rows.map { (index: $0.index, option: $0.option) },
            rows.contains { $0.marker == "↑" } || first.option.number > 1,
            rows.contains { $0.marker == "↓" } || last < end, true
        )
    }

    private static func plainRows(_ lines: [String], footer: Int) -> Rows? {
        guard
            let marked = (max(0, footer - 12)..<footer).last(where: {
                lines[$0].contains(/^\s*[❯›]\s+\S/) && optionRow(lines[$0]) == nil
            }), let match = lines[marked].firstMatch(of: /^(\s*)[❯›](\s+)/)
        else { return nil }
        let column = match.1.count + 1 + match.2.count
        func isRow(_ index: Int) -> Bool {
            let line = lines[index]
            guard !line.isEmpty, !isRule(line), !isFooter(line) else { return false }
            if index == marked { return true }
            let indent = line.prefix { $0 == " " }.count
            return indent >= column && indent <= column + 2 && !line.contains(/^\s*[❯›]/)
        }
        var start = marked
        while start > 0, isRow(start - 1) { start -= 1 }
        var end = marked
        while end + 1 < footer, isRow(end + 1) { end += 1 }
        guard end > start else { return nil }
        let rows = (start...end).enumerated().map { offset, index -> (index: Int, option: Option) in
            var text = String(lines[index].dropFirst(index == marked ? column : 0)).trimmingCharacters(in: .whitespaces)
            var current = false
            if text.hasPrefix("✔") {
                current = true
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return (
                index,
                Option(number: offset + 1, label: text, detail: current ? "current" : "", highlighted: index == marked)
            )
        }
        return (rows, false, false, false)
    }

    private static func review(_ lines: [String]) -> InteractivePrompt? {
        guard let title = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Review your answers" }),
            let ask = lines[title...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "Ready to submit your answers?"
            })
        else { return nil }
        var options: [Option] = []
        for line in lines[(ask + 1)...] where !line.isEmpty {
            guard case let (option, _)? = optionRow(line), option.number == options.count + 1 else { return nil }
            options.append(option)
        }
        guard options.map(\.label) == ["Submit answers", "Cancel"], options.contains(where: \.highlighted) else {
            return nil
        }
        let body = lines[(title + 1)..<ask].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var prompt = InteractivePrompt(
            question: "Ready to submit your answers?",
            context: body.filter { !$0.hasPrefix("⚠") }.map {
                $0.hasPrefix("●") ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0
            }, options: options)
        prompt.isReview = true
        prompt.reviewIncomplete = body.contains { $0.contains("not answered all questions") }
        if let bar = lines[..<title].last(where: { !$0.isEmpty }) { prompt.tabs = tabs(bar) ?? [] }
        return prompt
    }

    private static func tabs(_ line: String) -> [Tab]? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("←") else { return nil }
        return text.matches(of: /([☐☒])\s+(.+?)(?=\s{2,}|\s*→|$)/).map {
            Tab(label: String($0.2).trimmingCharacters(in: .whitespaces), answered: $0.1 == "☒")
        }
    }

    private typealias Block = (header: String?, question: String, context: [String], tabs: [Tab])

    private static func questionBlock(_ lines: [String], above first: Int) -> Block? {
        var block: [String] = []
        var header: String?
        var tabs: [Tab] = []
        var bounded = false
        var row = first - 1
        while row >= 0, first - row <= 16 {
            let line = lines[row].trimmingCharacters(in: .whitespaces)
            if isRule(line) {
                bounded = true
                break
            }
            if line.contains(/^Question \d+\/\d+/) {
                header = line
                bounded = true
                break
            }
            block.insert(line, at: 0)
            row -= 1
        }
        var paragraphs: [[String]] = [[]]
        for line in block {
            if line.isEmpty {
                if !(paragraphs.last?.isEmpty ?? true) { paragraphs.append([]) }
            } else {
                paragraphs[paragraphs.count - 1].append(line)
            }
        }
        paragraphs.removeAll { $0.isEmpty }
        paragraphs.removeAll { paragraph in
            guard paragraph.count == 1, let line = paragraph.first else { return false }
            if let bar = Self.tabs(line) {
                tabs = bar
                if bar.count == 1 { header = bar[0].label }
                return true
            }
            guard let marker = line.first, checkboxes.contains(marker) else { return false }
            header = line.dropFirst().trimmingCharacters(in: .whitespaces)
            return true
        }
        let asking = paragraphs.lastIndex { $0.last?.hasSuffix("?") == true }
        if !bounded {
            if let asking {
                paragraphs.removeFirst(asking)
            } else {
                paragraphs = paragraphs.suffix(1)
            }
        }
        let index = bounded ? asking ?? paragraphs.count - 1 : 0
        guard paragraphs.indices.contains(index) else { return nil }
        let question = paragraphs[index].joined(separator: " ")
        var context = paragraphs.enumerated().filter { $0.offset != index }.flatMap(\.element)
        context = context.prefix(4).map { $0.count > 120 ? String($0.prefix(120)) + "…" : $0 }
        return (header, question, context, tabs)
    }

    private static func optionRow(_ line: String) -> (Option, String?)? {
        guard let match = line.firstMatch(of: /^\s*([❯›>↑↓])?\s*(\d{1,2})\.\s+(\S.*)$/),
            let number = Int(match.2), number > 0
        else { return nil }
        let marker = match.1.map(String.init)
        var text = String(match.3)
        var checked: Bool?
        if let box = text.firstMatch(of: /^\[([ ✔✓×xX])\]\s*/) {
            checked = box.1 != " "
            text = String(text[box.range.upperBound...])
        }
        var label = text
        var detail = ""
        if let gap = text.firstRange(of: /\s{2,}/) {
            label = String(text[..<gap.lowerBound])
            detail = String(text[gap.upperBound...])
        }
        let free = freeTextLabels.contains(label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        let highlighted = marker.map { "❯›>".contains($0) } ?? false
        return (
            Option(
                number: number, label: label, detail: detail, highlighted: highlighted, freeText: free, checked: checked
            ),
            marker
        )
    }

    private static func button(_ line: String) -> Button? {
        line.wholeMatch(of: /\s*([❯›>])?\s+(Submit|Next)\s*/).map {
            Button(label: String($0.2), highlighted: $0.1 != nil)
        }
    }

    private static func isFooter(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return footerMarkers.contains(where: lowered.contains)
    }

    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { "─━═╌┄-".contains($0) }
    }

    private static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "\u{0}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        while let last = text.last, last.isWhitespace || "│┃╮╯".contains(last) { text.removeLast() }
        let lead = text.prefix { $0 == " " }
        if let border = text.dropFirst(lead.count).first, "│┃╭╰".contains(border) {
            text = String(lead) + String(text.dropFirst(lead.count + 1))
        }
        return text.allSatisfy(\.isWhitespace) ? "" : text
    }

    private static let footerMarkers = [
        "enter to select", "enter to confirm", "enter to submit", "esc to cancel", "to navigate",
    ]
    private static let freeTextLabels: Set<String> = ["type something", "chat about this"]
    private static let checkboxes: Set<Character> = ["☐", "☒", "☑", "✔", "✓", "□", "■"]
}
