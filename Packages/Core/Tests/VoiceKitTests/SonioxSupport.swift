@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import VoiceKit

func fixtureLines(_ name: String, _ ext: String) throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
}

func fixtureData(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func json(_ message: SocketMessage) -> [String: Any] {
    guard case .text(let text) = message,
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    else { return [:] }
    return object
}

final class FakeSocket: SonioxSocket, @unchecked Sendable {
    let url: URL
    let key: String
    private let lock = NSLock()
    private var outgoing: [SocketMessage] = []
    private var isClosed = false
    private let inbox: AsyncStream<SocketMessage>
    private let feed: AsyncStream<SocketMessage>.Continuation
    private var iterator: AsyncStream<SocketMessage>.AsyncIterator

    init(url: URL, key: String) {
        self.url = url
        self.key = key
        (inbox, feed) = AsyncStream<SocketMessage>.makeStream()
        iterator = inbox.makeAsyncIterator()
    }

    var sent: [SocketMessage] { lock.withLock { outgoing } }
    var sentJSON: [[String: Any]] { sent.map(json) }
    var closed: Bool { lock.withLock { isClosed } }

    func send(_ message: SocketMessage) async throws {
        lock.withLock { outgoing.append(message) }
    }

    func receive() async throws -> SocketMessage {
        var copy = lock.withLock { iterator }
        guard let next = await copy.next() else { throw URLError(.networkConnectionLost) }
        lock.withLock { iterator = copy }
        return next
    }

    func push(_ text: String) {
        feed.yield(.text(text))
    }

    func drop() {
        feed.finish()
    }

    func close() {
        lock.withLock { isClosed = true }
        feed.finish()
    }
}

final class SocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeSocket] = []

    var sockets: [FakeSocket] { lock.withLock { made } }
    var last: FakeSocket? { sockets.last }

    var connect: SonioxConnect {
        { url, key in
            let socket = FakeSocket(url: url, key: key)
            self.lock.withLock { self.made.append(socket) }
            return socket
        }
    }
}

final class FakeLine: AudioLine, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var completions: [@Sendable () -> Void] = []
    private var stops = 0

    var scheduled: [AVAudioPCMBuffer] { lock.withLock { buffers } }
    var stopCount: Int { lock.withLock { stops } }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            buffers.append(buffer)
            completions.append(completion)
        }
        return true
    }

    func playAll() {
        let pending = lock.withLock { () -> [@Sendable () -> Void] in
            defer { completions = [] }
            return completions
        }
        for completion in pending { completion() }
    }

    func stop() {
        lock.withLock {
            stops += 1
            completions = []
        }
    }
}

@MainActor
final class FakeMicrophone: MicrophoneSource {
    var onInputLevel: ((Float) -> Void)?
    private(set) var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func setSink(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        self.sink = sink
    }
}

func sine(seconds: Double, rate: Double = 48000) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
        buffer.floatChannelData![0][index] = 0.5 * sin(Float(index) * 2 * .pi * 440 / Float(rate))
    }
    return buffer
}

func pcm(samples: Int, value: Int16 = 1000) -> Data {
    var data = Data()
    for _ in 0..<samples { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    return data
}

func audioReply(_ stream: String, _ data: Data, end: Bool = false) -> String {
    #"{"stream_id":"\#(stream)","audio":"\#(data.base64EncodedString())","audio_end":\#(end)}"#
}

@MainActor
func eventually(_ timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
