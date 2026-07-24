import Foundation

public enum SelectionText {
    public static func join(rows: [String], startCol: Int, endCol: Int) -> String {
        rows.enumerated().map { index, row in
            let text = row.replacingOccurrences(of: "\u{0}", with: " ")
            let lower = index == 0 ? startCol : 0
            let upper = index == rows.count - 1 ? endCol + 1 : text.count
            guard lower < text.count else { return "" }
            return String(text.dropFirst(lower).prefix(max(0, min(upper, text.count) - lower)))
        }.joined(separator: "\n")
    }
}
