import Foundation

public enum TerminalURL {
    private static let trailing = CharacterSet(charactersIn: ".,;:!?)]}'\"")

    /// The URL under `column` of `row`, joining rows the terminal wrapped so a
    /// link split across the screen edge still resolves.
    public static func find(lines: [String], wrapped: [Bool], row: Int, column: Int) -> String? {
        guard lines.indices.contains(row) else { return nil }
        var start = row
        while start > 0, wrapped.indices.contains(start), wrapped[start] {
            start -= 1
        }
        var end = row
        while end + 1 < lines.count, wrapped.indices.contains(end + 1), wrapped[end + 1] {
            end += 1
        }
        var offset = column
        for index in start..<row {
            offset += lines[index].count
        }
        let joined = (start...end).map { lines[$0] }.joined()
        return url(in: joined, offset: offset)
    }

    static func url(in line: String, offset: Int) -> String? {
        let characters = Array(line)
        guard characters.indices.contains(offset) else { return nil }
        var from = offset
        while from > 0, !characters[from - 1].isWhitespace {
            from -= 1
        }
        var to = offset
        while to + 1 < characters.count, !characters[to + 1].isWhitespace {
            to += 1
        }
        var token = String(characters[from...to])
        while let last = token.unicodeScalars.last, trailing.contains(last) {
            token.removeLast()
        }
        guard token.hasPrefix("http://") || token.hasPrefix("https://"), token.count > 8,
            URL(string: token) != nil
        else { return nil }
        return token
    }
}
