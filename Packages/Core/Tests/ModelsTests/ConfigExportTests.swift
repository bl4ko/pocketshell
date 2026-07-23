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
