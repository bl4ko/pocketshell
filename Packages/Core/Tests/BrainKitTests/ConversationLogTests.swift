import Foundation
import Testing

@testable import BrainKit

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("psh-log-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func lines(_ url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) { self.value = value }

    var now: TimeInterval { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private let info = ConversationSessionInfo(
    build: "1.0 (42)", device: "iPhone17,1", system: "26.1", host: "devbox", hostID: "host-1",
    providers: BenchmarkProviders(ears: "soniox:stt", mouth: "iphone", model: "small"),
    settings: ["turn_end": "balanced"])

@Test func eventsEncodeAsOneJSONObjectPerLineWithMonotonicAndWallClockTime() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let ticker = Ticker(100)
    let wall = Date(timeIntervalSince1970: 1_800_000_000)
    let log = ConversationLog(
        store: ConversationLogStore(directory: root), hostID: "host-1", date: wall, clock: { ticker.now },
        now: { wall })
    log.record(.sessionStart(info))
    ticker.advance(1.5)
    log.record(.userPhrase(text: "what are my agents doing", speechStart: 100.4, speechEnd: 101.2))
    log.record(
        .toolCall(turn: 2, id: "c1", name: "list_agents", arguments: "{}", result: #"{"ok":true}"#, ms: 120))
    log.record(.confirmation(.held, question: "Send it?", action: "sendPrompt", result: nil))
    log.record(.sessionEnd(reason: "end button"))
    log.close()
    log.drain()

    #expect(log.fileURL.deletingLastPathComponent().lastPathComponent.count == 10)
    #expect(log.fileURL.lastPathComponent == log.sessionID + ".jsonl")
    let events = try lines(log.fileURL)
    #expect(
        events.map { $0["type"] as? String } == [
            "session_start", "user_phrase", "tool_call", "confirmation", "session_end",
        ])
    #expect(events.map { $0["seq"] as? Int } == [1, 2, 3, 4, 5])
    #expect(events.allSatisfy { $0["session"] as? String == log.sessionID })
    #expect(events[0]["t"] as? Double == 0)
    #expect(events[0]["host"] as? String == "devbox")
    #expect(events[0]["ears"] as? String == "soniox:stt")
    #expect((events[0]["settings"] as? [String: String])?["turn_end"] == "balanced")
    #expect(events[1]["t"] as? Double == 1.5)
    #expect(events[1]["speech_start"] as? Double == 0.4)
    #expect(events[1]["speech_end"] as? Double == 1.2)
    #expect(events[1]["time"] as? String == "2027-01-15T08:00:00.000Z")
    #expect(events[2]["result"] as? String == #"{"ok":true}"#)
    #expect(events[2]["ms"] as? Int == 120)
    #expect(events[3]["state"] as? String == "held")
    #expect(events[3]["result"] == nil)
}

@Test func secretsNeverReachTheLog() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let log = ConversationLog(
        store: ConversationLogStore(directory: root), hostID: "host-1", secrets: ["brain-key-123456"])
    log.record(.notice("Endpoint said brain-key-123456 is wrong"))
    log.record(
        .toolCall(
            turn: 1, id: "c1", name: "read_screen", arguments: "{}",
            result: """
                Authorization: Bearer abcdef0123456789abcdef
                export OPENAI_API_KEY=sk-proj-AbCdEf0123456789XyZ
                ANTHROPIC_API_KEY="sk-ant-api03-Zz9Yy8Xx7Ww6Vv5Uu4Tt3"
                password: hunter2hunter2
                token ghp_abcdefghijklmnopqrstuvwxyz0123456789
                -----BEGIN OPENSSH PRIVATE KEY-----
                b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ
                -----END OPENSSH PRIVATE KEY-----
                commit 3f2a9c1e4b5d6f7a8b9c0d1e2f3a4b5c6d7e8f9a builds fine
                """, ms: 1))
    log.close()
    log.drain()
    let text = try String(contentsOf: log.fileURL, encoding: .utf8)
    for secret in [
        "brain-key-123456", "abcdef0123456789abcdef", "sk-proj-AbCdEf0123456789XyZ", "sk-ant-api03", "hunter2",
        "ghp_abcdefghijklmnop", "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ",
    ] {
        #expect(!text.contains(secret), "\(secret) leaked")
    }
    #expect(text.contains("[redacted]"))
    #expect(text.contains("3f2a9c1e4b5d6f7a8b9c0d1e2f3a4b5c6d7e8f9a"), "a commit hash is not a secret")
    #expect(text.contains("Endpoint said"))
}

@Test func hugeScreenDumpsKeepTheirHeadAndTail() {
    let dump = "HEAD" + String(repeating: "x", count: 20_000) + "TAIL"
    let clipped = LogScrubber.clip(dump)
    #expect(clipped.utf8.count < LogScrubber.limit + 64)
    #expect(clipped.hasPrefix("HEAD"))
    #expect(clipped.hasSuffix("TAIL"))
    #expect(clipped.contains("characters cut"))
    #expect(LogScrubber.clip("short") == "short")
    let wide = String(repeating: "é🙂", count: 3000)
    #expect(LogScrubber.clip(wide).utf8.count < LogScrubber.limit + 64)
}

@Test func pruningDropsLogsOlderThanThirtyDaysThenTheOldestBeyondTheSizeLimit() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationLogStore(directory: root)
    let now = Date()
    func make(_ daysAgo: Double, bytes: Int) throws -> URL {
        let date = now.addingTimeInterval(-daysAgo * 86400)
        let url = store.newSession(date: date).url
        store.create(url, host: "host-1")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }
    let ancient = try make(40, bytes: 10)
    let older = try make(3, bytes: 600)
    let newer = try make(1, bytes: 600)
    store.prune(now: now, maxBytes: 1000)
    #expect(!FileManager.default.fileExists(atPath: ancient.path))
    #expect(!FileManager.default.fileExists(atPath: ancient.deletingLastPathComponent().path))
    #expect(!FileManager.default.fileExists(atPath: older.path))
    #expect(
        !FileManager.default.fileExists(atPath: older.deletingPathExtension().appendingPathExtension("mirror").path))
    #expect(store.logs.map(\.lastPathComponent) == [newer.lastPathComponent])
    store.deleteAll()
    #expect(store.isEmpty)
}

#if os(macOS)
    @MainActor
    private final class RemoteHost {
        let root: URL
        var down = false
        private(set) var execs = 0

        init(root: URL) { self.root = root }

        func exec(_ command: String) async -> String? {
            execs += 1
            guard !down else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let reader = pipe.fileHandleForReading
            let output = await Task.detached { reader.readDataToEndOfFile() }.value
            while process.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
            return String(decoding: output, as: UTF8.self)
        }

        func file(_ log: ConversationLog) -> URL {
            root.appendingPathComponent(".local/share/pocketshell/voice-logs/\(log.day)/\(log.sessionID).jsonl")
        }
    }

    @MainActor
    @Test func theMirrorBatchesTheLogToTheHostAndRetriesTheBacklogAfterTheLinkComesBack() async throws {
        let local = try scratch()
        let home = try scratch()
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: home)
        }
        let store = ConversationLogStore(directory: local)
        let host = RemoteHost(root: home)
        let mirror = ConversationLogMirror(store: store, hostID: "host-1", exec: { await host.exec($0) })
        mirror.chunkLimit = 400

        let log = ConversationLog(store: store, hostID: "host-1")
        for index in 0..<12 {
            log.record(.userPhrase(text: "phrase number \(index)", speechStart: nil, speechEnd: nil))
        }
        log.drain()

        host.down = true
        #expect(await mirror.sync() == false)
        #expect(!FileManager.default.fileExists(atPath: host.file(log).path))
        #expect(store.pending(host: "host-1").first?.sent == 0)

        host.down = false
        mirror.maxExecs = 50
        let before = host.execs
        #expect(await mirror.sync())
        #expect(host.execs - before > 1, "a long log goes in several bounded batches")
        #expect(try Data(contentsOf: host.file(log)) == Data(contentsOf: log.fileURL))
        #expect(store.pending(host: "host-1").isEmpty)

        log.record(.sessionEnd(reason: "end button"))
        log.close()
        log.drain()
        #expect(await mirror.sync())
        #expect(try Data(contentsOf: host.file(log)) == Data(contentsOf: log.fileURL))

        let other = ConversationLogMirror(store: store, hostID: "host-2", exec: { await host.exec($0) })
        let execs = host.execs
        #expect(await other.sync())
        #expect(host.execs == execs, "another host never receives this host's logs")
    }

    @MainActor
    @Test func theMirrorHealsARemoteFileThatWasDeletedOrAlreadyAhead() async throws {
        let local = try scratch()
        let home = try scratch()
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: home)
        }
        let store = ConversationLogStore(directory: local)
        let host = RemoteHost(root: home)
        let mirror = ConversationLogMirror(store: store, hostID: "host-1", exec: { await host.exec($0) })
        let log = ConversationLog(store: store, hostID: "host-1")
        log.record(.notice("one"))
        log.drain()
        #expect(await mirror.sync())

        try FileManager.default.removeItem(at: host.file(log))
        log.record(.notice("two"))
        log.drain()
        #expect(await mirror.sync())
        #expect(try Data(contentsOf: host.file(log)) == Data(contentsOf: log.fileURL))

        let size = try Data(contentsOf: log.fileURL).count
        log.record(.notice("three"))
        log.drain()
        store.markSent(log.fileURL, sent: size)
        try FileManager.default.copyItem(at: log.fileURL, to: home.appendingPathComponent("full"))
        try FileManager.default.removeItem(at: host.file(log))
        try FileManager.default.moveItem(at: home.appendingPathComponent("full"), to: host.file(log))
        #expect(await mirror.sync())
        #expect(try Data(contentsOf: host.file(log)) == Data(contentsOf: log.fileURL), "no duplicate lines")
    }

    @MainActor
    @Test func theTestRootWritesNothingWithoutItsDirectory() async throws {
        let local = try scratch()
        let home = try scratch()
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: home)
        }
        let store = ConversationLogStore(directory: local)
        let host = RemoteHost(root: home)
        let mirror = ConversationLogMirror(
            store: store, hostID: "host-1", root: ConversationLogMirror.testRoot, exec: { await host.exec($0) })
        let log = ConversationLog(store: store, hostID: "host-1")
        log.record(.notice("ui test"))
        log.drain()
        #expect(await mirror.sync() == false)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: home.path)) == [])
    }
#endif

@Test func mirrorCommandsRejectUnsafeNamesAndParseTheRemoteSize() {
    #expect(
        ConversationLogMirror.command(root: "/x", day: "2026-11-15", id: "a;rm -rf", offset: 0, data: Data()) == nil)
    let command = ConversationLogMirror.command(
        root: ConversationLogMirror.homeRoot, day: "2026-11-15", id: "20261115-101500-ab12cd34", offset: 10,
        data: Data("{}\n".utf8))
    #expect(command?.hasPrefix("sh -c ") == true)
    #expect(command?.contains("e30K") == true)
    #expect(ConversationLogMirror.size(from: "motd\npsh-voice-log 42\n") == 42)
    #expect(ConversationLogMirror.size(from: "nothing") == nil)
    #expect(ConversationLogMirror.size(from: nil) == nil)
}

@Test func recallListsRecentExchangesNewestLastAndFlagsLongReads() {
    let long = "start " + String(repeating: "word ", count: 2000) + "finish"
    let exchanges = (1...12).map { index in
        RecallExchange(
            session: "s", turn: index, time: "t\(index)", user: "question \(index)",
            generated: index == 12 ? long : "Answer \(index).")
    }
    func decode(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }
    let listed = decode(
        ConversationRecall.answer(["action": "list", "count": 3], exchanges: exchanges, excluding: ("s", 12)))
    let entries = listed["exchanges"] as? [[String: Any]] ?? []
    #expect(listed["total"] as? Int == 11)
    #expect(entries.map { $0["back"] as? Int } == [3, 2, 1])
    #expect(entries.last?["reply"] as? String == "Answer 11.")
    let read = decode(ConversationRecall.answer(["action": "read", "index": 12], exchanges: exchanges, excluding: nil))
    #expect(read["truncated"] as? Bool == true)
    #expect((read["reply"] as? String)?.hasPrefix("start") == true)
    #expect((read["reply"] as? String)?.hasSuffix("finish") == true)
    #expect(
        decode(ConversationRecall.answer(["action": "read", "back": 40], exchanges: exchanges, excluding: nil))["error"]
            != nil)
}
