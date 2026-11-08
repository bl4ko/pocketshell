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
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains(where: { $0.isLetter || $0.isNumber }) ? trimmed : ""
    }
}
