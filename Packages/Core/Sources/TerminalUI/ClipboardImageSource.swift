import Foundation

enum ClipboardImageSource: Equatable {
    case file(URL)
    case data(Data)

    static func parse(_ text: String) -> Self? {
        if let marker = text.firstMatch(of: /data:image\/[^;]+;base64,/),
            let data = Data(base64Encoded: token(in: text[marker.range.upperBound...]))
        {
            return .data(data)
        }
        if let match = text.firstMatch(of: /file:\/\/[^"'<>[:space:]]+/),
            let url = URL(string: String(match.output))
        {
            return .file(url)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) {
            return .file(URL(fileURLWithPath: trimmed))
        }
        return nil
    }

    private static func token(in text: Substring) -> String {
        String(text.prefix { !"\"'<> \r\n".contains($0) })
    }
}
