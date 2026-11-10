import Foundation

public struct SpeechChunker: Sendable {
    private var pending = ""

    public init() {}

    public mutating func append(_ delta: String) -> [String] {
        pending += delta
        var sentences: [String] = []
        while let end = Self.sentenceEnd(in: pending) {
            let sentence = String(pending[..<end])
            pending = String(pending[end...])
            let spoken = Self.clean(sentence)
            if !spoken.isEmpty { sentences.append(spoken) }
        }
        return sentences
    }

    public mutating func flush() -> [String] {
        defer { pending = "" }
        let spoken = Self.clean(pending)
        return spoken.isEmpty ? [] : [spoken]
    }

    static func sentenceEnd(in text: String) -> String.Index? {
        var inCode = false
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("```") {
                inCode.toggle()
                index = text.index(index, offsetBy: 3)
                continue
            }
            let character = text[index]
            let next = text.index(after: index)
            if !inCode {
                if character == "\n" { return next }
                if ".!?".contains(character), next < text.endIndex, text[next].isWhitespace {
                    let word = text[..<index].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                    if !abbreviations.contains(word.lowercased()) { return next }
                }
            }
            index = next
        }
        return nil
    }

    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "mr", "mrs", "dr"]

    public static func clean(_ text: String) -> String {
        let trimmed = strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains(where: { $0.isLetter || $0.isNumber }) ? trimmed : ""
    }

    static func strip(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "```", with: " ")
        result = result.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "https?://\\S+", with: "a link", options: .regularExpression)
        result = result.replacingOccurrences(of: "`", with: "")
        result = result.replacingOccurrences(of: "(\\*\\*|__|\\*|~~)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "(?m)^\\s*(#{1,6}|[-+•]|\\d+[.)])\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "(?<!\\S)[-=_#~|>]{2,}(?!\\S)", with: " ", options: .regularExpression)
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

public struct SpeechCleaner: Sendable {
    public private(set) var held = ""
    private var lineStart = true
    private var spaced = true

    public init() {}

    public mutating func append(_ delta: String) -> String {
        held += delta
        guard let cut = Self.safeCut(in: held) else { return "" }
        let ready = String(held[..<cut])
        held = String(held[cut...])
        return emit(ready)
    }

    public mutating func flush() -> String {
        defer { held = "" }
        if let fence = Self.openFence(in: held) { held = String(held[..<fence]) }
        return emit(held)
    }

    private mutating func emit(_ raw: String) -> String {
        var text = SpeechChunker.strip((lineStart ? "" : "\u{1}") + raw)
        text.removeAll { $0 == "\u{1}" }
        if spaced, text.first == " " { text.removeFirst() }
        let tail = raw.reversed().prefix(while: \.isWhitespace)
        lineStart = tail.contains(where: \.isNewline) || (lineStart && tail.count == raw.count)
        if let last = text.last { spaced = last == " " }
        return text
    }

    static func openFence(in text: String) -> String.Index? {
        var open: String.Index?
        var index = text.startIndex
        while let range = text.range(of: "```", range: index..<text.endIndex) {
            open = open == nil ? range.lowerBound : nil
            index = range.upperBound
        }
        return open
    }

    static func safeCut(in text: String) -> String.Index? {
        enum Link { case none, label(Int), closed, target }
        var cut: String.Index?
        var inCode = false
        var link = Link.none
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("```") {
                inCode.toggle()
                index = text.index(index, offsetBy: 3)
                continue
            }
            let character = text[index]
            let next = text.index(after: index)
            if !inCode {
                if case .closed = link { link = character == "(" ? .target : .none }
                switch link {
                case .none:
                    if character == "[" {
                        link = .label(0)
                    } else if character.isWhitespace {
                        cut = next
                    }
                case .label(let length):
                    if character == "]" {
                        link = .closed
                    } else if character.isNewline {
                        link = .none
                        cut = next
                    } else if length > 120 {
                        link = .none
                    } else {
                        link = .label(length + 1)
                    }
                case .target:
                    if character == ")" || character.isWhitespace { link = .none }
                case .closed:
                    break
                }
            }
            index = next
        }
        return cut
    }
}
