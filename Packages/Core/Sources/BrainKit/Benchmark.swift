import Foundation

public struct BenchmarkProviders: Codable, Equatable, Sendable {
    public var ears: String
    public var mouth: String
    public var model: String

    public init(ears: String, mouth: String, model: String) {
        self.ears = ears
        self.mouth = mouth
        self.model = model
    }
}

public struct UserTurn: Equatable, Sendable {
    public var turn: Int
    public var text: String
    public var speechStart: TimeInterval?
    public var speechEnd: TimeInterval
    public var providers: BenchmarkProviders
}

public struct TurnTiming: Codable, Equatable, Sendable {
    public var turn: Int
    public var date: Date
    public var providers: BenchmarkProviders
    public var text: String
    public var sttMs: Int
    public var firstTokenMs: Int?
    public var firstAudioMs: Int?
    public var totalMs: Int

    public init(
        turn: Int, date: Date, providers: BenchmarkProviders, text: String, sttMs: Int, firstTokenMs: Int?,
        firstAudioMs: Int?, totalMs: Int
    ) {
        self.turn = turn
        self.date = date
        self.providers = providers
        self.text = text
        self.sttMs = sttMs
        self.firstTokenMs = firstTokenMs
        self.firstAudioMs = firstAudioMs
        self.totalMs = totalMs
    }

    public var summary: String {
        [
            "STT \(Self.format(sttMs))", "first token \(Self.format(firstTokenMs))",
            "first audio \(Self.format(firstAudioMs))", "total \(Self.format(totalMs))",
        ].joined(separator: " · ")
    }

    static func format(_ ms: Int?) -> String {
        guard let ms else { return "–" }
        return ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }
}

struct TurnClock {
    var turn: Int
    var text: String
    var speechEnd: TimeInterval
    var phrase: TimeInterval
    var firstToken: TimeInterval?
    var firstAudio: TimeInterval?
    var brainDone = false

    func timing(done: TimeInterval, date: Date, providers: BenchmarkProviders) -> TurnTiming {
        func ms(_ time: TimeInterval?) -> Int? { time.map { Int((($0 - speechEnd) * 1000).rounded()) } }
        return TurnTiming(
            turn: turn, date: date, providers: providers, text: text, sttMs: max(0, ms(phrase) ?? 0),
            firstTokenMs: ms(firstToken), firstAudioMs: ms(firstAudio), totalMs: ms(done) ?? 0)
    }
}

public enum BenchmarkCSV {
    public static let header = "turn,date,ears,mouth,model,stt_ms,first_token_ms,first_audio_ms,total_ms,text"

    public static func row(_ timing: TurnTiming) -> String {
        let date = ISO8601DateFormatter().string(from: timing.date)
        return [
            String(timing.turn), date, timing.providers.ears, timing.providers.mouth, timing.providers.model,
            String(timing.sttMs), timing.firstTokenMs.map(String.init) ?? "",
            timing.firstAudioMs.map(String.init) ?? "",
            String(timing.totalMs), timing.text,
        ].map(field).joined(separator: ",")
    }

    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public final class BenchmarkLog: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    public var csvURL: URL { directory.appendingPathComponent("turns.csv") }
    public var lastURL: URL { directory.appendingPathComponent("last-turn.json") }

    public func append(_ timing: TurnTiming) {
        lock.withLock {
            let manager = FileManager.default
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let line = Data((BenchmarkCSV.row(timing) + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: csvURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                try? (Data((BenchmarkCSV.header + "\n").utf8) + line).write(to: csvURL, options: .atomic)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(timing).write(to: lastURL, options: .atomic)
        }
    }

    public var last: TurnTiming? {
        lock.withLock {
            guard let data = try? Data(contentsOf: lastURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(TurnTiming.self, from: data)
        }
    }

    public var hasTimings: Bool { FileManager.default.fileExists(atPath: csvURL.path) }

    public func clear() {
        lock.withLock {
            try? FileManager.default.removeItem(at: csvURL)
            try? FileManager.default.removeItem(at: lastURL)
        }
    }
}
