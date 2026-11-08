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
    case playing(String)
    case idle
    case level(Float)
}

@MainActor
public protocol VoiceEars: AnyObject {
    var onEvent: ((EarsEvent) -> Void)? { get set }
    var muted: Bool { get set }
    func start() async throws
    func stop()
}

@MainActor
public protocol VoiceMouth: AnyObject {
    var onEvent: ((MouthEvent) -> Void)? { get set }
    var isSpeaking: Bool { get }
    func speak(_ text: String)
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
    private var queue: [String] = []
    private var task: Task<Void, Never>?
    private let secondsPerCharacter: Double

    public init(secondsPerCharacter: Double = 0.03) {
        self.secondsPerCharacter = secondsPerCharacter
    }

    public func speak(_ text: String) {
        spoken.append(text)
        queue.append(text)
        guard task == nil else { return }
        isSpeaking = true
        onEvent?(.started)
        task = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                self.onEvent?(.playing(next))
                let seconds = min(1.5, Double(next.count) * self.secondsPerCharacter)
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
            }
            self?.finish()
        }
    }

    public func stop() {
        task?.cancel()
        queue.removeAll()
        guard isSpeaking else { return }
        finish()
    }

    private func finish() {
        task = nil
        isSpeaking = false
        onEvent?(.idle)
    }
}
