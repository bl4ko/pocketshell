import Foundation

public struct ConversationSessionInfo: Equatable, Sendable {
    public var build: String
    public var device: String
    public var system: String
    public var host: String
    public var hostID: String
    public var providers: BenchmarkProviders
    public var settings: [String: String]

    public init(
        build: String, device: String, system: String, host: String, hostID: String, providers: BenchmarkProviders,
        settings: [String: String] = [:]
    ) {
        self.build = build
        self.device = device
        self.system = system
        self.host = host
        self.hostID = hostID
        self.providers = providers
        self.settings = settings
    }
}

public enum ConversationEvent: Equatable, Sendable {
    public enum Spoken: String, Sendable {
        case filler, announcement, prompt, reply
    }

    public enum Confirmation: String, Sendable {
        case held, accepted, declined, dropped
    }

    case sessionStart(ConversationSessionInfo)
    case sessionEnd(reason: String)
    case userPhrase(text: String, speechStart: TimeInterval?, speechEnd: TimeInterval?)
    case echoDropped(text: String)
    case bargeIn(cause: String, partial: String?, stoppedMouth: Bool, cancelledBrain: Bool)
    case turn(id: Int, text: String)
    case dictation(text: String)
    case request(turn: Int, round: Int, messages: Int, notes: [String])
    case reply(turn: Int, reply: Int, generated: String, toolCalls: [String])
    case heard(reply: Int, text: String, cut: Bool)
    case toolCall(turn: Int, id: String, name: String, arguments: String, result: String, ms: Int)
    case confirmation(Confirmation, question: String, action: String, by: String? = nil, result: String? = nil)
    case sent(agent: String, text: String)
    case agentEvent(agent: String, kind: String, question: String?, options: [String])
    case promptAnswered(agent: String, option: Int, label: String, failure: String?)
    case spoken(Spoken, text: String)
    case mouth(speaking: Bool)
    case notice(String)
    case fallback(part: String, message: String)
    case earsFailed(String)
    case brainError(String)
    case interruption(began: Bool)
    case timing(TurnTiming)

    public var type: String { encoded(origin: 0).type }

    func encoded(origin: TimeInterval) -> (type: String, fields: [String: Any]) {
        func relative(_ time: TimeInterval?) -> Any? { time.map { ConversationLog.round(max(0, $0 - origin)) } }
        switch self {
        case .sessionStart(let info):
            return (
                "session_start",
                [
                    "build": info.build, "device": info.device, "system": info.system, "host": info.host,
                    "host_id": info.hostID, "ears": info.providers.ears, "mouth": info.providers.mouth,
                    "model": info.providers.model, "settings": info.settings,
                ]
            )
        case .sessionEnd(let reason): return ("session_end", ["reason": reason])
        case .userPhrase(let text, let start, let end):
            return (
                "user_phrase",
                ["text": text, "speech_start": relative(start) as Any, "speech_end": relative(end) as Any]
            )
        case .echoDropped(let text): return ("echo_dropped", ["text": text])
        case .bargeIn(let cause, let partial, let stopped, let cancelled):
            return (
                "barge_in",
                ["cause": cause, "partial": partial as Any, "stopped_mouth": stopped, "cancelled_brain": cancelled]
            )
        case .turn(let id, let text): return ("turn", ["turn": id, "text": text])
        case .dictation(let text): return ("dictation", ["text": text])
        case .request(let turn, let round, let messages, let notes):
            return ("request", ["turn": turn, "round": round, "messages": messages, "notes": notes])
        case .reply(let turn, let reply, let generated, let calls):
            return ("reply", ["turn": turn, "reply": reply, "generated": generated, "tool_calls": calls])
        case .heard(let reply, let text, let cut): return ("heard", ["reply": reply, "text": text, "cut": cut])
        case .toolCall(let turn, let id, let name, let arguments, let result, let ms):
            return (
                "tool_call",
                ["turn": turn, "id": id, "name": name, "arguments": arguments, "result": result, "ms": ms]
            )
        case .confirmation(let state, let question, let action, let by, let result):
            return (
                "confirmation",
                [
                    "state": state.rawValue, "question": question, "action": action, "by": by as Any,
                    "result": result as Any,
                ]
            )
        case .sent(let agent, let text): return ("sent", ["agent": agent, "text": text])
        case .agentEvent(let agent, let kind, let question, let options):
            return ("agent_event", ["agent": agent, "kind": kind, "question": question as Any, "options": options])
        case .promptAnswered(let agent, let option, let label, let failure):
            return ("prompt_answered", ["agent": agent, "option": option, "label": label, "failure": failure as Any])
        case .spoken(let kind, let text): return ("spoken", ["kind": kind.rawValue, "text": text])
        case .mouth(let speaking): return ("mouth", ["speaking": speaking])
        case .notice(let text): return ("notice", ["text": text])
        case .fallback(let part, let message): return ("fallback", ["part": part, "message": message])
        case .earsFailed(let message): return ("ears_failed", ["message": message])
        case .brainError(let message): return ("brain_error", ["message": message])
        case .interruption(let began): return ("interruption", ["began": began])
        case .timing(let timing):
            return (
                "timing",
                [
                    "turn": timing.turn, "text": timing.text, "stt_ms": timing.sttMs,
                    "first_token_ms": timing.firstTokenMs as Any, "first_audio_ms": timing.firstAudioMs as Any,
                    "total_ms": timing.totalMs, "ears": timing.providers.ears, "mouth": timing.providers.mouth,
                    "model": timing.providers.model,
                ]
            )
        }
    }
}

public enum LogScrubber {
    public static let limit = 4096
    static let redacted = "[redacted]"

    nonisolated(unsafe) private static let patterns: [(Regex<AnyRegexOutput>, String)] = [
        (try! Regex(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#), redacted),
        (
            try! Regex(#"(?i)\b(authorization|x-api-key|api-key)(\s*[:=]\s*)(bearer\s+|basic\s+)?[^\s"',;]+"#),
            "$1$2$3\(redacted)"
        ),
        (try! Regex(#"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]{8,}"#), "Bearer \(redacted)"),
        (
            try! Regex(
                #"(?i)\b([A-Za-z0-9_]*(?:api[_-]?key|token|secret|passw(?:or)?d))(["']?\s*[:=]\s*["']?)[^\s"',;&]+"#),
            "$1$2\(redacted)"
        ),
        (try! Regex(#"\b(sk|pk|rk)-[A-Za-z0-9_\-]{16,}"#), redacted),
        (try! Regex(#"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}"#), redacted),
        (try! Regex(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#), redacted),
        (try! Regex(#"\bAKIA[0-9A-Z]{16}\b"#), redacted),
        (try! Regex(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]+"#), redacted),
        (
            try! Regex(
                #"\b(?=[A-Za-z0-9_\-]*[a-z])(?=[A-Za-z0-9_\-]*[A-Z])(?=[A-Za-z0-9_\-]*[0-9])[A-Za-z0-9_\-]{32,}"#),
            redacted
        ),
    ]

    public static func scrub(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where secret.count >= 6 {
            result = result.replacingOccurrences(of: secret, with: redacted)
        }
        for (pattern, template) in patterns {
            result = replace(result, pattern, template)
        }
        return result
    }

    public static func clip(_ text: String, limit: Int = limit) -> String {
        guard text.utf8.count > limit else { return text }
        let half = limit / 2
        let head = prefix(text, bytes: half)
        let tail = suffix(text, bytes: half)
        let dropped = text.count - head.count - tail.count
        return head + "\n…[\(dropped) characters cut]…\n" + tail
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        var count = 0
        var end = text.startIndex
        for index in text.indices {
            count += text[index].utf8.count
            if count > bytes { break }
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    private static func suffix(_ text: String, bytes: Int) -> String {
        var count = 0
        var start = text.endIndex
        for index in text.indices.reversed() {
            count += text[index].utf8.count
            if count > bytes { break }
            start = index
        }
        return String(text[start...])
    }

    private static func replace(_ text: String, _ pattern: Regex<AnyRegexOutput>, _ template: String) -> String {
        text.replacing(pattern) { match in
            var output = template
            for index in (1..<match.output.count).reversed() {
                let group = match.output[index].substring.map(String.init) ?? ""
                output = output.replacingOccurrences(of: "$\(index)", with: group)
            }
            return output
        }
    }
}

public final class ConversationLog: @unchecked Sendable {
    public let sessionID: String
    public let day: String
    public let fileURL: URL
    public let store: ConversationLogStore
    private let queue = DispatchQueue(label: "pocketshell.conversation-log")
    private let origin: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date
    private let secrets: [String]
    private var sequence = 0
    private var handle: FileHandle?
    private var closed = false

    public init(
        store: ConversationLogStore, hostID: String, secrets: [String] = [], date: Date = Date(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.secrets = secrets.filter { !$0.isEmpty }
        self.clock = clock
        self.now = now
        origin = clock()
        let session = store.newSession(date: date)
        sessionID = session.id
        day = session.day
        fileURL = session.url
        queue.async { [store, fileURL] in
            store.prune(now: date)
            store.create(fileURL, host: hostID)
        }
    }

    public func record(_ event: ConversationEvent) {
        let time = clock()
        let date = now()
        queue.async { [self] in
            guard !closed, let line = line(event, time: time, date: date) else { return }
            write(line)
        }
    }

    public func close() {
        queue.async { [self] in
            closed = true
            try? handle?.close()
            handle = nil
        }
    }

    public func drain() {
        queue.sync {}
    }

    func line(_ event: ConversationEvent, time: TimeInterval, date: Date) -> Data? {
        sequence += 1
        let (type, fields) = event.encoded(origin: origin)
        var object = clean(fields) as? [String: Any] ?? [:]
        object["seq"] = sequence
        object["t"] = Self.round(time - origin)
        object["time"] = Self.wallClock.string(from: date)
        object["type"] = type
        object["session"] = sessionID
        guard JSONSerialization.isValidJSONObject(object),
            var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        data.append(0x0A)
        return data
    }

    private func clean(_ value: Any) -> Any? {
        let reflected = Mirror(reflecting: value)
        if reflected.displayStyle == .optional {
            guard let wrapped = reflected.children.first else { return nil }
            return clean(wrapped.value)
        }
        switch value {
        case let text as String: return scrubbed(text)
        case let list as [String]: return list.map(scrubbed)
        case let map as [String: String]: return map.mapValues(scrubbed)
        case let map as [String: Any]: return map.compactMapValues(clean)
        default: return value
        }
    }

    private func scrubbed(_ text: String) -> String {
        LogScrubber.clip(LogScrubber.scrub(text, secrets: secrets))
    }

    private func write(_ line: Data) {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) { store.create(fileURL, host: nil) }
            handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: line)
    }

    static func round(_ value: TimeInterval) -> Double {
        (value * 1000).rounded() / 1000
    }

    nonisolated(unsafe) static let wallClock: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public struct ConversationLogStore: Sendable {
    public struct Pending: Equatable, Sendable {
        public let url: URL
        public let day: String
        public let id: String
        public let sent: Int
        public let size: Int
    }

    struct Mirror: Codable {
        var host: String
        var sent: Int
    }

    public static let maxAge: TimeInterval = 30 * 24 * 3600
    public static let maxBytes = 50 * 1024 * 1024

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func newSession(date: Date) -> (id: String, day: String, url: URL) {
        let day = Self.format("yyyy-MM-dd", date)
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let id = Self.format("yyyyMMdd-HHmmss", date) + "-" + random
        return (id, day, directory.appendingPathComponent(day).appendingPathComponent(id + ".jsonl"))
    }

    func create(_ url: URL, host: String?) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        if let host { setMirror(Mirror(host: host, sent: 0), for: url) }
    }

    public var logs: [URL] {
        let manager = FileManager.default
        let days = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return days.flatMap { day in
            ((try? manager.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public var isEmpty: Bool { logs.isEmpty }

    public func prune(now: Date, maxAge: TimeInterval = maxAge, maxBytes: Int = maxBytes) {
        let manager = FileManager.default
        var kept: [(url: URL, size: Int)] = []
        for url in logs {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > maxAge {
                remove(url)
            } else {
                kept.append((url, values?.fileSize ?? 0))
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for entry in kept where total > maxBytes {
            remove(entry.url)
            total -= entry.size
        }
        let days = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for day in days where ((try? manager.contentsOfDirectory(atPath: day.path)) ?? ["?"]).isEmpty {
            try? manager.removeItem(at: day)
        }
    }

    public func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    public func pending(host: String) -> [Pending] {
        logs.compactMap { url in
            guard let mirror = mirror(for: url), mirror.host == host else { return nil }
            let length = size(url)
            guard mirror.sent < length else { return nil }
            return Pending(
                url: url, day: url.deletingLastPathComponent().lastPathComponent,
                id: url.deletingPathExtension().lastPathComponent, sent: mirror.sent, size: length)
        }
    }

    public func chunk(_ pending: Pending, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: pending.url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(pending.sent))) != nil,
            let data = try? handle.read(upToCount: min(limit, pending.size - pending.sent)), !data.isEmpty
        else { return nil }
        guard let newline = data.lastIndex(of: 0x0A) else { return data.count >= limit ? data : nil }
        return data[data.startIndex...newline]
    }

    public func markSent(_ url: URL, sent: Int) {
        guard var mirror = mirror(for: url) else { return }
        mirror.sent = max(0, min(sent, size(url)))
        setMirror(mirror, for: url)
    }

    func sent(_ url: URL) -> Int? { mirror(for: url)?.sent }

    public func host(of url: URL) -> String? { mirror(for: url)?.host }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    private func mirrorURL(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("mirror") }

    private func mirror(for url: URL) -> Mirror? {
        (try? Data(contentsOf: mirrorURL(url))).flatMap { try? JSONDecoder().decode(Mirror.self, from: $0) }
    }

    private func setMirror(_ mirror: Mirror, for url: URL) {
        try? JSONEncoder().encode(mirror).write(to: mirrorURL(url), options: .atomic)
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: mirrorURL(url))
    }

    private static func format(_ pattern: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
