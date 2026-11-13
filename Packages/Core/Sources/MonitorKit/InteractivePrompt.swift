import Foundation

public struct InteractivePrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var number: Int
        public var label: String
        public var detail: String
        public var highlighted: Bool
        public var freeText: Bool

        public init(number: Int, label: String, detail: String = "", highlighted: Bool = false, freeText: Bool = false)
        {
            self.number = number
            self.label = label
            self.detail = detail
            self.highlighted = highlighted
            self.freeText = freeText
        }
    }

    public var header: String?
    public var question: String
    public var context: [String]
    public var options: [Option]

    public init(header: String? = nil, question: String, context: [String] = [], options: [Option]) {
        self.header = header
        self.question = question
        self.context = context
        self.options = options
    }

    public var choices: [Option] { options.filter { !$0.freeText } }
    public var highlighted: Int? { options.first(where: \.highlighted)?.number }

    public static func read(_ screen: String) -> InteractivePrompt? {
        read(lines: screen.components(separatedBy: "\n"))
    }

    public static func read(lines raw: [String]) -> InteractivePrompt? {
        var lines = raw.map(clean)
        while lines.last?.isEmpty == true { lines.removeLast() }
        let tail = lines.indices.filter { !lines[$0].isEmpty }.suffix(3)
        guard let footer = tail.last(where: { isFooter(lines[$0]) }) else { return nil }
        var rows: [(index: Int, option: Option)] = []
        var row = footer - 1
        while row >= max(0, footer - 40) {
            if let option = optionRow(lines[row]) {
                rows.insert((row, option), at: 0)
                if option.number == 1 { break }
            }
            row -= 1
        }
        guard rows.count >= 2, rows.map(\.option.number) == Array(1...rows.count),
            rows.contains(where: \.option.highlighted)
        else { return nil }
        var options: [Option] = []
        for (offset, entry) in rows.enumerated() {
            let end = offset + 1 < rows.count ? rows[offset + 1].index : footer
            var option = entry.option
            let extra = lines[(entry.index + 1)..<end]
                .filter { !$0.isEmpty && !isRule($0) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            option.detail = ([option.detail] + extra).filter { !$0.isEmpty }.joined(separator: " ")
            options.append(option)
        }
        guard let (header, question, context) = questionBlock(lines, above: rows[0].index) else { return nil }
        return InteractivePrompt(header: header, question: question, context: context, options: options)
    }

    private static func questionBlock(_ lines: [String], above first: Int) -> (String?, String, [String])? {
        var block: [String] = []
        var header: String?
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
            if line.hasPrefix("←") { return true }
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
        return (header, question, context)
    }

    private static func optionRow(_ line: String) -> Option? {
        guard let match = line.firstMatch(of: /^\s*([❯›>])?\s*([1-9])\.\s+(\S.*)$/),
            let number = Int(match.2)
        else { return nil }
        let text = String(match.3)
        var label = text
        var detail = ""
        if let gap = text.firstRange(of: /\s{2,}/) {
            label = String(text[..<gap.lowerBound])
            detail = String(text[gap.upperBound...])
        }
        let free = freeTextLabels.contains(label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        return Option(number: number, label: label, detail: detail, highlighted: match.1 != nil, freeText: free)
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
