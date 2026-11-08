import Foundation

public enum SocketMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

public protocol SonioxSocket: AnyObject, Sendable {
    func send(_ message: SocketMessage) async throws
    func receive() async throws -> SocketMessage
    func close()
}

public typealias SonioxConnect = @Sendable (URL, String) -> SonioxSocket

public struct SonioxError: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: Equatable, Sendable {
        case auth, server, network, timeout
    }

    public var kind: Kind
    public var code: Int?
    public var type: String?
    public var message: String

    public init(_ kind: Kind, code: Int? = nil, type: String? = nil, message: String) {
        self.kind = kind
        self.code = code
        self.type = type
        self.message = message
    }

    public var errorDescription: String? { message }

    public var notice: String {
        switch kind {
        case .auth: "Soniox rejected the API key"
        case .timeout: "Soniox did not answer in time"
        case .network: "Soniox is not reachable"
        case .server: "Soniox error: \(message)"
        }
    }

    static func frame(_ object: [String: Any]) -> SonioxError? {
        guard let code = object["error_code"] as? Int else { return nil }
        let type = object["error_type"] as? String
        let message = object["error_message"] as? String ?? "Error \(code)"
        let auth = code == 401 || code == 403 || type == "unauthenticated"
        return SonioxError(auth ? .auth : .server, code: code, type: type, message: message)
    }
}

public final class WebSocketConnection: SonioxSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(url: URL, apiKey: String, session: URLSession = .shared) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 8 << 20
        task.resume()
    }

    public static let connect: SonioxConnect = { url, key in WebSocketConnection(url: url, apiKey: key) }

    public func send(_ message: SocketMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .data(let data): try await task.send(.data(data))
        }
    }

    public func receive() async throws -> SocketMessage {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default: return .data(Data())
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

enum SonioxJSON {
    static func object(_ message: SocketMessage) -> [String: Any]? {
        let data: Data
        switch message {
        case .text(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
