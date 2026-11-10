import Foundation

public struct Conversation: Codable, Equatable, Sendable {
    public static let resumeWindow: TimeInterval = 3600

    public var hostID: String
    public private(set) var messages: [ChatMessage] = []
    public private(set) var earlier: [String] = []
    public private(set) var updatedAt: Date
    public var maxMessages: Int
    public var maxCharacters: Int

    public init(hostID: String, now: Date, maxMessages: Int = 40, maxCharacters: Int = 24000) {
        self.hostID = hostID
        updatedAt = now
        self.maxMessages = maxMessages
        self.maxCharacters = maxCharacters
    }

    public func canResume(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) < Self.resumeWindow && now >= updatedAt.addingTimeInterval(-60)
    }

    public mutating func append(_ message: ChatMessage, at now: Date) {
        var message = message
        if message.role == .tool, let content = message.content, content.count > 6000 {
            message.content = String(content.prefix(6000)) + "…"
        }
        messages.append(message)
        updatedAt = now
        trim()
    }

    public mutating func touch(_ now: Date) {
        updatedAt = now
    }

    @discardableResult
    public mutating func removeLast() -> ChatMessage? {
        messages.popLast()
    }

    public mutating func setContent(_ content: String?, at index: Int) {
        guard messages.indices.contains(index) else { return }
        if content == nil, messages[index].toolCalls.isEmpty {
            messages.remove(at: index)
        } else {
            messages[index].content = content
        }
    }

    public var summary: String? {
        guard !earlier.isEmpty else { return nil }
        return "Earlier in this conversation the user said: " + earlier.joined(separator: "; ") + "."
    }

    public func request(system: String) -> [ChatMessage] {
        var prompt = system
        if let summary { prompt += "\n\n" + summary }
        return [.system(prompt)] + messages
    }

    private var characters: Int {
        messages.reduce(0) { $0 + ($1.content?.count ?? 0) + $1.toolCalls.reduce(0) { $0 + $1.arguments.count } }
    }

    private mutating func trim() {
        while messages.count > maxMessages || characters > maxCharacters {
            guard let next = messages.indices.dropFirst().first(where: { messages[$0].role == .user }) else { break }
            for message in messages[..<next] where message.role == .user {
                let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, !text.hasPrefix("[") { earlier.append(String(text.prefix(80))) }
            }
            earlier = Array(earlier.suffix(8))
            messages.removeSubrange(..<next)
        }
    }
}

public struct ConversationStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(hostID: String, now: Date) -> Conversation {
        guard let data = try? Data(contentsOf: file(hostID)),
            let conversation = try? JSONDecoder().decode(Conversation.self, from: data),
            conversation.canResume(at: now)
        else { return Conversation(hostID: hostID, now: now) }
        return conversation
    }

    public func save(_ conversation: Conversation) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(conversation) else { return }
        try? data.write(
            to: file(conversation.hostID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func file(_ hostID: String) -> URL {
        let safe = hostID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("brain-\(safe).json")
    }
}
