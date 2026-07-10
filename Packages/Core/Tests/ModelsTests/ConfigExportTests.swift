import Foundation
import Models
import Testing

@Test func configExportRoundTripsThroughJSON() throws {
    let host = HostConfig(name: "mini", hostname: "192.0.2.10", port: 22, username: "alice", keyTag: "device")
    let export = ConfigExport(
        hosts: [host],
        vncHosts: [],
        snippets: [],
        toolbarKeys: ToolbarKey.defaults,
        knownHosts: ["192.0.2.10:22": "SHA256:abc"]
    )
    let data = try JSONEncoder().encode(export)
    let decoded = try JSONDecoder().decode(ConfigExport.self, from: data)
    #expect(decoded == export)
    #expect(decoded.version == 1)
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
