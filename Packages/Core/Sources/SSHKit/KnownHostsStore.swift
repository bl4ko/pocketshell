import Crypto
import Foundation

public struct KnownHostsStore: Sendable {
    public enum Verdict: Equatable, Sendable {
        case firstUse
        case match
        case mismatch(stored: String, presented: String)
    }

    private static let lock = NSLock()

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func check(host: String, port: Int, publicKeyLine: String) throws -> Verdict {
        let presented = Self.fingerprint(publicKeyLine: publicKeyLine)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let stored = try read()[key(host, port)] else { return .firstUse }
        return stored == presented ? .match : .mismatch(stored: stored, presented: presented)
    }

    public func trust(host: String, port: Int, publicKeyLine: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var entries = try read()
        entries[key(host, port)] = Self.fingerprint(publicKeyLine: publicKeyLine)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    public func entries() throws -> [String: String] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try read()
    }

    public func merge(_ incoming: [String: String]) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var entries = try read()
        for (key, value) in incoming where entries[key] == nil {
            entries[key] = value
        }
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func fingerprint(publicKeyLine: String) -> String {
        let parts = publicKeyLine.split(separator: " ")
        let blob =
            parts.count > 1
            ? Data(base64Encoded: String(parts[1])) ?? Data(publicKeyLine.utf8) : Data(publicKeyLine.utf8)
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private func key(_ host: String, _ port: Int) -> String {
        "\(host):\(port)"
    }

    private func read() throws -> [String: String] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return [:]
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}
