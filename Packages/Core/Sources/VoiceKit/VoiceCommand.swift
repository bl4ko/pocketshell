import Foundation

public enum VoiceCommand: Equatable, Sendable {
    case text(String)
    case send(String)
    case clear
    case escape
    case enter
    case digit(Int)
    case jump(String)

    public static func parse(_ phrase: String) -> VoiceCommand? {
        let raw = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        let words = raw.map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        guard let last = words.last else { return nil }
        if words.count == 1 {
            if last == "escape" { return .escape }
            if last == "enter" { return .enter }
            if let digit = digits[last] { return .digit(digit) }
        }
        if words.count > 2, words[0] == "go", words[1] == "to" {
            return .jump(words.dropFirst(2).joined(separator: " "))
        }
        switch last {
        case "send":
            return .send(raw.dropLast().joined(separator: " ").trimmingCharacters(in: .punctuationCharacters))
        case "clear":
            return .clear
        default:
            return .text(raw.joined(separator: " "))
        }
    }

    public enum Action: Equatable, Sendable {
        case submit(String)
        case keys(String)
        case jump(String)
    }

    public static func apply(_ phrase: String, to draft: inout String) -> Action? {
        switch parse(phrase) {
        case .text(let text):
            draft = join(draft, text)
        case .send(let text):
            let message = join(draft, text)
            draft = ""
            return message.isEmpty ? nil : .submit(message)
        case .clear:
            draft = ""
        case .escape:
            return .keys("\u{1b}")
        case .enter:
            return .keys("\r")
        case .digit(let digit):
            return .keys("\(digit)")
        case .jump(let name):
            return .jump(name)
        case nil:
            break
        }
        return nil
    }

    public static func join(_ draft: String, _ text: String) -> String {
        [draft, text].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let digits: [String: Int] = [
        "1": 1, "one": 1, "won": 1, "2": 2, "two": 2, "to": 2, "too": 2, "3": 3, "three": 3,
        "4": 4, "four": 4, "for": 4, "5": 5, "five": 5, "6": 6, "six": 6, "7": 7, "seven": 7,
        "8": 8, "eight": 8, "9": 9, "nine": 9,
    ]
}
