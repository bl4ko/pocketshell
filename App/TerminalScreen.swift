import HerdrKit
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
            Task { @MainActor [weak self] in
                let screenHeight =
                    UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }
                    .max() ?? 0
                self?.height = max(0, screenHeight - end.origin.y)
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
    @State private var testKeyboardHeight: CGFloat =
        ProcessInfo.processInfo.environment["PS_UI_TEST_KEYBOARD_RESIZE"] == "1" ? 300 : 0
    @AppStorage(AppSettings.terminalThemeKey) private var themeName = TerminalTheme.defaultTheme.name
    @AppStorage(AppSettings.uiScaleKey) private var uiScale = 1.0
    @State private var findTerm = ""
    @State private var findFailed = false
    @FocusState private var findFocused: Bool

    let host: HostConfig
    var isActive = true
    var quickReplyOptions: [Int] = []
    var onQuickReply: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                statusBanner
                if connection.findVisible {
                    findBar
                }
                SSHTerminalView(
                    bridge: connection.bridge,
                    theme: TerminalTheme.named(themeName),
                    scale: uiScale,
                    multiplexerMode: connection.isMultiplexerAttached
                )
                .focusEffectDisabled()
                if connection.composerVisible {
                    ComposerBar(
                        text: $connection.composerDraft,
                        theme: TerminalTheme.named(themeName),
                        onSend: { connection.bridge.sendComposed(connection.composerDraft) },
                        onClose: {
                            connection.composerVisible = false
                            connection.bridge.setTerminalFocused(true)
                        }
                    )
                }
                #if !targetEnvironment(macCatalyst)
                    TerminalToolbar(
                        keys: store.toolbarKeys,
                        theme: TerminalTheme.named(themeName),
                        ctrlActive: Binding(
                            get: { connection.bridge.ctrlActive },
                            set: { connection.bridge.ctrlActive = $0 }
                        ),
                        quickReplyOptions: quickReplyOptions,
                        onKey: { connection.bridge.handleToolbar($0) },
                        onHideKeyboard: {
                            connection.bridge.toggleKeyboard()
                            if ProcessInfo.processInfo.environment["PS_UI_TEST_KEYBOARD_RESIZE"] == "1" {
                                testKeyboardHeight = testKeyboardHeight == 0 ? 300 : 0
                            }
                        },
                        onPaste: { connection.bridge.paste() },
                        onCopy: { connection.bridge.copySelection() },
                        onToggleSelect: { connection.bridge.toggleSelectMode() },
                        onCompose: {
                            connection.composerVisible.toggle()
                            if !connection.composerVisible {
                                connection.bridge.setTerminalFocused(true)
                            }
                        },
                        selectActive: connection.bridge.selectMode,
                        composeActive: connection.composerVisible,
                        multiplexer: connection.isMultiplexerAttached
                    )
                #endif
            }
            .padding(
                .bottom,
                isActive
                    ? max(testKeyboardHeight, max(0, keyboard.height - proxy.safeAreaInsets.bottom))
                    : 0
            )
        }
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: windowPickerShown) {
            windowPicker
        }
        .task {
            connection.bridge.userSentInput = { onQuickReply?() }
            await connection.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                connection.appForegrounded()
            }
        }
    }

    private var findBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(PocketshellTheme.secondary)
            TextField("find in scrollback", text: $findTerm)
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(findFailed ? Color.red : PocketshellTheme.ink)
                .focused($findFocused)
                .onSubmit { runFind(forward: true) }
                .onChange(of: findTerm) { _, term in
                    findFailed = false
                    guard !term.isEmpty else {
                        connection.bridge.clearFind()
                        return
                    }
                    // A fresh forward search starts at row 0 of the scrollback, which
                    // on a long buffer lands thousands of lines from the prompt; a
                    // reverse search starts at the bottom, on the newest match.
                    runFind(forward: false, fromStart: true)
                }
                .accessibilityIdentifier("find-field")
            if findFailed {
                Text("no match")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.red)
            }
            Button {
                runFind(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .accessibilityIdentifier("find-previous")
            Button {
                runFind(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .accessibilityIdentifier("find-next")
            Button {
                closeFind()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityIdentifier("find-close")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(PocketshellTheme.paper)
        .onAppear { findFocused = true }
    }

    private func runFind(forward: Bool, fromStart: Bool = false) {
        if fromStart {
            connection.bridge.clearFind()
        }
        findFailed = !connection.bridge.find(findTerm, forward: forward)
    }

    private func closeFind() {
        connection.bridge.clearFind()
        connection.findVisible = false
        findFailed = false
        connection.bridge.setTerminalFocused(true)
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
                if case .pickingSession = connection.phase { return true }
                return false
            },
            set: { shown in
                if !shown, case .pickingSession = connection.phase {
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
    @State private var herdrSessions: [HerdrSession] = []
    @State private var windowsBySession: [String: [WindowDashboardItem]] = [:]

    let host: HostConfig

    var body: some View {
        NavigationStack {
            List {
                Button("Plain shell") {
                    Task { await connection.openPlainShell() }
                }
                if !herdrSessions.isEmpty {
                    Section("Herdr") {
                        ForEach(herdrSessions) { session in
                            Button(session.isDefault ? "Default session" : session.name) {
                                Task { await connection.selectHerdrSession(session) }
                            }
                        }
                    }
                }
                if sessions.isEmpty,
                    case .pickingSession(let windows, _) = connection.phase
                {
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
                                Task {
                                    await connection.jump(
                                        toSession: session.name, windowIndex: item.window.index,
                                        windowID: item.window.windowID)
                                }
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
        if case .pickingSession(_, let initialHerdrSessions) = connection.phase {
            herdrSessions = initialHerdrSessions
        } else {
            herdrSessions = await connection.herdrSessions()
        }
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
