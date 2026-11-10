import Foundation
import Testing

@testable import BrainKit

final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Reply = @Sendable (URLRequest) -> Result<(Int, String), URLError>
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]

    static func client(_ host: String, key: String = "sk-test", model: String = "m", reply: @escaping Reply)
        -> OpenAIChatClient
    {
        lock.withLock { replies[host] = reply }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return OpenAIChatClient(
            baseURL: URL(string: "https://\(host)/v1")!, apiKey: key, model: model,
            session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let reply = Self.lock.withLock { Self.replies[request.url?.host ?? ""] }
        switch reply?(request) {
        case .success((let status, let body)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case nil: client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }
}

private let catalog = """
    {"object":"list","data":[{"id":"gpt-6-luna","object":"model"},{"id":"claude-opus-5-5"},
    {"id":"text-embedding-4"},{"id":"gpt-image-2"},{"id":"TTS-1-hd"},{"id":"whisper-2"},{"id":"gpt-audio"},
    {"id":"omni-moderation"},{"id":"rerank-v4"},{"id":"claude-opus-5-5"},{"id":""},{"object":"model"}]}
    """

@Test func modelListKeepsSortedChatModels() throws {
    #expect(try BrainModelList.parse(Data(catalog.utf8)) == ["claude-opus-5-5", "gpt-6-luna"])
    #expect(try BrainModelList.parse(Data(#"{"data":[]}"#.utf8)).isEmpty)
    #expect(throws: BrainError.malformed) { try BrainModelList.parse(Data("<html>".utf8)) }
}

@Test func currentModelIsAlwaysAChoice() {
    #expect(BrainModelList.choices(["a", "b"], current: "b") == ["a", "b"])
    #expect(BrainModelList.choices(["a", "b"], current: "mine") == ["mine", "a", "b"])
    #expect(BrainModelList.choices([], current: "mine") == ["mine"])
}

@Test func modelCacheKeepsTheLastListOfOneEndpoint() throws {
    let suite = "brain-model-cache-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = URL(string: "https://one.example.test/v1")!
    let second = URL(string: "https://two.example.test/v1")!
    let cache = BrainModelCache(defaults: defaults)
    #expect(cache.models(for: first).isEmpty)
    cache.save(["a", "b"], for: first)
    #expect(BrainModelCache(defaults: defaults).models(for: first) == ["a", "b"])
    #expect(cache.models(for: second).isEmpty)
    cache.save(["c"], for: second)
    #expect(cache.models(for: first).isEmpty)
}

@Test func modelsAreFetchedFromTheEndpointWithTheKey() async throws {
    let client = StubProtocol.client("list.example.test") { request in
        guard request.url?.path == "/v1/models", request.httpMethod == "GET",
            request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test"
        else { return .success((500, "")) }
        return .success((200, catalog))
    }
    #expect(try await client.models() == ["claude-opus-5-5", "gpt-6-luna"])
}

@Test(arguments: [401, 403])
func modelListReportsARejectedKey(status: Int) async {
    let client = StubProtocol.client("denied\(status).example.test") { _ in
        .success((status, #"{"error":{"message":"bad key"}}"#))
    }
    await #expect(throws: BrainError.unauthorized) { try await client.models() }
    #expect(BrainError.unauthorized.note == "The endpoint rejected the API key")
}

@Test func modelListReportsNetworkAndServerErrors() async {
    let offline = StubProtocol.client("offline.example.test") { _ in .failure(URLError(.notConnectedToInternet)) }
    do {
        _ = try await offline.models()
        Issue.record("an offline endpoint returned a model list")
    } catch {
        guard case .unreachable = error as? BrainError else {
            Issue.record("unexpected error \(error)")
            return
        }
        #expect((error as? BrainError)?.note.hasPrefix("No connection: ") == true)
    }
    let slow = StubProtocol.client("slow.example.test") { _ in .failure(URLError(.timedOut)) }
    await #expect(throws: BrainError.timeout) { try await slow.models() }
    let missing = StubProtocol.client("missing.example.test") { _ in .success((404, "Not Found\n")) }
    await #expect(throws: BrainError.http(404, "Not Found")) { try await missing.models() }
    #expect(BrainError.http(404, "Not Found").note == "HTTP 404: Not Found")
    #expect(BrainError.http(502, "").note == "HTTP 502")
    let page = StubProtocol.client("page.example.test") { _ in .success((200, "<html>")) }
    await #expect(throws: BrainError.malformed) { try await page.models() }
}

@Test func checkSendsTheVoiceRequestAndReportsTheResponseTime() async throws {
    let client = StubProtocol.client("works.example.test", model: "gpt-6-luna") { request in
        guard request.url?.path == "/v1/chat/completions", request.httpMethod == "POST",
            request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test"
        else { return .success((500, "")) }
        return .success((200, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"}}]}\n\ndata: [DONE]\n\n"))
    }
    guard case .works(let seconds) = await client.check() else {
        Issue.record("the check failed")
        return
    }
    #expect(seconds >= 0 && seconds < 10)
    #expect(ModelCheck.works(0.84).note == "Works, answered in 0.8 s")
    let body = try #require(try client.request([.user("hi")], tools: AgentToolbox.definitions).httpBody)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(object.keys) == ["model", "messages", "stream", "tools"])
}

@Test func checkShowsTheServerMessageOfARefusedModel() async {
    let denied = StubProtocol.client("refused.example.test") { _ in
        .success(
            (
                403,
                #"{"error":{"message":"this client key cannot use this model","type":"permission_error","code":"provider_not_allowed"}}"#
            ))
    }
    #expect(await denied.check() == .failed("HTTP 403: this client key cannot use this model"))
    let unknown = StubProtocol.client("unknown.example.test") { _ in
        .success((400, #"{"error":{"message":"unknown provider for model nope","code":"model_not_found"}}"#))
    }
    #expect(await unknown.check() == .failed("HTTP 400: unknown provider for model nope"))
    let plain = StubProtocol.client("plain.example.test") { _ in .success((500, #"{"error":"upstream down"}"#)) }
    #expect(await plain.check() == .failed("HTTP 500: upstream down"))
}

@Test func checkFailsWithoutAReplyStream() async {
    let silent = StubProtocol.client("silent.example.test") { _ in
        .success((200, #"{"choices":[{"message":{"content":"OK"}}]}"#))
    }
    #expect(await silent.check() == .failed(BrainError.malformed.note))
    let broken = StubProtocol.client("broken.example.test") { _ in
        .success((200, "data: {\"error\":{\"message\":\"model overloaded\"}}\n\n"))
    }
    #expect(await broken.check() == .failed("model overloaded"))
    let slow = StubProtocol.client("slowcheck.example.test") { _ in .failure(URLError(.timedOut)) }
    #expect(await slow.check() == .failed("The endpoint did not answer in time"))
}
