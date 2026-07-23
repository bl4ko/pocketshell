public enum AgentQuickReply {
    public static func options(in text: String) -> [Int] {
        let found = text.split(separator: "\n").flatMap { line in
            line.matches(of: /(?:^|\s)([1-9])[\.\):]\s+\S/).compactMap { Int(String($0.1)) }
        }
        let unique = found.reduce(into: [Int]()) { result, option in
            if result.last != option { result.append(option) }
        }
        guard unique.count >= 2, unique.first == 1, unique == Array(1...unique.count) else { return [] }
        return unique
    }
}
