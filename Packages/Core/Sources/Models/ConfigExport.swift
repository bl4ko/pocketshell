import Foundation

public struct TabRecord: Codable, Equatable, Sendable {
    public var name: String?
    public var tmuxSession: String?
    public var windowIndex: Int?

    public init(name: String? = nil, tmuxSession: String? = nil, windowIndex: Int? = nil) {
        self.name = name
        self.tmuxSession = tmuxSession
        self.windowIndex = windowIndex
    }
}

public struct WorkspaceConfig: Codable, Equatable, Sendable {
    public var savedTabs: [String: [TabRecord]]
    public var sessionOrder: [String: [String]]
    public var updatedAtByHost: [String: Date]?

    public init(
        savedTabs: [String: [TabRecord]] = [:],
        sessionOrder: [String: [String]] = [:],
        updatedAtByHost: [String: Date]? = nil
    ) {
        self.savedTabs = savedTabs
        self.sessionOrder = sessionOrder
        self.updatedAtByHost = updatedAtByHost
    }

    public func tmuxSessions(hostID: UUID, configuredSession: String?) -> [String] {
        var sessions = configuredSession.map { [$0] } ?? []
        for session in savedTabs[hostID.uuidString]?.compactMap(\.tmuxSession) ?? [] where !sessions.contains(session) {
            sessions.append(session)
        }
        return sessions
    }

    public static func merged(local: Self, remote: Self) -> Self {
        let localDates = local.updatedAtByHost ?? [:]
        let remoteDates = remote.updatedAtByHost ?? [:]
        let hostIDs = Set(local.savedTabs.keys)
            .union(remote.savedTabs.keys)
            .union(local.sessionOrder.keys)
            .union(remote.sessionOrder.keys)
            .union(localDates.keys)
            .union(remoteDates.keys)
        var tabs = local.savedTabs
        var order = local.sessionOrder
        var dates = localDates

        for hostID in hostIDs {
            switch (localDates[hostID], remoteDates[hostID]) {
            case let (localDate?, remoteDate?):
                if remoteDate >= localDate {
                    tabs[hostID] = remote.savedTabs[hostID]
                    order[hostID] = remote.sessionOrder[hostID]
                    dates[hostID] = remoteDate
                }
            case (nil, _?):
                tabs[hostID] = remote.savedTabs[hostID]
                order[hostID] = remote.sessionOrder[hostID]
                dates[hostID] = remoteDates[hostID]
            case (_?, nil):
                break
            case (nil, nil):
                if let remoteTabs = remote.savedTabs[hostID] {
                    var records = tabs[hostID] ?? []
                    records.append(contentsOf: remoteTabs.filter { !records.contains($0) })
                    tabs[hostID] = records
                }
                if order[hostID] == nil {
                    order[hostID] = remote.sessionOrder[hostID]
                }
            }
        }
        return Self(savedTabs: tabs, sessionOrder: order, updatedAtByHost: dates)
    }
}

public struct ConfigExport: Codable, Equatable, Sendable {
    public var version: Int
    public var hosts: [HostConfig]
    public var vncHosts: [VNCHostConfig]
    public var snippets: [Snippet]
    public var toolbarKeys: [ToolbarKey]
    public var knownHosts: [String: String]
    public var workspace: WorkspaceConfig?

    public init(
        hosts: [HostConfig],
        vncHosts: [VNCHostConfig],
        snippets: [Snippet],
        toolbarKeys: [ToolbarKey],
        knownHosts: [String: String],
        workspace: WorkspaceConfig? = nil
    ) {
        version = 1
        self.hosts = hosts
        self.vncHosts = vncHosts
        self.snippets = snippets
        self.toolbarKeys = toolbarKeys
        self.knownHosts = knownHosts
        self.workspace = workspace
    }

    public static func mergeByID<T: Identifiable & Equatable>(existing: [T], incoming: [T]) -> [T] {
        var result = existing
        for item in incoming {
            if let index = result.firstIndex(where: { $0.id == item.id }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }
}
