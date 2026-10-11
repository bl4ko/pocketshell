import Foundation

public struct PushRelayProvision: Equatable, Sendable {
    public static let readCommand = #"cat "$HOME/.local/share/pocketshell/push/relay.json" 2>/dev/null"#
    public static let minimumSecretLength = 16

    public var url: String
    public var pairingSecret: String

    public init(url: String, pairingSecret: String) {
        self.url = url
        self.pairingSecret = pairingSecret
    }

    public static func parse(_ output: String) -> PushRelayProvision? {
        struct Payload: Decodable {
            var url: String
            var pairingSecret: String
        }
        guard let data = output.data(using: .utf8),
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            let url = normalizedURL(payload.url),
            payload.pairingSecret.count >= minimumSecretLength
        else { return nil }
        return PushRelayProvision(url: url, pairingSecret: payload.pairingSecret)
    }

    public static func normalizedURL(_ value: String) -> String? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            components.scheme == "https", let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else { return nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url?.absoluteString
    }

    public func shouldConfigure(currentURL: String?, isConfigured: Bool, attempted: Set<String>) -> Bool {
        if attempted.contains(url) { return false }
        if isConfigured, let currentURL, Self.normalizedURL(currentURL) == url { return false }
        return true
    }
}
