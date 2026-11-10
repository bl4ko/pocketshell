import Foundation

struct EchoGuard: Sendable {
    private var log: [(at: TimeInterval, text: String)] = []

    mutating func heard(_ text: String, at now: TimeInterval) {
        log.append((now, text))
        if log.count > 4000 { log.removeFirst(2000) }
    }

    func matches(_ text: String, since: TimeInterval) -> Bool {
        let words = Self.words(text)
        guard !words.isEmpty else { return false }
        var start = log.endIndex
        while start > log.startIndex, log[start - 1].at >= since { start -= 1 }
        while start > log.startIndex {
            start -= 1
            if log[start].text.contains(where: \.isWhitespace) { break }
        }
        let spoken = Self.words(log[start...].map(\.text).joined())
        guard spoken.count >= words.count else { return false }
        return (0...(spoken.count - words.count)).contains { spoken[$0..<($0 + words.count)].elementsEqual(words) }
    }

    private static func words(_ text: String) -> [Substring] {
        AgentResolver.normalize(text).split(separator: " ")
    }
}
