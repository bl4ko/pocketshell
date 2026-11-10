import Foundation

public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var data: [String] = []

    public init() {}

    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [String] where Bytes.Element == UInt8 {
        var events: [String] = []
        for byte in bytes {
            if byte == 0x0A {
                if line.last == 0x0D { line.removeLast() }
                if let event = take(line: line) { events.append(event) }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        return events
    }

    public mutating func finish() -> [String] {
        var events: [String] = []
        if !line.isEmpty, let event = take(line: line) { events.append(event) }
        line.removeAll()
        if !data.isEmpty { events.append(data.joined(separator: "\n")) }
        data.removeAll()
        return events
    }

    private mutating func take(line: [UInt8]) -> String? {
        guard !line.isEmpty else {
            defer { data.removeAll() }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
        let text = String(decoding: line, as: UTF8.self)
        guard text.hasPrefix("data:") else { return nil }
        var value = text.dropFirst(5)
        if value.first == " " { value = value.dropFirst() }
        data.append(String(value))
        return nil
    }
}

public enum BrainStreamEvent: Equatable, Sendable {
    case text(String)
    case toolCalls([ToolCall])
    case finished(String?)
}

public enum BrainError: Error, Equatable, Sendable {
    case notConfigured
    case unauthorized
    case modelRefused(String)
    case unreachable(String)
    case timeout
    case http(Int, String)
    case api(String)
    case malformed

    public var spoken: String {
        switch self {
        case .notConfigured: "The brain is not set up. Add its address and key in Settings."
        case .unauthorized: "The brain rejected the API key."
        case .modelRefused: "This key cannot use the selected model. Choose a different model in Settings."
        case .unreachable: "I can't reach the brain right now."
        case .timeout: "The brain took too long to answer."
        case .http(let code, _): "The brain answered with error \(code)."
        case .api: "The brain reported an error."
        case .malformed: "The brain sent something I could not read."
        }
    }

    public var caption: String {
        if case .modelRefused(let detail) = self, !detail.isEmpty { return "\(spoken) (\(detail))" }
        return spoken
    }
}

public struct ChatStreamAssembler: Sendable {
    private struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var calls: [Int: PartialCall] = [:]
    private var order: [Int] = []
    private var done = false

    public init() {}

    public mutating func consume(_ data: String) throws -> [BrainStreamEvent] {
        guard !done else { return [] }
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" { return finish(reason: nil) }
        guard let bytes = trimmed.data(using: .utf8), !bytes.isEmpty else { return [] }
        let chunk: Chunk
        do {
            chunk = try JSONDecoder().decode(Chunk.self, from: bytes)
        } catch {
            throw BrainError.malformed
        }
        if let error = chunk.error { throw BrainError.api(error.message ?? "error") }
        var events: [BrainStreamEvent] = []
        for choice in chunk.choices ?? [] {
            if let text = choice.delta?.content, !text.isEmpty { events.append(.text(text)) }
            for (position, delta) in (choice.delta?.toolCalls ?? []).enumerated() {
                let index = delta.index ?? position
                if calls[index] == nil {
                    calls[index] = PartialCall()
                    order.append(index)
                }
                if let id = delta.id, !id.isEmpty { calls[index]?.id = id }
                if let name = delta.function?.name { calls[index]?.name += name }
                if let arguments = delta.function?.arguments { calls[index]?.arguments += arguments }
            }
            if let reason = choice.finishReason { events += finish(reason: reason) }
        }
        return events
    }

    public mutating func finish(reason: String? = nil) -> [BrainStreamEvent] {
        guard !done else { return [] }
        done = true
        let assembled = order.compactMap { index -> ToolCall? in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            return ToolCall(
                id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name,
                arguments: call.arguments.isEmpty ? "{}" : call.arguments)
        }
        return (assembled.isEmpty ? [] : [.toolCalls(assembled)]) + [.finished(reason)]
    }

    private struct Chunk: Decodable {
        var choices: [Choice]?
        var error: APIError?
    }

    private struct APIError: Decodable {
        var message: String?
    }

    private struct Choice: Decodable {
        var delta: Delta?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    private struct Delta: Decodable {
        var content: String?
        var toolCalls: [ToolDelta]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    private struct ToolDelta: Decodable {
        var index: Int?
        var id: String?
        var function: FunctionDelta?
    }

    private struct FunctionDelta: Decodable {
        var name: String?
        var arguments: String?
    }
}

public protocol BrainModel: Sendable {
    func stream(_ messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<BrainStreamEvent, Error>
    func warmUp()
}

extension BrainModel {
    public func warmUp() {}
}

public struct OpenAIChatClient: BrainModel {
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var timeout: TimeInterval
    let session: URLSession

    public init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval = 20, session: URLSession = .shared)
    {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    public static func endpoint(for baseURL: URL) -> URL {
        let path = baseURL.path
        if path.hasSuffix("/chat/completions") { return baseURL }
        return baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
    }

    public func request(_ messages: [ChatMessage], tools: [ToolDefinition]) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint(for: baseURL), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: model, messages: messages, tools: tools))
        return request
    }

    public var warmUpRequest: URLRequest {
        let models = Self.endpoint(for: baseURL).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("models")
        var request = URLRequest(url: models, timeoutInterval: timeout)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    public func warmUp() {
        session.dataTask(with: warmUpRequest).resume()
    }

    public func stream(_ messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<
        BrainStreamEvent, Error
    > {
        let request: URLRequest
        do {
            request = try self.request(messages, tools: tools)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: BrainError.malformed) }
        }
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = [UInt8]()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 2000 { break }
                        }
                        throw Self.failure(status: http.statusCode, body: Data(body))
                    }
                    var parser = SSEParser()
                    var assembler = ChatStreamAssembler()
                    var chunk = [UInt8]()
                    for try await byte in bytes {
                        chunk.append(byte)
                        guard byte == 0x0A else { continue }
                        for data in parser.feed(chunk) {
                            for event in try assembler.consume(data) { continuation.yield(event) }
                        }
                        chunk.removeAll(keepingCapacity: true)
                    }
                    for data in parser.feed(chunk) + parser.finish() {
                        for event in try assembler.consume(data) { continuation.yield(event) }
                    }
                    for event in assembler.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func failure(status: Int, body: Data) -> BrainError {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        if status == 401 { return .unauthorized }
        if status == 403 || error?["code"] as? String == "model_not_found" {
            return .modelRefused(error?["message"] as? String ?? "")
        }
        return .http(status, String(decoding: body, as: UTF8.self))
    }

    public static func map(_ error: Error) -> Error {
        if error is BrainError || error is CancellationError { return error }
        guard let urlError = error as? URLError else { return BrainError.unreachable(error.localizedDescription) }
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .timedOut: return BrainError.timeout
        case .userAuthenticationRequired: return BrainError.unauthorized
        default: return BrainError.unreachable(urlError.localizedDescription)
        }
    }
}
