import Foundation
import Testing
import VoiceKit

func fixture(_ name: String) throws -> String {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    let url = try #require(Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@MainActor
func eventually(_ timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
final class StagedMouth: VoiceMouth {
    var onEvent: ((MouthEvent) -> Void)?
    private(set) var isSpeaking = false
    private(set) var spoken: [String] = []
    private(set) var streamed = ""
    private(set) var reply: Int?
    private(set) var finishes = 0
    private(set) var stops = 0

    func speak(_ text: String) {
        spoken.append(text)
        begin()
    }

    func stream(_ delta: String, reply: Int) {
        streamed += delta
        self.reply = reply
        begin()
    }

    func finish() {
        finishes += 1
    }

    func stop() {
        stops += 1
        settle()
    }

    func hear(_ text: String, reply: Int? = nil) {
        onEvent?(.upcoming(text))
        onEvent?(.heard(text, reply: reply))
    }

    func settle() {
        guard isSpeaking else { return }
        isSpeaking = false
        onEvent?(.idle)
    }

    private func begin() {
        guard !isSpeaking else { return }
        isSpeaking = true
        onEvent?(.started)
    }
}

@MainActor
final class RecordingEars: VoiceEars {
    var onEvent: ((EarsEvent) -> Void)?
    var muted = false
    private(set) var said: [String] = []
    private(set) var ends = 0

    func start() async throws {}

    func stop() {}

    func agentSaid(_ text: String, end: Bool) {
        if !text.isEmpty { said.append(text) }
        if end { ends += 1 }
    }

    func partial(_ text: String) {
        onEvent?(.partial(text))
    }

    func phrase(_ text: String, start: TimeInterval? = nil, end: TimeInterval? = nil) {
        if let start, let end { onEvent?(.spoken(start: start, end: end)) }
        onEvent?(.phrase(text))
    }
}
