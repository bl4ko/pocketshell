import Foundation

struct TextInputDocument: Equatable {
    enum Output: Equatable {
        case text(String)
        case backspaces(Int)
    }

    private(set) var storage = ""
    private(set) var selected = 0..<0
    private(set) var markedRange: Range<Int>?
    static let limit = 512

    var length: Int { storage.utf16.count }

    var markedText: String? {
        markedRange.map { substring($0) }
    }

    func substring(_ range: Range<Int>) -> String {
        let utf16 = storage.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: min(max(0, range.lowerBound), utf16.count))
        let upper = utf16.index(utf16.startIndex, offsetBy: min(max(0, range.upperBound), utf16.count))
        return String(storage[lower..<upper])
    }

    private mutating func replaceStorage(_ range: Range<Int>, with text: String) {
        let utf16 = storage.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: min(max(0, range.lowerBound), utf16.count))
        let upper = utf16.index(utf16.startIndex, offsetBy: min(max(0, range.upperBound), utf16.count))
        storage.replaceSubrange(lower..<upper, with: text)
    }

    private func boundary(_ offset: Int, roundingUp: Bool) -> Int {
        var position = 0
        for character in storage {
            let next = position + character.utf16.count
            if next > offset { return roundingUp && position < offset ? next : position }
            position = next
        }
        return position
    }

    private func clamp(_ range: Range<Int>) -> Range<Int> {
        let lower = boundary(max(0, range.lowerBound), roundingUp: false)
        guard !range.isEmpty else { return lower..<lower }
        return lower..<max(lower, boundary(range.upperBound, roundingUp: true))
    }

    mutating func insert(_ text: String) -> [Output] {
        var output: [Output] = []
        if let marked = markedRange {
            replaceStorage(marked, with: text)
            let end = marked.lowerBound + text.utf16.count
            selected = end..<end
            markedRange = nil
            output.append(.text(text))
        } else {
            let range = clamp(selected)
            output.append(contentsOf: replace(range, with: text))
        }
        if text.contains("\n") || text.contains("\r") || length > Self.limit {
            reset()
        }
        return output
    }

    mutating func deleteBackward() -> [Output] {
        if let marked = markedRange {
            guard !marked.isEmpty else {
                markedRange = nil
                return []
            }
            let text = substring(marked)
            let trimmed = String(text.dropLast())
            replaceStorage(marked, with: trimmed)
            let end = marked.lowerBound + trimmed.utf16.count
            markedRange = trimmed.isEmpty ? nil : marked.lowerBound..<end
            selected = end..<end
            return []
        }
        let range = clamp(selected)
        if !range.isEmpty {
            return replace(range, with: "")
        }
        guard let last = substring(0..<range.lowerBound).last else { return [.backspaces(1)] }
        return replace((range.lowerBound - last.utf16.count)..<range.lowerBound, with: "")
    }

    mutating func replace(_ range: Range<Int>, with text: String) -> [Output] {
        let range = clamp(range)
        let tail = substring(range.lowerBound..<length)
        let suffix = substring(range.upperBound..<length)
        replaceStorage(range, with: text)
        let caret = range.lowerBound + text.utf16.count
        selected = caret..<caret
        var output: [Output] = []
        if !tail.isEmpty { output.append(.backspaces(tail.count)) }
        if !(text + suffix).isEmpty { output.append(.text(text + suffix)) }
        return output
    }

    mutating func setMarked(_ text: String, selectedRange: NSRange) {
        let target = markedRange ?? clamp(selected)
        replaceStorage(target, with: text)
        if text.isEmpty {
            markedRange = nil
            selected = target.lowerBound..<target.lowerBound
            return
        }
        let marked = target.lowerBound..<(target.lowerBound + text.utf16.count)
        markedRange = marked
        let start = min(marked.lowerBound + max(0, selectedRange.location), marked.upperBound)
        selected = start..<min(start + max(0, selectedRange.length), marked.upperBound)
    }

    mutating func unmark() -> [Output] {
        guard let marked = markedRange else { return [] }
        let text = substring(marked)
        markedRange = nil
        selected = marked.upperBound..<marked.upperBound
        return text.isEmpty ? [] : [.text(text)]
    }

    mutating func select(_ range: Range<Int>) {
        selected = clamp(range)
    }

    mutating func reset() {
        storage = ""
        selected = 0..<0
        markedRange = nil
    }
}
