import Foundation

public enum EarsEvent: Equatable, Sendable {
    case partial(String)
    case phrase(String)
    case spoken(start: TimeInterval, end: TimeInterval)
    case level(Float)
    case failed(String)
}

public enum MouthEvent: Equatable, Sendable {
    case started
    case upcoming(String)
    case heard(String, reply: Int?)
    case idle
    case level(Float)
}

@MainActor
public protocol VoiceEars: AnyObject {
    var onEvent: ((EarsEvent) -> Void)? { get set }
    var muted: Bool { get set }
    func start() async throws
    func stop()
    func agentSaid(_ text: String, end: Bool)
}

extension VoiceEars {
    public func agentSaid(_ text: String, end: Bool) {}
}

@MainActor
public protocol VoiceMouth: AnyObject {
    var onEvent: ((MouthEvent) -> Void)? { get set }
    var isSpeaking: Bool { get }
    func speak(_ text: String)
    func stream(_ delta: String, reply: Int)
    func finish()
    func stop()
}

@MainActor
public final class TextEars: VoiceEars {
    public var onEvent: ((EarsEvent) -> Void)?
    public var muted = false
    public private(set) var running = false

    public init() {}

    public func start() async throws {
        running = true
    }

    public func stop() {
        running = false
    }

    public func submit(_ text: String) {
        guard running, !muted else { return }
        onEvent?(.partial(text))
        onEvent?(.phrase(text))
    }
}

@MainActor
public final class TimedMouth: VoiceMouth {
    public var onEvent: ((MouthEvent) -> Void)?
    public private(set) var spoken: [String] = []
    public private(set) var isSpeaking = false
    private var queue: [(text: String, reply: Int?)] = []
    private var task: Task<Void, Never>?
    private var chunker = SpeechChunker()
    private var streaming: Int?
    private let secondsPerCharacter: Double

    public init(secondsPerCharacter: Double = 0.03) {
        self.secondsPerCharacter = secondsPerCharacter
    }

    public func speak(_ text: String) {
        finish()
        enqueue(text, reply: nil)
    }

    public func stream(_ delta: String, reply: Int) {
        streaming = reply
        for sentence in chunker.append(delta) { enqueue(sentence, reply: reply) }
    }

    public func finish() {
        for sentence in chunker.flush() { enqueue(sentence, reply: streaming) }
        streaming = nil
    }

    public func stop() {
        task?.cancel()
        queue.removeAll()
        chunker = SpeechChunker()
        streaming = nil
        guard isSpeaking else { return }
        settle()
    }

    private func enqueue(_ text: String, reply: Int?) {
        spoken.append(text)
        queue.append((text, reply))
        guard task == nil else { return }
        isSpeaking = true
        onEvent?(.started)
        task = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                self.onEvent?(.upcoming(next.text + " "))
                self.onEvent?(.heard(next.text + " ", reply: next.reply))
                let seconds = min(1.5, Double(next.text.count) * self.secondsPerCharacter)
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
            }
            self?.settle()
        }
    }

    private func settle() {
        task = nil
        isSpeaking = false
        onEvent?(.idle)
    }
}
