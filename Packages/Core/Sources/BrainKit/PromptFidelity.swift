import Foundation

public enum PromptFidelity {
    public static func addedWords(_ text: String, turns: [String]) -> [String] {
        let spoken = turns.flatMap(words)
        var said = Set(spoken.map(stem))
        for (first, second) in zip(spoken, spoken.dropFirst()) { said.insert(stem(first + second)) }
        return content(text).filter { !said.contains(stem($0)) }
    }

    public static func isVerbatim(_ text: String, turns: [String]) -> Bool {
        let added = addedWords(text, turns: turns)
        if added.contains(where: meta.contains) { return false }
        return added.count <= max(1, content(text).count / 8)
    }

    public static let readBackPrefix = "I will send to "

    public static func readBack(_ text: String, agent: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = trimmed.last.map { ".?!".contains($0) } == false ? trimmed + "." : trimmed
        return "\(readBackPrefix)\(agent): \(ended) Send it?"
    }

    static func content(_ text: String) -> [String] {
        words(text).filter { !stopwords.contains($0) }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { word in
                var word = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                if word.hasSuffix("'s") { word.removeLast(2) }
                return numbers[word] ?? word
            }
            .filter { !$0.isEmpty }
    }

    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    private static let meta: Set<String> = ["correction", "user", "users", "assistant", "requirement", "requirements"]

    private static let numbers = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10",
    ]

    private static let stopwords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "and", "or", "but", "is", "are", "was", "were",
        "be", "been", "being", "it", "its", "this", "that", "these", "those", "i", "you", "we", "they", "he", "she",
        "me", "my", "your", "our", "their", "them", "us", "do", "does", "did", "can", "could", "should", "would",
        "will", "shall", "may", "might", "must", "not", "no", "so", "if", "then", "than", "as", "by", "from", "up",
        "out", "about", "into", "also", "just", "please", "now", "again", "there", "here", "what", "which", "who",
        "how", "when", "where", "why", "all", "any", "some", "too", "very", "let", "let's", "ok", "okay", "um", "uh",
        "hmm", "im", "i'm", "it's", "that's", "don't", "dont", "yes", "yeah", "has", "have", "had", "make", "sure",
    ]
}
