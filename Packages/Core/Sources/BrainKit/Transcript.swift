import Foundation
import VoiceKit

public struct TranscriptLine: Equatable, Sendable, Identifiable {
    public enum Speaker: Equatable, Sendable {
        case user, assistant
    }

    public var id: Int
    public var speaker: Speaker
    public var text: String

    public init(id: Int, speaker: Speaker, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

public enum Transcript {
    public static func lines(_ messages: [ChatMessage], live: String? = nil) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        for message in messages {
            let speaker: TranscriptLine.Speaker
            var text = message.content ?? ""
            switch message.role {
            case .user:
                speaker = .user
                if let note = text.range(of: "[app:") { text = String(text[..<note.lowerBound]) }
            case .assistant:
                speaker = .assistant
                text = SpeechChunker.clean(text)
            case .system, .tool:
                continue
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(TranscriptLine(id: lines.count, speaker: speaker, text: text)) }
        }
        if let live, lines.last?.text == live.trimmingCharacters(in: .whitespacesAndNewlines) { lines.removeLast() }
        return lines
    }
}
