import Foundation
import Testing

@testable import VoiceKit

final class StubHTTP: @unchecked Sendable {
    typealias Reply = @Sendable (URLRequest) throws -> (Int, Data)
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let reply: Reply

    init(_ reply: @escaping Reply) {
        self.reply = reply
    }

    var requests: [URLRequest] { lock.withLock { seen } }

    var send: SonioxHTTP {
        { request in
            self.lock.withLock { self.seen.append(request) }
            let (status, data) = try self.reply(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("psh-voices-\(UUID().uuidString)")
}

private func library(_ directory: URL, key: String? = "k", _ http: StubHTTP) -> SonioxVoiceLibrary {
    SonioxVoiceLibrary(directory: directory, apiKey: { key }, http: http.send)
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

private func sharedVoices() throws -> [SonioxVoice] {
    try SonioxVoiceCatalog.page(try fixtureData("soniox-shared-voices", "json")).voices
}

@Test func sharedVoicesDecodeTheirMetadata() throws {
    let page = try SonioxVoiceCatalog.page(try fixtureData("soniox-shared-voices", "json"))
    #expect(page.cursor == nil)
    #expect(page.voices.map(\.id) == ["Daniel", "Nina", "Emma", "Grace", "Owen", "Kenji", "Lucia", "Arthur", "Hazel"])
    let daniel = try #require(page.voices.first)
    #expect(daniel.gender == "male")
    #expect(daniel.age == "middle_aged")
    #expect(daniel.accent == "british")
    #expect(daniel.useCases == ["narration", "entertainment", "educational"])
    #expect(daniel.styles == ["calm", "deep", "smooth", "friendly"])
    #expect(daniel.description.hasPrefix("Low British baritone"))
    #expect(daniel.tags == ["Male", "British", "Calm", "Deep"])
    let bare = try SonioxVoiceCatalog.page(Data(#"{"voices":[{"id":"Solo"}]}"#.utf8))
    #expect(bare.voices == [SonioxVoice(id: "Solo")])
    #expect(bare.voices[0].tags.isEmpty)
    #expect(SonioxVoiceCatalog.label("southeast_asian") == "Southeast Asian")
}

@Test func voicesOrderDefaultThenCuratedThenEnglishConversational() throws {
    let ordered = SonioxVoiceCatalog.ordered(try sharedVoices()).map(\.id)
    #expect(ordered == ["Hazel", "Grace", "Daniel", "Emma", "Nina", "Owen", "Arthur", "Kenji", "Lucia"])
}

@Test func voiceFilterDefaultsToEnglishAndNarrowsByGenderAccentAndSearch() throws {
    let voices = SonioxVoiceCatalog.ordered(try sharedVoices())
    func ids(_ filter: SonioxVoiceFilter) -> [String] { SonioxVoiceCatalog.filter(voices, filter).map(\.id) }
    #expect(ids(SonioxVoiceFilter()) == ["Hazel", "Grace", "Daniel", "Emma", "Nina", "Owen", "Arthur"])
    #expect(ids(SonioxVoiceFilter(accent: .any)).count == 9)
    #expect(ids(SonioxVoiceFilter(gender: "male")) == ["Daniel", "Owen", "Arthur"])
    #expect(ids(SonioxVoiceFilter(accent: .only("british"))) == ["Daniel", "Emma", "Nina", "Arthur"])
    #expect(ids(SonioxVoiceFilter(gender: "female", accent: .only("japanese"))).isEmpty)
    #expect(ids(SonioxVoiceFilter(accent: .any, search: "kenji")) == ["Kenji"])
    #expect(ids(SonioxVoiceFilter(search: "BARITONE")) == ["Daniel"])
    #expect(ids(SonioxVoiceFilter(search: "british deep")) == ["Daniel", "Arthur"])
    #expect(ids(SonioxVoiceFilter(search: "  ")).count == 7)
    #expect(ids(SonioxVoiceFilter(search: "zzz")).isEmpty)
    #expect(SonioxVoiceCatalog.accents(voices) == ["american", "british", "australian", "japanese", "spanish"])
    #expect(SonioxVoiceCatalog.genders(voices) == ["female", "male"])
    #expect(SonioxVoiceCatalog.filter(SonioxVoiceCatalog.fallback, SonioxVoiceFilter()).map(\.id) == SonioxTTS.voices)
    #expect(SonioxVoiceCatalog.genders(SonioxVoiceCatalog.fallback).isEmpty)
}

@Test func catalogFetchFollowsThePaginationCursor() async throws {
    let voices = try sharedVoices()
    let http = StubHTTP { request in
        let cursor = query(request)["cursor"]
        let page: [String: Any] =
            cursor == nil
            ? ["voices": voices.prefix(5).map(\.wire), "next_page_cursor": "page-2"]
            : ["voices": voices.dropFirst(5).map(\.wire), "next_page_cursor": NSNull()]
        return (200, try JSONSerialization.data(withJSONObject: page))
    }
    let fetched = try await library(scratch(), key: "secret", http).refresh()
    #expect(fetched.map(\.id) == ["Hazel", "Grace", "Daniel", "Emma", "Nina", "Owen", "Arthur", "Kenji", "Lucia"])
    #expect(http.requests.count == 2)
    #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
    #expect(http.requests[0].url?.host == "api.soniox.com")
    #expect(http.requests[0].url?.path == "/v1/shared-voices")
    #expect(query(http.requests[0]) == ["model": "tts-rt-v2", "limit": "200"])
    #expect(query(http.requests[1])["cursor"] == "page-2")
}

@Test func catalogFallsBackToTheBuiltInVoicesAndThenServesTheLastFetch() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try fixtureData("soniox-shared-voices", "json")
    let online = StubHTTP { _ in (200, fixture) }
    #expect(library(directory, online).cached() == SonioxVoiceCatalog.fallback)
    #expect(SonioxVoiceCatalog.fallback.map(\.id) == SonioxTTS.voices)
    _ = try await library(directory, online).refresh()

    let offline = StubHTTP { _ in throw URLError(.notConnectedToInternet) }
    let cached = library(directory, offline).cached()
    #expect(cached.map(\.id) == ["Hazel", "Grace", "Daniel", "Emma", "Nina", "Owen", "Arthur", "Kenji", "Lucia"])
    #expect(cached.first?.accent == "american")
    await #expect(throws: SonioxError.self) { try await library(directory, offline).refresh() }
    #expect(library(directory, offline).cached() == cached)
    #expect(offline.requests.count == 1)
}

@Test func catalogAndPreviewErrorsMapToSonioxErrors() async throws {
    func failure(_ http: StubHTTP, key: String? = "k") async -> SonioxError? {
        do {
            _ = try await library(scratch(), key: key, http).preview(voice: "Hazel")
            return nil
        } catch {
            return error as? SonioxError
        }
    }
    let untouched = StubHTTP { _ in (200, Data()) }
    #expect(await failure(untouched, key: nil) == .missingKey)
    #expect(await failure(untouched, key: "") == .missingKey)
    #expect(untouched.requests.isEmpty)
    #expect(SonioxError.missingKey.previewMessage.contains("Add a Soniox key"))

    let rejected = await failure(
        StubHTTP { _ in
            (401, Data(#"{"error_code":401,"error_type":"unauthenticated","error_message":"Incorrect API key"}"#.utf8))
        })
    #expect(rejected == SonioxError(.auth, code: 401, type: "unauthenticated", message: "Incorrect API key"))
    #expect(rejected?.previewMessage == "Soniox rejected the API key")

    let invalid = await failure(
        StubHTTP { _ in
            (400, Data(#"{"error_code":400,"error_type":"invalid_request","error_message":"Invalid voice"}"#.utf8))
        })
    #expect(invalid == SonioxError(.server, code: 400, type: "invalid_request", message: "Invalid voice"))
    #expect(invalid?.previewMessage == "Soniox error: Invalid voice")

    #expect(await failure(StubHTTP { _ in throw URLError(.notConnectedToInternet) })?.kind == .network)
    #expect(await failure(StubHTTP { _ in throw URLError(.timedOut) })?.kind == .timeout)
    #expect(await failure(StubHTTP { _ in (200, Data()) })?.kind == .server)
    #expect(await failure(StubHTTP { _ in (503, Data("busy".utf8)) })?.message == "HTTP 503")

    let listing = StubHTTP { _ in
        (401, Data(#"{"status_code":401,"error_type":"unauthenticated","message":"Incorrect API key"}"#.utf8))
    }
    await #expect(throws: SonioxError(.auth, code: 401, type: "unauthenticated", message: "Incorrect API key")) {
        try await library(scratch(), listing).refresh()
    }
    await #expect(throws: SonioxError.missingKey) { try await library(scratch(), key: nil, listing).refresh() }
    let garbled = StubHTTP { _ in (200, Data("<html>".utf8)) }
    await #expect(throws: SonioxError.self) { try await library(scratch(), garbled).refresh() }
}

@Test func previewIsSynthesizedOnceAndThenReplayedFromTheCache() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pcm = Data((0..<480).flatMap { sample in [UInt8(sample & 0xff), 0] })
    let http = StubHTTP { _ in (200, pcm) }
    let voices = library(directory, key: "secret", http)

    let first = try await voices.preview(voice: "Hazel")
    #expect(try await voices.preview(voice: "Hazel") == first)
    #expect(http.requests.count == 1)
    #expect(try Data(contentsOf: first) == PCM.wav(s16le: pcm, sampleRate: 24000))

    let request = try #require(http.requests.first)
    #expect(request.url == URL(string: "https://tts-rt.soniox.com/tts"))
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    let sent = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
    #expect(body["voice"] as? String == "Hazel")
    #expect(body["model"] as? String == "tts-rt-v2")
    #expect(body["language"] as? String == "en")
    #expect(body["audio_format"] as? String == "pcm_s16le")
    #expect(body["sample_rate"] as? Int == 24000)
    #expect(body["text"] as? String == SonioxVoiceLibrary.sentence)
    #expect(body.values.allSatisfy { ($0 as? String)?.contains("secret") != true })

    let other = try await voices.preview(voice: "Grace")
    #expect(other != first)
    #expect(try await voices.preview(voice: "Hazel", model: "tts-rt-v3") != first)
    #expect(http.requests.count == 3)

    let offline = library(directory, key: nil, StubHTTP { _ in throw URLError(.notConnectedToInternet) })
    #expect(try await offline.preview(voice: "Hazel") == first)
}

@Test func failedPreviewIsNotCached() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let failing = StubHTTP { _ in (500, Data()) }
    await #expect(throws: SonioxError.self) { try await library(directory, failing).preview(voice: "Hazel") }
    let working = StubHTTP { _ in (200, Data([1, 0, 2, 0])) }
    _ = try await library(directory, working).preview(voice: "Hazel")
    #expect(working.requests.count == 1)
}

extension SonioxVoice {
    fileprivate var wire: [String: Any] {
        [
            "id": id, "description": description, "gender": gender, "age": age, "accent": accent,
            "use_case": useCases, "style": styles,
        ]
    }
}

@MainActor
private final class FakeOutput: VoicePreviewOutput {
    var played: [VoicePreviewClip] = []
    var stops = 0
    var failure: Error?
    var finish: (@MainActor () -> Void)?

    func play(_ clip: VoicePreviewClip, finished: @escaping @MainActor () -> Void) throws {
        if let failure { throw failure }
        played.append(clip)
        finish = finished
    }

    func stop() {
        stops += 1
    }
}

@MainActor
private func settle(_ player: VoicePreviewPlayer, until done: (VoicePreviewPlayer.State) -> Bool) async {
    for _ in 0..<400 where !done(player.state) {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func speech(_ voice: String) -> VoicePreviewClip {
    .speech(text: "hi", voiceIdentifier: voice)
}

@MainActor
@Test func previewPlayerLoadsPlaysAndReturnsToIdle() async {
    let output = FakeOutput()
    let player = VoicePreviewPlayer(output: output)
    player.play("a") { speech("a") }
    #expect(player.state == .loading("a"))
    #expect(player.isActive("a"))
    await settle(player) { $0 == .playing("a") }
    #expect(player.state == .playing("a"))
    #expect(output.played == [speech("a")])
    output.finish?()
    #expect(player.state == .idle)
    #expect(!player.isActive("a"))
}

@MainActor
@Test func previewPlayerPlaysOneVoiceAtATime() async {
    let output = FakeOutput()
    let player = VoicePreviewPlayer(output: output)
    player.play("a") { speech("a") }
    await settle(player) { $0 == .playing("a") }
    let staleFinish = output.finish
    let stops = output.stops

    player.play("b") { speech("b") }
    #expect(output.stops > stops)
    #expect(player.state == .loading("b"))
    await settle(player) { $0 == .playing("b") }
    #expect(output.played == [speech("a"), speech("b")])
    staleFinish?()
    #expect(player.state == .playing("b"))

    player.toggle("b") { speech("b") }
    #expect(player.state == .idle)
    player.toggle("b") { speech("b") }
    #expect(player.state == .loading("b"))
    player.stop()
    #expect(player.state == .idle)
}

@MainActor
@Test func previewPlayerDropsALoadThatWasReplacedBeforeItFinished() async {
    let output = FakeOutput()
    let player = VoicePreviewPlayer(output: output)
    let (gate, open) = AsyncStream<Void>.makeStream()
    player.play("slow") {
        for await _ in gate { break }
        return speech("slow")
    }
    player.play("fast") { speech("fast") }
    await settle(player) { $0 == .playing("fast") }
    open.yield()
    open.finish()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(player.state == .playing("fast"))
    #expect(output.played == [speech("fast")])
}

@MainActor
@Test func previewPlayerShowsWhySynthesisOrPlaybackFailed() async {
    let output = FakeOutput()
    let player = VoicePreviewPlayer(output: output)
    player.play("a") { throw SonioxError.missingKey }
    await settle(player) { $0 != .loading("a") }
    #expect(player.state == .failed("a", SonioxError.missingKey.message))
    #expect(player.error(for: "a") == SonioxError.missingKey.message)
    #expect(player.error(for: "b") == nil)
    #expect(!player.isActive("a"))

    player.play("b") { throw SonioxError(.auth, code: 401, message: "Incorrect API key") }
    await settle(player) { $0 != .loading("b") }
    #expect(player.error(for: "b") == "Soniox rejected the API key")
    #expect(player.error(for: "a") == nil)

    player.play("c") { throw SonioxError(.network, message: "offline") }
    await settle(player) { $0 != .loading("c") }
    #expect(player.error(for: "c") == "Soniox is not reachable")

    output.failure = URLError(.cannotDecodeContentData)
    player.play("d") { speech("d") }
    await settle(player) { $0 != .loading("d") }
    #expect(player.error(for: "d") != nil)
    #expect(output.played.isEmpty)

    output.failure = nil
    player.play("d") { speech("d") }
    await settle(player) { $0 == .playing("d") }
    #expect(player.error(for: "d") == nil)
}

@MainActor
@Test func timedPreviewOutputFinishesByItselfAndStopsQuietly() async {
    let output = TimedPreviewOutput(seconds: 0.05)
    let player = VoicePreviewPlayer(output: output)
    player.play("a") { speech("a") }
    await settle(player) { $0 == .playing("a") }
    await settle(player) { $0 == .idle }
    #expect(player.state == .idle)
    #expect(output.played == [speech("a")])

    player.play("b") { speech("b") }
    await settle(player) { $0 == .playing("b") }
    player.stop()
    try? await Task.sleep(for: .milliseconds(120))
    #expect(player.state == .idle)
}
