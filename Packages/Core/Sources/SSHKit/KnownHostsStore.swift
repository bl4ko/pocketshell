import Crypto
import Foundation

public struct KnownHostsStore: Sendable {
    public enum Verdict: Equatable, Sendable {
        case firstUse
        case match
        case mismatch(stored: String, presented: String)
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func check(host: String, port: Int, publicKeyLine: String) -> Verdict {
        let presented = Self.fingerprint(publicKeyLine: publicKeyLine)
        guard let stored = read()[key(host, port)] else { return .firstUse }
        return stored == presented ? .match : .mismatch(stored: stored, presented: presented)
    }

    public func trust(host: String, port: Int, publicKeyLine: String) throws {
        var entries = read()
        entries[key(host, port)] = Self.fingerprint(publicKeyLine: publicKeyLine)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func fingerprint(publicKeyLine: String) -> String {
        let parts = publicKeyLine.split(separator: " ")
        let blob = parts.count > 1 ? Data(base64Encoded: String(parts[1])) ?? Data(publicKeyLine.utf8) : Data(publicKeyLine.utf8)
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private func key(_ host: String, _ port: Int) -> String {
        "\(host):\(port)"
    }

    private func read() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
