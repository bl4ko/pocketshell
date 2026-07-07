import Models
import SwiftUI
import TerminalUI
import TmuxKit
import ToolbarUI

struct TerminalScreen: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var connection: ConnectionController
    @AppStorage(AppSettings.terminalThemeKey) private var themeName = TerminalTheme.defaultTheme.name

    let host: HostConfig

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            SSHTerminalView(bridge: connection.bridge, theme: TerminalTheme.named(themeName))
            TerminalToolbar(
                keys: store.toolbarKeys,
                ctrlActive: Binding(
                    get: { connection.bridge.ctrlActive },
                    set: { connection.bridge.ctrlActive = $0 }
                ),
                onKey: { connection.bridge.handleToolbar($0) },
                onHideKeyboard: { connection.bridge.toggleKeyboard() }
            )
        }
        .sheet(isPresented: windowPickerShown) {
            windowPicker
        }
        .task {
            await connection.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                connection.appForegrounded()
            }
        }
    }

    private var statusBanner: some View {
        Group {
            switch connection.phase {
            case .connecting:
                banner("connecting…", color: .blue, icon: "bolt.horizontal")
            case .reconnecting(let message):
                banner(message, color: .orange, icon: "arrow.clockwise")
            case .failed(let message):
                banner(message, color: .red, icon: "exclamationmark.triangle.fill")
            default:
                EmptyView()
            }
        }
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .padding(.top, 1)
            Text(text)
                .font(.caption.monospaced())
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.15))
    }

    private var windowPickerShown: Binding<Bool> {
        Binding(
            get: {
                if case .pickingWindow = connection.phase { return true }
                return false
            },
            set: { shown in
                if !shown, case .pickingWindow = connection.phase {
                    Task { await connection.openPlainShell() }
                }
            }
        )
    }

    private var windowPicker: some View {
        WindowDashboardSheet(connection: connection, host: host)
    }
}

struct WindowDashboardSheet: View {
    @ObservedObject var connection: ConnectionController
    @State private var items: [WindowDashboardItem] = []

    let host: HostConfig

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty, case .pickingWindow(let windows) = connection.phase {
                    ForEach(windows) { window in
                        Button {
                            Task { await connection.selectWindow(window) }
                        } label: {
                            Text("\(window.index): \(window.name)")
                        }
                    }
                } else {
                    ForEach(items) { item in
                        Button {
                            Task { await connection.selectWindow(item.window) }
                        } label: {
                            DashboardRow(item: item)
                        }
                    }
                }
                Button("Plain shell") {
                    Task { await connection.openPlainShell() }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            .themedScreen()
            .task {
                await refresh()
            }
            .refreshable {
                await refresh()
            }
        }
    }

    private func refresh() async {
        guard let session = host.tmuxSession else { return }
        items = await connection.dashboardItems(session: session)
    }
}
