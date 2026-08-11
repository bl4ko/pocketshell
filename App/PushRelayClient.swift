import Combine
import Foundation
import HerdrKit
import KeyKit
import Models
import SSHKit
import UIKit

@MainActor
final class PushRelayClient: ObservableObject {
    static let shared = PushRelayClient()

    @Published private(set) var status: String?
    @Published private(set) var isWorking = false

    private static let pairingAccount = "push-relay-pairing"
    private static let hostAccountPrefix = "push-relay-host-"
    private var deviceToken: String?

    var isConfigured: Bool {
        UserDefaults.standard.string(forKey: AppSettings.pushRelayURLKey) != nil
            && PasswordVault.get(account: Self.pairingAccount) != nil
    }

    func hasInstalledPlugin(hostID: UUID) -> Bool {
        PasswordVault.get(account: Self.hostAccountPrefix + hostID.uuidString.lowercased()) != nil
    }

    func startIfConfigured() {
        guard isConfigured else { return }
        registerWithAPNs()
    }

    func configure(urlString: String, pairingSecret newSecret: String) async throws {
        let url = try Self.validatedURL(urlString)
        let secret = newSecret.isEmpty ? PasswordVault.get(account: Self.pairingAccount) : newSecret
        guard let secret, secret.count >= 16 else { throw PushRelayError.invalidPairingSecret }
        UserDefaults.standard.set(url.absoluteString, forKey: AppSettings.pushRelayURLKey)
        PasswordVault.set(secret, account: Self.pairingAccount)
        registerWithAPNs()
        if deviceToken != nil {
            try await updateDevice(enabled: UserDefaults.standard.bool(forKey: AppSettings.agentNotifyKey))
        }
        status = "Push relay saved."
    }

    func notificationSettingChanged(_ enabled: Bool) async {
        guard isConfigured else { return }
        if enabled {
            registerWithAPNs()
        } else if deviceToken != nil {
            try? await updateDevice(enabled: false)
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }

    func receivedDeviceToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        Task {
            do {
                let enabled = UserDefaults.standard.bool(forKey: AppSettings.agentNotifyKey)
                try await updateDevice(enabled: enabled)
                status = enabled ? "This iPhone is registered for Herdr alerts." : status
                if !enabled { UIApplication.shared.unregisterForRemoteNotifications() }
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func registrationFailed(_ error: Error) {
        status = "APNs registration failed: \(error.localizedDescription)"
    }

    func report(_ error: Error) {
        status = error.localizedDescription
    }

    func installPlugin(on host: HostConfig, store: AppStore) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let endpoint = try relayURL()
            let pairingSecret = try pairingSecret()
            let account = Self.hostAccountPrefix + host.id.uuidString.lowercased()
            let hostSecret = PasswordVault.get(account: account) ?? Self.makeSecret()
            let key = try store.key(for: host)
            let connection = SSHConnection(
                host: host,
                key: key,
                knownHosts: store.knownHosts,
                hops: store.hops(for: host)
            )
            do {
                try await connection.connect()
                try await provisionHost(host, secret: hostSecret, endpoint: endpoint, pairingSecret: pairingSecret)
                for command in HerdrPushPlugin.installCommands(endpoint: endpoint, hostID: host.id, secret: hostSecret)
                {
                    _ = try await connection.exec(command)
                }
                let output = try await connection.exec(Herdr.listSessionsCommand())
                var sessions = ["default"]
                for session in Herdr.parseSessions(output).map(\.name) where !sessions.contains(session) {
                    sessions.append(session)
                }
                for session in sessions {
                    _ = try await connection.exec(HerdrPushPlugin.linkCommand(session: session))
                }
                await connection.disconnect()
            } catch {
                await connection.disconnect()
                throw error
            }
            PasswordVault.set(hostSecret, account: account)
            status = "Herdr push installed on \(host.name)."
        } catch {
            status = "\(host.name): \(error.localizedDescription)"
        }
    }

    private func registerWithAPNs() {
        #if !targetEnvironment(macCatalyst)
            UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    private func updateDevice(enabled: Bool) async throws {
        guard let deviceToken else { return }
        let request = try authorizedRequest(path: "v1/devices", method: enabled ? "POST" : "DELETE")
        try await send(request, body: ["token": deviceToken, "environment": Self.apnsEnvironment])
    }

    private func provisionHost(_ host: HostConfig, secret: String, endpoint: URL, pairingSecret: String) async throws {
        var request = URLRequest(url: endpoint.appending(path: "v1/hosts/\(host.id.uuidString.lowercased())"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(pairingSecret)", forHTTPHeaderField: "Authorization")
        try await send(request, body: ["name": host.name, "secret": secret])
    }

    private func authorizedRequest(path: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: try relayURL().appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(try pairingSecret())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest, body: [String: String]) async throws {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let message = (try? JSONDecoder().decode(RelayError.self, from: data).error) ?? "request failed"
            throw PushRelayError.server(message)
        }
    }

    private func relayURL() throws -> URL {
        guard let value = UserDefaults.standard.string(forKey: AppSettings.pushRelayURLKey) else {
            throw PushRelayError.notConfigured
        }
        return try Self.validatedURL(value)
    }

    private func pairingSecret() throws -> String {
        guard let value = PasswordVault.get(account: Self.pairingAccount) else {
            throw PushRelayError.notConfigured
        }
        return value
    }

    private static func validatedURL(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            components.scheme == "https", components.host != nil, components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else { throw PushRelayError.invalidURL }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw PushRelayError.invalidURL }
        return url
    }

    private static func makeSecret() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static var apnsEnvironment: String {
        #if DEBUG
            "sandbox"
        #else
            "production"
        #endif
    }
}

@MainActor
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushRelayClient.shared.startIfConfigured()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRelayClient.shared.receivedDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushRelayClient.shared.registrationFailed(error)
    }
}

private struct RelayError: Decodable {
    var error: String
}

private enum PushRelayError: LocalizedError {
    case invalidURL
    case invalidPairingSecret
    case notConfigured
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Use an HTTPS Cloudflare Worker URL."
        case .invalidPairingSecret: "The pairing secret must be at least 16 characters."
        case .notConfigured: "Save the push relay URL and pairing secret first."
        case .server(let message): "Push relay: \(message)"
        }
    }
}
