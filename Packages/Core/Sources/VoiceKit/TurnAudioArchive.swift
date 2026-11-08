#if !os(watchOS)
    import Foundation

    public struct AudioManifestEntry: Codable, Equatable, Sendable {
        public var turn: Int
        public var file: String
        public var recordedAt: Date
        public var speechStart: Double
        public var speechEnd: Double
        public var durationMs: Int
        public var sampleRate: Int
        public var ears: String
        public var mouth: String
        public var model: String
        public var text: String

        enum CodingKeys: String, CodingKey {
            case turn, file, ears, mouth, model, text
            case recordedAt = "recorded_at"
            case speechStart = "speech_start_uptime"
            case speechEnd = "speech_end_uptime"
            case durationMs = "duration_ms"
            case sampleRate = "sample_rate"
        }
    }

    public final class TurnAudioArchive: @unchecked Sendable {
        public static let sampleRate = 16000
        public let directory: URL
        private let lock = NSLock()
        private let capacity: Int
        private let padding: TimeInterval
        private var samples = Data()
        private var lastUptime: TimeInterval = 0

        public init(directory: URL, keepSeconds: TimeInterval = 120, padding: TimeInterval = 0.3) {
            self.directory = directory
            capacity = Int(keepSeconds * Double(Self.sampleRate)) * 2
            self.padding = padding
        }

        public var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

        public func append(_ pcm: Data, at uptime: TimeInterval) {
            lock.withLock {
                samples.append(pcm)
                if samples.count > capacity + capacity / 4 { samples.removeSubrange(0..<(samples.count - capacity)) }
                lastUptime = uptime
            }
        }

        public func clip(from start: TimeInterval, to end: TimeInterval) -> Data {
            lock.withLock {
                let rate = Double(Self.sampleRate)
                let total = samples.count / 2
                let first = total - Int(((lastUptime - (start - padding)) * rate).rounded())
                let last = total - Int(((lastUptime - (end + padding)) * rate).rounded())
                let lower = min(max(0, first), total)
                let upper = min(max(lower, last), total)
                return samples.subdata(in: (lower * 2)..<(upper * 2))
            }
        }

        @discardableResult
        public func save(
            turn: Int, text: String, speechStart: TimeInterval, speechEnd: TimeInterval, ears: String, mouth: String,
            model: String, date: Date = Date()
        ) throws -> AudioManifestEntry? {
            let pcm = clip(from: speechStart, to: speechEnd)
            guard !pcm.isEmpty else { return nil }
            let stamp = Self.stamp(date)
            let file = "turn-\(stamp)-\(turn).wav"
            let entry = AudioManifestEntry(
                turn: turn, file: file, recordedAt: date, speechStart: speechStart, speechEnd: speechEnd,
                durationMs: pcm.count / 2 * 1000 / Self.sampleRate, sampleRate: Self.sampleRate, ears: ears,
                mouth: mouth, model: model, text: text)
            try lock.withLock {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try PCM.wav(s16le: pcm, sampleRate: Self.sampleRate).write(
                    to: directory.appendingPathComponent(file), options: .atomic)
                var entries = Self.read(manifestURL)
                entries.append(entry)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(entries).write(to: manifestURL, options: .atomic)
            }
            return entry
        }

        public var entries: [AudioManifestEntry] { lock.withLock { Self.read(manifestURL) } }

        public func clear() {
            lock.withLock { try? FileManager.default.removeItem(at: directory) }
        }

        static func read(_ url: URL) -> [AudioManifestEntry] {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([AudioManifestEntry].self, from: data)) ?? []
        }

        static func stamp(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return formatter.string(from: date)
        }
    }
#endif
