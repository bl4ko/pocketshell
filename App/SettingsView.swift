import Models
import SwiftUI
import UniformTypeIdentifiers

enum AppSettings {
    static let terminalThemeKey = "pocketshell.terminalTheme"
    static let appLockKey = "pocketshell.appLock"
    static let agentNotifyKey = "pocketshell.agentNotify"
    static let iCloudSyncKey = "pocketshell.iCloudSync"
    static let iCloudCredentialsSyncKey = "pocketshell.iCloudCredentialsSync"
    static let tmuxTabsExpandedKey = "pocketshell.tmuxTabsExpanded"
    static let tmuxExpandedSessionsKeyPrefix = "pocketshell.tmuxExpandedSessions"
    static let collapsedTabGroupsKeyPrefix = "pocketshell.collapsedTabGroups"
    static let uiScaleKey = "pocketshell.uiScale"
    static let developerModeKey = "pocketshell.developerMode"
    static let pushRelayURLKey = "pocketshell.pushRelayURL"
}

struct ConfigDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var monitor: SessionMonitor
    @AppStorage(AppSettings.terminalThemeKey) private var themeName = TerminalTheme.defaultTheme.name
    @AppStorage(AppSettings.appLockKey) private var appLock = false
    @AppStorage(AppSettings.agentNotifyKey) private var agentNotify = false
    @AppStorage(AppSettings.iCloudSyncKey) private var iCloudSync = false
    @AppStorage(AppSettings.iCloudCredentialsSyncKey) private var iCloudCredentialsSync = false
    @AppStorage(AppSettings.developerModeKey) private var developerMode = false
    @StateObject private var pushRelay = PushRelayClient.shared
    @State private var pushRelayURL = UserDefaults.standard.string(forKey: AppSettings.pushRelayURLKey) ?? ""
    @State private var pushPairingSecret = ""
    @State private var exportDocument: ConfigDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var importResult: String?

    var body: some View {
        List {
            Section {
                Toggle("Require Face ID", isOn: $appLock)
            } header: {
                Text("Security")
            } footer: {
                Text("Locks the app after 30 seconds in background. Takes effect on next launch.")
            }
            Section {
                Toggle("Notify when agents finish", isOn: $agentNotify)
                    .onChange(of: agentNotify) { _, on in
                        if on {
                            SessionMonitor.requestAuthorization()
                            monitor.startPolling()
                        } else {
                            monitor.stopPolling()
                        }
                        Task { await pushRelay.notificationSettingChanged(on) }
                    }
            } header: {
                Text("Agents")
            } footer: {
                Text(
                    "Uses Herdr's semantic agent state when available. Foreground polling also supports tmux. Configure push below for reliable lock-screen alerts."
                )
            }
            Section {
                TextField("https://your-worker.workers.dev", text: $pushRelayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField(
                    pushRelay.isConfigured ? "Pairing secret saved" : "Pairing secret", text: $pushPairingSecret
                )
                .textInputAutocapitalization(.never)
                Button("Save and register this iPhone") {
                    Task {
                        do {
                            try await pushRelay.configure(urlString: pushRelayURL, pairingSecret: pushPairingSecret)
                            pushPairingSecret = ""
                        } catch {
                            pushRelay.report(error)
                        }
                    }
                }
                .disabled(pushRelayURL.isEmpty || pushRelay.isWorking)
                if pushRelay.isConfigured {
                    ForEach(store.hosts) { host in
                        Button("Install Herdr push on \(host.name)") {
                            Task { await pushRelay.installPlugin(on: host, store: store) }
                        }
                        .disabled(pushRelay.isWorking)
                    }
                }
                if let status = pushRelay.status {
                    Text(status)
                }
            } header: {
                Text("Reliable Herdr push")
            } footer: {
                Text(
                    "The pairing secret stays in this device's Keychain. Each host receives a separate credential over SSH."
                )
            }
            Section {
                Toggle("Sync config with iCloud Keychain", isOn: $iCloudSync)
                    .accessibilityIdentifier("settings.icloudSync")
                    .onChange(of: iCloudSync) { _, enabled in
                        store.setCloudSyncEnabled(enabled)
                    }
                Toggle("Include shared SSH key, imported keys and VNC passwords", isOn: $iCloudCredentialsSync)
                    .accessibilityIdentifier("settings.icloudCredentialsSync")
                    .disabled(!iCloudSync)
                    .onChange(of: iCloudCredentialsSync) { _, enabled in
                        store.setCredentialsSyncEnabled(enabled)
                    }
                Button("Export config…") {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    guard let data = try? encoder.encode(store.exportConfig()) else { return }
                    exportDocument = ConfigDocument(data: data)
                    exporting = true
                }
                Button("Import config…") {
                    importing = true
                }
            } header: {
                Text("Config")
            } footer: {
                if let error = store.configSyncError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text(
                        "Credential sync uses one portable PocketShell SSH key across devices. Install its public key on hosts once. Turning sync off doesn't erase credentials already received."
                    )
                }
            }
            Section("App + terminal theme") {
                ForEach(TerminalTheme.all) { theme in
                    Button {
                        themeName = theme.name
                    } label: {
                        HStack {
                            themePreview(theme)
                            Text(theme.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if theme.name == themeName {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            Section {
                Toggle("Developer Mode", isOn: $developerMode)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(
                    "Adds Copy Debug Report to the terminal menu. Reports include session and window names, but never credentials or terminal contents."
                )
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "pocketshell-config"
        ) { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard let data = try? Data(contentsOf: url),
                let config = try? JSONDecoder().decode(ConfigExport.self, from: data)
            else {
                importResult = "Import failed — not a pocketshell config file."
                return
            }
            store.applyConfig(config)
            importResult =
                "Imported \(config.hosts.count) hosts, \(config.vncHosts.count) desktops, \(config.snippets.count) snippets."
        }
        .alert(importResult ?? "", isPresented: importAlertShown) {
            Button("OK") { importResult = nil }
        }
        .paperScreen()
    }

    private var importAlertShown: Binding<Bool> {
        Binding(
            get: { importResult != nil },
            set: { if !$0 { importResult = nil } }
        )
    }

    private func themePreview(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(theme.ansi.prefix(8).enumerated()), id: \.offset) { _, hex in
                Circle()
                    .fill(color(hex))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(4)
        .background(color(theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func color(_ hex: String) -> Color {
        guard let rgb = RGBColor(hex: hex) else { return .black }
        return Color(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }
}
