import Foundation
import Models
import Testing

@Test func configExportRoundTripsThroughJSON() throws {
    let host = HostConfig(name: "mini", hostname: "192.0.2.10", port: 22, username: "alice", keyTag: "device")
    let workspace = WorkspaceConfig(
        savedTabs: [host.id.uuidString: [TabRecord(name: "agent", tmuxSession: "agents", windowIndex: 2)]],
        sessionOrder: [host.id.uuidString: ["agents"]]
    )
    let export = ConfigExport(
        hosts: [host],
        vncHosts: [],
        snippets: [],
        toolbarKeys: ToolbarKey.defaults,
        knownHosts: ["192.0.2.10:22": "SHA256:abc"],
        workspace: workspace
    )
    let data = try JSONEncoder().encode(export)
    let decoded = try JSONDecoder().decode(ConfigExport.self, from: data)
    #expect(decoded == export)
    #expect(decoded.version == 1)
}

@Test func hostWorkspaceRoundTripsThroughJSON() throws {
    let workspace = HostWorkspace(
        tabs: [TabRecord(name: "agent", tmuxSession: "agents", windowIndex: 2)],
        sessionOrder: ["agents", "infra"],
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let data = try JSONEncoder().encode(workspace)
    let decoded = try JSONDecoder().decode(HostWorkspace.self, from: data)
    #expect(decoded == workspace)
}

@Test func herdrTabRecordRoundTripsThroughJSON() throws {
    let record = TabRecord(
        name: "agent",
        number: 1,
        tabGroup: "Herdr · work",
        herdrSession: "work",
        herdrWorkspaceID: "w1"
    )
    let data = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(TabRecord.self, from: data) == record)
    #expect(record.groupName == "Herdr · work")
}

@Test func workspaceSyncWriteCommandEmbedsDecodablePayload() throws {
    let workspace = HostWorkspace(
        tabs: [TabRecord(tmuxSession: "agents", windowIndex: 0)],
        sessionOrder: ["agents"],
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let command = try #require(WorkspaceSync.writeCommand(workspace))
    #expect(command.contains("mkdir -p \"$HOME/.config/pocketshell\""))
    #expect(command.contains("base64 -d > \"$HOME/.config/pocketshell/workspace.json."))
    #expect(command.contains(".tmp\" && mv "))
    let payload = try #require(command.components(separatedBy: "'").dropFirst(3).first)
    let data = try #require(Data(base64Encoded: payload))
    let decoded = try JSONDecoder().decode(HostWorkspace.self, from: data)
    #expect(decoded == workspace)
    #expect(WorkspaceSync.decode(String(decoding: data, as: UTF8.self)) == workspace)
}

@Test func workspaceSyncBacksUpReplacedState() throws {
    let old = HostWorkspace(updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let new = HostWorkspace(updatedAt: Date(timeIntervalSince1970: 1_800_000_100))
    let command = try #require(WorkspaceSync.writeCommand(new, replacing: old))
    #expect(command.contains("workspace.json.bak-1800000000000"))
    #expect(command.hasSuffix("\"$HOME/.config/pocketshell/workspace.json\""))
}

@Test func workspaceSyncActionUsesLastWriterWins() {
    let old = Date(timeIntervalSince1970: 1_800_000_000)
    let new = Date(timeIntervalSince1970: 1_800_000_100)
    let remote = HostWorkspace(tabs: [], sessionOrder: [], updatedAt: new)

    #expect(WorkspaceSync.action(localUpdatedAt: nil, remote: nil) == .none)
    #expect(WorkspaceSync.action(localUpdatedAt: old, remote: nil) == .push)
    #expect(WorkspaceSync.action(localUpdatedAt: nil, remote: remote) == .apply(remote))
    #expect(WorkspaceSync.action(localUpdatedAt: old, remote: remote) == .apply(remote))
    #expect(WorkspaceSync.action(localUpdatedAt: new, remote: remote) == .none)
    #expect(
        WorkspaceSync.action(
            localUpdatedAt: new,
            remote: HostWorkspace(tabs: [], sessionOrder: [], updatedAt: old)
        ) == .push
    )
    #expect(WorkspaceSync.decode("") == nil)
    #expect(WorkspaceSync.decode("no session") == nil)
}

@Test func workspaceDerivesUniqueTmuxSessionsFromHostAndTabs() {
    let hostID = UUID()
    let workspace = WorkspaceConfig(
        savedTabs: [
            hostID.uuidString: [
                TabRecord(tmuxSession: "agents", windowIndex: 0),
                TabRecord(tmuxSession: "infra", windowIndex: 1),
                TabRecord(tmuxSession: "agents", windowIndex: 2),
            ]
        ]
    )

    #expect(workspace.tmuxSessions(hostID: hostID, configuredSession: "agents") == ["agents", "infra"])
}

@Test func workspaceMigrationUnionsTabsFromDifferentHosts() {
    let localHost = UUID()
    let remoteHost = UUID()
    let local = WorkspaceConfig(savedTabs: [localHost.uuidString: [TabRecord(tmuxSession: "agents")]])
    let remote = WorkspaceConfig(savedTabs: [remoteHost.uuidString: [TabRecord(tmuxSession: "infra")]])

    let merged = WorkspaceConfig.merged(local: local, remote: remote)
    #expect(merged.savedTabs[localHost.uuidString]?.first?.tmuxSession == "agents")
    #expect(merged.savedTabs[remoteHost.uuidString]?.first?.tmuxSession == "infra")
}

@Test func newerWorkspaceStateWinsIncludingTabClosure() {
    let hostID = UUID().uuidString
    let oldDate = Date(timeIntervalSince1970: 1)
    let newDate = Date(timeIntervalSince1970: 2)
    let local = WorkspaceConfig(
        savedTabs: [hostID: [TabRecord(tmuxSession: "agents")]],
        updatedAtByHost: [hostID: oldDate]
    )
    let remote = WorkspaceConfig(savedTabs: [hostID: []], updatedAtByHost: [hostID: newDate])

    #expect(WorkspaceConfig.merged(local: local, remote: remote).savedTabs[hostID] == [])
}

@Test func mergeByIDReplacesMatchingAndAppendsNew() {
    let a = HostConfig(name: "a", hostname: "1", port: 22, username: "u", keyTag: "k")
    let b = HostConfig(name: "b", hostname: "2", port: 22, username: "u", keyTag: "k")
    var aUpdated = a
    aUpdated.hostname = "1.new"
    let c = HostConfig(name: "c", hostname: "3", port: 22, username: "u", keyTag: "k")

    let merged = ConfigExport.mergeByID(existing: [a, b], incoming: [aUpdated, c])
    #expect(merged == [aUpdated, b, c])
}
