import Combine
import Foundation
import Models
import Testing

@testable import pocketshell

@MainActor
final class FakeRelayPairing: RelayAutoPairing {
    var isConfigured = false
    var configuredURL: String?
    var configured: [(PushRelayProvision, String)] = []

    func configure(from provision: PushRelayProvision, hostName: String) async {
        configured.append((provision, hostName))
        isConfigured = true
        configuredURL = provision.url
    }
}

@MainActor
struct RelayAutoPairTests {
    let json = #"{"url":"https://relay.example.com/","pairingSecret":"0123456789abcdef"}"#

    func makeMonitor(
        relay: FakeRelayPairing, reply: @escaping @Sendable (String) -> String
    ) -> (SessionMonitor, FakeConnection) {
        let host = HostConfig(name: "box", hostname: "box", username: "u", keyTag: "k", tmuxSession: nil)
        let connection = FakeConnection { reply($0) }
        let store = AppStore()
        store.savedTabs = [:]
        store.hosts = [host]
        return (SessionMonitor(store: store, connector: { _ in connection }, relayPairing: relay), connection)
    }

    @Test func configuresFromProvisionedHostOncePerLaunch() async {
        let relay = FakeRelayPairing()
        let payload = json
        let (monitor, connection) = makeMonitor(relay: relay) {
            $0 == PushRelayProvision.readCommand ? payload : ""
        }
        await monitor.pollOnce()
        await monitor.pollOnce()
        #expect(relay.configured.count == 1)
        #expect(relay.configured.first?.0.url == "https://relay.example.com")
        #expect(relay.configured.first?.1 == "box")
        #expect(connection.commands.filter { $0 == PushRelayProvision.readCommand }.count == 1)
    }

    @Test func doesNotRetrySameURLFromAnotherHostAfterFailure() async {
        let relay = FakeRelayPairing()
        let payload = json
        let hosts = ["one", "two"].map {
            HostConfig(name: $0, hostname: $0, username: "u", keyTag: "k", tmuxSession: nil)
        }
        let connection = FakeConnection { $0 == PushRelayProvision.readCommand ? payload : "" }
        let store = AppStore()
        store.savedTabs = [:]
        store.hosts = [hosts[0]]
        let monitor = SessionMonitor(store: store, connector: { _ in connection }, relayPairing: relay)
        await monitor.pollOnce()
        relay.isConfigured = false
        relay.configuredURL = nil
        store.hosts = [hosts[1]]
        await monitor.pollOnce()
        #expect(relay.configured.count == 1)
    }

    @Test func leavesMatchingManualConfigurationAlone() async {
        let relay = FakeRelayPairing()
        relay.isConfigured = true
        relay.configuredURL = "https://relay.example.com"
        let payload = json
        let (monitor, _) = makeMonitor(relay: relay) { $0 == PushRelayProvision.readCommand ? payload : "" }
        await monitor.pollOnce()
        #expect(relay.configured.isEmpty)
    }

    @Test func replacesConfigurationWithDifferentURL() async {
        let relay = FakeRelayPairing()
        relay.isConfigured = true
        relay.configuredURL = "https://old.example.com"
        let payload = json
        let (monitor, _) = makeMonitor(relay: relay) { $0 == PushRelayProvision.readCommand ? payload : "" }
        await monitor.pollOnce()
        #expect(relay.configured.count == 1)
    }

    @Test func ignoresMalformedFile() async {
        let relay = FakeRelayPairing()
        let (monitor, _) = makeMonitor(relay: relay) {
            $0 == PushRelayProvision.readCommand
                ? #"{"url":"http://x.example.com","pairingSecret":"0123456789abcdef"}"# : ""
        }
        await monitor.pollOnce()
        #expect(relay.configured.isEmpty)
    }
}

@MainActor
struct PushRelayClientTests {
    @Test func configurePublishesNormalizedURL() async throws {
        let key = AppSettings.pushRelayURLKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let client = PushRelayClient()
        var published: [String?] = []
        let subscription = client.$configuredURL.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }
        try await client.configure(urlString: "https://relay.example.com/", pairingSecret: "0123456789abcdef")
        #expect(client.configuredURL == "https://relay.example.com")
        #expect(published == ["https://relay.example.com"])
    }
}
