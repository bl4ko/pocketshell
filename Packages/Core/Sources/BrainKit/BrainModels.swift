import Foundation

public enum BrainModelList {
    static let excluded = ["image", "embedding", "tts", "whisper", "audio", "moderation", "rerank"]

    public static func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return !lowered.isEmpty && !excluded.contains { lowered.contains($0) }
    }

    public static func parse(_ data: Data) throws -> [String] {
        struct Listing: Decodable {
            struct Model: Decodable { var id: String? }
            var data: [Model]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { throw BrainError.malformed }
        return Set(listing.data.compactMap(\.id)).filter(isChatModel).sorted()
    }

    public static func choices(_ models: [String], current: String) -> [String] {
        models.contains(current) ? models : [current] + models
    }
}

public struct BrainModelCache {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "pocketshell.brainModelList") {
        self.defaults = defaults
        self.key = key
    }

    public func models(for endpoint: URL) -> [String] {
        defaults.dictionary(forKey: key)?[endpoint.absoluteString] as? [String] ?? []
    }

    public func save(_ models: [String], for endpoint: URL) {
        defaults.set([endpoint.absoluteString: models], forKey: key)
    }
}

public enum ModelCheck: Equatable, Sendable {
    case works(TimeInterval)
    case failed(String)

    public var note: String {
        switch self {
        case .works(let seconds): "Works, answered in \(String(format: "%.1f", seconds)) s"
        case .failed(let reason): reason
        }
    }
}

extension BrainError {
    public var note: String {
        switch self {
        case .notConfigured: "Add the endpoint to load its models"
        case .unauthorized: "The endpoint rejected the API key"
        case .modelRefused(let detail): detail.isEmpty ? spoken : detail
        case .unreachable(let reason): "No connection: \(reason)"
        case .timeout: "The endpoint did not answer in time"
        case .http(let code, let message): message.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(message)"
        case .api(let message): message
        case .malformed: "The endpoint sent an answer that is not readable"
        }
    }
}

extension OpenAIChatClient {
    public func models() async throws -> [String] {
        try BrainModelList.parse(try await send(warmUpRequest, keyErrors: true))
    }

    public func check() async -> ModelCheck {
        let start = ContinuousClock.now
        do {
            let request = try request([.user("Reply with the word OK.")], tools: AgentToolbox.definitions)
            var parser = SSEParser()
            var assembler = ChatStreamAssembler()
            var replied = false
            for data in parser.feed(try await send(request, keyErrors: false)) + parser.finish() {
                for event in try assembler.consume(data) {
                    if case .finished = event { continue }
                    replied = true
                }
            }
            guard replied else { throw BrainError.malformed }
            return .works((ContinuousClock.now - start) / .seconds(1))
        } catch {
            return .failed((Self.map(error) as? BrainError)?.note ?? "Cancelled")
        }
    }

    static func serverMessage(_ body: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message =
            (object?["error"] as? [String: Any])?["message"] as? String ?? object?["error"] as? String
            ?? object?["message"] as? String ?? String(decoding: body.prefix(200), as: UTF8.self)
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ request: URLRequest, keyErrors: Bool) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if (200..<300).contains(status) { return data }
            throw keyErrors && (status == 401 || status == 403)
                ? BrainError.unauthorized : BrainError.http(status, Self.serverMessage(data))
        } catch {
            throw Self.map(error)
        }
    }
}
