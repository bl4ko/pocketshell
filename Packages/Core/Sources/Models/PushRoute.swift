import Foundation

public struct PushRoute: Equatable, Sendable {
    public var host: HostConfig?
    public var backend: String?
    public var session: String?
    public var windowIndex: Int?
    public var windowID: String?
    public var workspaceID: String?
    public var paneID: String?

    public static func resolve(_ info: [AnyHashable: Any], hosts: [HostConfig]) -> PushRoute {
        PushRoute(
            host: resolveHost(
                id: (info["hostID"] as? String).flatMap(UUID.init(uuidString:)),
                name: info["hostName"] as? String,
                hosts: hosts
            ),
            backend: info["backend"] as? String,
            session: info["session"] as? String,
            windowIndex: integer(info["windowIndex"]),
            windowID: info["windowID"] as? String,
            workspaceID: info["workspaceID"] as? String,
            paneID: info["paneID"] as? String
        )
    }

    public static func resolveHost(id: UUID?, name: String?, hosts: [HostConfig]) -> HostConfig? {
        if let id, let match = hosts.first(where: { $0.id == id }) { return match }
        guard let name, !name.isEmpty else { return nil }
        return hosts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public var visibleWindowKey: String? {
        guard let host, let session else { return nil }
        if backend == "herdr" {
            return workspaceID.map { "\(host.id):herdr:\(session):\($0)" }
        }
        return windowIndex.map { "\(host.id):\(session):\($0)" }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

public struct HookPushCache: Sendable {
    public static let detectCommand =
        #"test -f "$HOME/.local/share/pocketshell/push/config" && echo pocketshell-push-yes || echo pocketshell-push-no"#

    private var entries: [UUID: (installed: Bool, checkedAt: Date)] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 600) {
        self.ttl = ttl
    }

    public static func parse(_ output: String) -> Bool? {
        if output.contains("pocketshell-push-yes") { return true }
        if output.contains("pocketshell-push-no") { return false }
        return nil
    }

    public func isInstalled(_ hostID: UUID) -> Bool {
        entries[hostID]?.installed ?? false
    }

    public func needsRefresh(_ hostID: UUID, now: Date = Date()) -> Bool {
        guard let entry = entries[hostID] else { return true }
        return now.timeIntervalSince(entry.checkedAt) >= ttl
    }

    public mutating func record(_ installed: Bool, for hostID: UUID, at now: Date = Date()) {
        entries[hostID] = (installed, now)
    }
}
