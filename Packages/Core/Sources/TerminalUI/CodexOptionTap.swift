enum CodexOptionTap {
    static func shortcut(lines: [String], tappedRow: Int) -> UInt8? {
        guard lines.indices.contains(tappedRow),
            let footerRow = lines.lastIndex(where: { $0.contains("enter to submit answer") }),
            tappedRow < footerRow,
            let questionRow = lines[..<footerRow].lastIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("Question ")
            }),
            tappedRow > questionRow
        else { return nil }

        for row in stride(from: tappedRow, through: questionRow + 1, by: -1) {
            if let shortcut = optionShortcut(in: lines[row]) {
                return shortcut
            }
        }
        return nil
    }

    private static func optionShortcut(in line: String) -> UInt8? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.first == "›" || text.first == ">" {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        guard text.count >= 2,
            let digit = text.utf8.first,
            (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(digit),
            text.dropFirst().first == "."
        else { return nil }
        return digit
    }
}
