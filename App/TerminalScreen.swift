import Models
import SwiftUI
import TerminalUI
import TmuxKit
import ToolbarUI
import UIKit

@MainActor
final class KeyboardObserver: ObservableObject {
    @Published var height: CGFloat = 0
    nonisolated(unsafe) private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let height = max(0, UIScreen.main.bounds.height - end.origin.y)
            Task { @MainActor [weak self] in
                withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)) {
                    self?.height = height
                }
            }
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

struct TerminalScreen: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var connection: ConnectionController
    @StateObject private var keyboard = KeyboardObserver()
    @AppStorage(AppSettings.terminalThemeKey) private var themeName = TerminalTheme.defaultTheme.name

    let host: HostConfig

    var body: some View {
        GeometryReader { proxy in
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
                    onHideKeyboard: { connection.bridge.toggleKeyboard() },
                    onPaste: { connection.bridge.paste() },
                    onCopy: { connection.bridge.copySelection() }
                )
            }
            .padding(.bottom, max(0, keyboard.height - proxy.safeAreaInsets.bottom))
        }
        .ignoresSafeArea(.keyboard)
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
    @EnvironmentObject var store: AppStore
    @ObservedObject var connection: ConnectionController
    @State private var sessions: [TmuxSession] = []
    @State private var windowsBySession: [String: [WindowDashboardItem]] = [:]

    let host: HostConfig

    var body: some View {
        NavigationStack {
            List {
                Button("Plain shell") {
                    Task { await connection.openPlainShell() }
                }
                if sessions.isEmpty, case .pickingWindow(let windows) = connection.phase {
                    Section(host.tmuxSession ?? "tmux") {
                        ForEach(windows) { window in
                            Button {
                                Task { await connection.selectWindow(window) }
                            } label: {
                                Text("\(window.index): \(window.name)")
                            }
                        }
                    }
                }
                ForEach(sessions) { session in
                    Section(session.name) {
                        ForEach(windowsBySession[session.name] ?? []) { item in
                            Button {
                                Task { await connection.jump(toSession: session.name, windowIndex: item.window.index) }
                            } label: {
                                DashboardRow(item: item)
                            }
                        }
                    }
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
        var list = await connection.tmuxSessions()
        if let saved = store.sessionOrder[host.id.uuidString] {
            list = Tmux.orderSessions(list, by: saved)
        }
        var map: [String: [WindowDashboardItem]] = [:]
        for session in list {
            map[session.name] = await connection.dashboardItems(session: session.name)
        }
        sessions = list
        windowsBySession = map
    }
}
