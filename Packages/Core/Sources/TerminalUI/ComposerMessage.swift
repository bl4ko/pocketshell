import Foundation

/// Turns a composed prompt into the bytes a live session should receive.
///
/// A composer writes into the same shell the terminal shows, so a multi-line prompt has to
/// arrive as one block: without bracketed paste every newline submits a line, which makes an
/// agent answer the first sentence and treat the rest as new prompts.
public enum ComposerMessage {
    public static func payload(_ text: String, bracketedPaste: Bool, submit: Bool = true) -> String {
        let normalized =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return "" }
        let body = bracketedPaste ? "\u{1b}[200~\(normalized)\u{1b}[201~" : normalized
        return submit ? body + "\r" : body
    }
}
