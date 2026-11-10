import Foundation
import Testing

@testable import BrainKit

private func events(_ raw: String, chunkSize: Int) throws -> [BrainStreamEvent] {
    var parser = SSEParser()
    var assembler = ChatStreamAssembler()
    var result: [BrainStreamEvent] = []
    let bytes = Array(raw.utf8)
    var start = 0
    while start < bytes.count {
        let end = min(start + chunkSize, bytes.count)
        for data in parser.feed(bytes[start..<end]) { result += try assembler.consume(data) }
        start = end
    }
    for data in parser.finish() { result += try assembler.consume(data) }
    return result + assembler.finish()
}

@Test(arguments: [1, 7, 64, 100_000])
func assemblesTextAndToolCallsFromStreamDeltas(chunkSize: Int) throws {
    let result = try events(fixture("chat-tool-call.sse"), chunkSize: chunkSize)
    let text = result.compactMap { if case .text(let delta) = $0 { delta } else { nil } }.joined()
    #expect(text == "Hmm, let me check that.")
    #expect(
        result.suffix(2) == [
            .toolCalls([
                ToolCall(id: "call_list01", name: "list_agents", arguments: "{}"),
                ToolCall(
                    id: "call_read02", name: "read_answer", arguments: #"{"agent": "Claude in api", "which": "last"}"#),
            ]),
            .finished("tool_calls"),
        ])
    #expect(result.filter { if case .finished = $0 { true } else { false } }.count == 1)
}

@Test func parsesCRLFTextStream() throws {
    let result = try events(fixture("chat-text.sse"), chunkSize: 5)
    #expect(
        result == [.text("Claude finished"), .text(" the migration. All tests pass."), .finished("stop")])
}

@Test func streamWithoutDoneStillFinishes() throws {
    let raw = #"data: {"choices":[{"index":0,"delta":{"content":"Hi"}}]}"#
    #expect(try events(raw, chunkSize: 3) == [.text("Hi"), .finished(nil)])
}

@Test func errorPayloadThrowsAPIError() {
    var assembler = ChatStreamAssembler()
    #expect(throws: BrainError.api("Rate limit")) {
        try assembler.consume(#"{"error":{"message":"Rate limit","type":"requests"}}"#)
    }
    #expect(throws: BrainError.malformed) { try assembler.consume("not json") }
}

@Test func toolCallArgumentsDecodeAsObject() {
    let call = ToolCall(id: "c", name: "send_prompt", arguments: #"{"text":"run the tests","agent":"codex"}"#)
    #expect(call.argumentObject["text"] as? String == "run the tests")
    #expect(ToolCall(id: "c", name: "x", arguments: "{").argumentObject.isEmpty)
}

@Test func requestEncodesOpenAIWireFormat() throws {
    let client = OpenAIChatClient(
        baseURL: URL(string: "https://llm.example.test/v1")!, apiKey: "sk-test", model: "gpt-6-luna")
    let request = try client.request(
        [
            .system("sys"), .user("hi"),
            .assistant("", toolCalls: [ToolCall(id: "call_1", name: "list_agents", arguments: "{}")]),
            .tool("call_1", #"{"agents":[]}"#),
        ], tools: AgentToolbox.definitions)
    #expect(request.url?.absoluteString == "https://llm.example.test/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    let body = try #require(request.httpBody)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == "gpt-6-luna")
    #expect(object["stream"] as? Bool == true)
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(messages[2]["content"] is NSNull)
    let calls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
    #expect(calls[0]["type"] as? String == "function")
    #expect((calls[0]["function"] as? [String: Any])?["name"] as? String == "list_agents")
    #expect(messages[3]["tool_call_id"] as? String == "call_1")
    let tools = try #require(object["tools"] as? [[String: Any]])
    let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    #expect(
        Set(names).isSuperset(of: [
            "list_agents", "read_answer", "send_prompt", "answer_question", "send_key", "focus_agent", "unsent_prompt",
        ]))
}

@Test func endpointKeepsAFullCompletionsURL() {
    let full = URL(string: "https://llm.example.test/openai/v1/chat/completions")!
    #expect(OpenAIChatClient.endpoint(for: full) == full)
}

@Test func warmUpAsksTheSameHostForItsModelList() {
    let client = OpenAIChatClient(
        baseURL: URL(string: "https://llm.example.test/v1")!, apiKey: "sk-test", model: "gpt-6-luna")
    #expect(client.warmUpRequest.url?.absoluteString == "https://llm.example.test/v1/models")
    #expect(client.warmUpRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(client.warmUpRequest.httpMethod == "GET")
    let full = OpenAIChatClient(
        baseURL: URL(string: "https://llm.example.test/openai/v1/chat/completions")!, apiKey: "", model: "m")
    #expect(full.warmUpRequest.url?.absoluteString == "https://llm.example.test/openai/v1/models")
    #expect(full.warmUpRequest.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func messagesRoundTripThroughStorage() throws {
    let messages: [ChatMessage] = [
        .user("hi"), .assistant("ok", toolCalls: [ToolCall(id: "a", name: "list_agents", arguments: "{}")]),
        .tool("a", "{}"),
    ]
    let decoded = try JSONDecoder().decode([ChatMessage].self, from: JSONEncoder().encode(messages))
    #expect(decoded == messages)
}

@Test func urlErrorsMapToSpokenBrainErrors() {
    #expect(OpenAIChatClient.map(URLError(.timedOut)) as? BrainError == .timeout)
    #expect(OpenAIChatClient.map(URLError(.cannotConnectToHost)) as? BrainError != nil)
    #expect(OpenAIChatClient.map(URLError(.cancelled)) is CancellationError)
}

@Test func voiceTurnReportsARefusedModelNotARejectedKey() async {
    func failure(_ host: String, _ status: Int, _ body: String) async -> BrainError? {
        let client = StubProtocol.client(host) { _ in .success((status, body)) }
        do {
            for try await _ in client.stream([.user("hi")], tools: []) {}
            return nil
        } catch {
            return error as? BrainError
        }
    }
    let denied =
        #"{"error":{"message":"this client key cannot use this model","type":"permission_error","code":"provider_not_allowed"}}"#
    let unknown = #"{"error":{"message":"unknown provider for model nope","code":"model_not_found"}}"#
    let invalid = #"{"error":{"message":"messages is empty","code":"invalid_request"}}"#
    #expect(
        await failure("turn403.example.test", 403, denied) == .modelRefused("this client key cannot use this model"))
    #expect(await failure("turn400.example.test", 400, unknown) == .modelRefused("unknown provider for model nope"))
    #expect(await failure("turn404.example.test", 404, unknown) == .modelRefused("unknown provider for model nope"))
    #expect(await failure("turn403plain.example.test", 403, "Forbidden") == .modelRefused(""))
    #expect(await failure("turn401.example.test", 401, #"{"error":{"message":"bad key"}}"#) == .unauthorized)
    #expect(await failure("turn400other.example.test", 400, invalid) == .http(400, invalid))
    let spoken = "This key cannot use the selected model. Choose a different model in Settings."
    #expect(BrainError.modelRefused("no access").spoken == spoken)
    #expect(BrainError.modelRefused("no access").caption == spoken + " (no access)")
    #expect(BrainError.modelRefused("").caption == spoken)
    #expect(BrainError.unauthorized.spoken == "The brain rejected the API key.")
    #expect(BrainError.unauthorized.caption == BrainError.unauthorized.spoken)
}
