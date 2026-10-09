import HerdrKit
import Models
import MonitorKit
import SwiftUI
import TerminalUI
import TmuxKit
import ToolbarUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class KeyboardObserver: ObservableObject {
    @Published var height: CGFloat = 0
    private(set) var duration: Double = 0.25
    nonisolated(unsafe) private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            MainActor.assumeIsolated {
                self?.duration = duration
            }
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

// Input-view replacement can emit a hide notification for the old keyboard after
// the new one appears. The native guide tracks the keyboard that is actually visible.
private struct KeyboardLayoutProbe: UIViewRepresentable {
    let observer: KeyboardObserver

    func makeUIView(context: Context) -> KeyboardLayoutView {
        let view = KeyboardLayoutView()
        view.onHeight = { [weak observer] height in
            if observer?.height != height { observer?.height = height }
        }
        return view
    }

    func updateUIView(_ uiView: KeyboardLayoutView, context: Context) {}
}

private final class KeyboardLayoutView: UIView {
    var onHeight: ((CGFloat) -> Void)?
    private var updateScheduled = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        let marker = UIView()
        marker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(marker)
        NSLayoutConstraint.activate([
            marker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor),
            marker.widthAnchor.constraint(equalToConstant: 0),
            marker.heightAnchor.constraint(equalToConstant: 0),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let window = self.window else { return }
            let frame = self.keyboardLayoutGuide.layoutFrame
            let visible = frame.height > self.safeAreaInsets.bottom + 1
            let top = self.convert(frame, to: window).minY
            self.onHeight?(visible ? max(0, window.bounds.maxY - top) : 0)
        }
    }
}

private enum UITestFlags {
    static let keyboardResize = ProcessInfo.processInfo.environment["PS_UI_TEST_KEYBOARD_RESIZE"] == "1"
    static let resizeCount = ProcessInfo.processInfo.environment["PS_UI_TEST_RESIZE_COUNT"] == "1"
}

// Approximates UIKit's private keyboard curve 7 so the toolbar stays glued to the keyboard.
private func keyboardMotion(duration: Double) -> Animation {
    .timingCurve(0.38, 0.7, 0.125, 1, duration: duration)
}

// Animate only the visible clip and toolbar position. Terminal layout changes once,
// so keyboard motion does not reflow scrollback or send a PTY resize on every frame.
private struct KeyboardReveal: AnimatableModifier {
    let layout: CGFloat
    var animatableData: CGFloat

    init(layout: CGFloat, shown: CGFloat) {
        self.layout = layout
        animatableData = shown
    }

    func body(content: Content) -> some View {
        content.offset(y: min(0, layout - animatableData))
            .mask {
                Rectangle().padding(.bottom, max(0, animatableData - layout))
            }
    }
}

private struct KeyboardToolbarSlide: AnimatableModifier {
    let layout: CGFloat
    var animatableData: CGFloat

    init(layout: CGFloat, shown: CGFloat) {
        self.layout = layout
        animatableData = shown
    }

    func body(content: Content) -> some View {
        content.offset(y: layout - animatableData)
            .overlay(alignment: .topLeading) {
                if UITestFlags.resizeCount {
                    KeyboardMotionProbe(offset: layout - animatableData).frame(width: 1, height: 1)
                }
            }
    }
}

private struct KeyboardTarget: Equatable {
    var inset: CGFloat
    var active: Bool
}

// UI tests observe actual intermediate display offsets, not a timer or animation flag.
private struct KeyboardMotionProbe: UIViewRepresentable {
    let offset: CGFloat

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "keyboard.motion"
        view.accessibilityLabel = "Keyboard motion frames: 0"
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if view.accessibilityValue != String(Double(offset)) {
            let count = Int(view.accessibilityLabel?.split(separator: " ").last ?? "") ?? 0
            view.accessibilityLabel = "Keyboard motion frames: \(count + 1)"
            view.accessibilityValue = String(Double(offset))
        }
    }
}

struct TerminalScreen: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var connection: ConnectionController
    @ObservedObject private var bridge: TerminalBridge
    @StateObject private var keyboard = KeyboardObserver()
    @State private var testKeyboardHeight: CGFloat = UITestFlags.keyboardResize ? 300 : 0
    @State private var keyboardInset = KeyboardInset()
    @State private var shownInset: CGFloat = 0
    @AppStorage(AppSettings.terminalThemeKey) private var themeName = TerminalTheme.defaultTheme.name
    @AppStorage(AppSettings.uiScaleKey) private var uiScale = 1.0
    @State private var findTerm = ""
    @State private var findFailed = false
    @State private var attachingFile = false
    @State private var attachmentError: String?
    @FocusState private var findFocused: Bool

    let host: HostConfig
    var isActive = true
    var quickReplyOptions: [Int] = []
    var onQuickReply: (() -> Void)?

    init(
        connection: ConnectionController,
        host: HostConfig,
        isActive: Bool = true,
        quickReplyOptions: [Int] = [],
        onQuickReply: (() -> Void)? = nil
    ) {
        self.connection = connection
        self.bridge = connection.bridge
        self.host = host
        self.isActive = isActive
        self.quickReplyOptions = quickReplyOptions
        self.onQuickReply = onQuickReply
    }

    var body: some View {
        GeometryReader { proxy in
            let keyboardHeight =
                UITestFlags.keyboardResize
                ? testKeyboardHeight : max(0, keyboard.height - proxy.safeAreaInsets.bottom)
            VStack(spacing: 0) {
                statusBanner
                if connection.findVisible {
                    findBar
                }
                SSHTerminalView(
                    bridge: connection.bridge,
                    theme: TerminalTheme.named(themeName),
                    scale: uiScale,
                    multiplexerMode: connection.isMultiplexerAttached,
                    shortcutKeys: store.toolbarKeys
                )
                .focusEffectDisabled()
                .transaction { $0.animation = nil }
                .modifier(KeyboardReveal(layout: keyboardInset.layout, shown: shownInset))
                VStack(spacing: 0) {
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
                            theme: TerminalTheme.named(themeName),
                            ctrlActive: Binding(
                                get: { connection.bridge.ctrlActive },
                                set: { connection.bridge.ctrlActive = $0 }
                            ),
                            quickReplyOptions: quickReplyOptions,
                            onKey: { connection.bridge.handleToolbar($0) },
                            onHideKeyboard: {
                                connection.bridge.toggleKeyboard()
                                if UITestFlags.keyboardResize {
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
                            onAttach: {
                                let env = ProcessInfo.processInfo.environment
                                if env["PS_UI_TEST"] == "1", let content = env["PS_UI_TEST_ATTACHMENT"] {
                                    try? content.write(
                                        to: URL.documentsDirectory.appendingPathComponent(
                                            "pocketshell-attachment-test.txt"),
                                        atomically: true, encoding: .utf8)
                                }
                                attachingFile = true
                            },
                            uploadingFile: connection.isUploadingFile,
                            selectActive: connection.bridge.selectMode,
                            composeActive: connection.composerVisible,
                            shortcutsActive: bridge.shortcutsActive,
                            onShortcuts: { bridge.toggleShortcuts(category: $0) }
                        )
                    #endif
                }
                .modifier(KeyboardToolbarSlide(layout: keyboardInset.layout, shown: shownInset))
            }
            .background(Color(hexRGB: TerminalTheme.named(themeName).background))
            .padding(.bottom, keyboardInset.layout)
            .onChange(of: KeyboardTarget(inset: keyboardHeight, active: isActive), initial: true) { old, new in
                followKeyboard(new.active ? new.inset : 0, animated: old.active && new.active && old != new)
            }
        }
        .background(KeyboardLayoutProbe(observer: keyboard))
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: windowPickerShown) {
            windowPicker
        }
        .fileImporter(isPresented: $attachingFile, allowedContentTypes: [.item]) { result in
            Task {
                do {
                    try await connection.attachFile(result.get())
                } catch {
                    if (error as? CocoaError)?.code != .userCancelled {
                        attachmentError = error.localizedDescription
                    }
                }
            }
        }
        .alert(
            "File upload failed",
            isPresented: Binding(
                get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } }
            )
        ) {
            Button("OK") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
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
                banner(message, color: .orange, icon: "arrow.clockwise", retry: connection.canRetryNow)
            case .failed(let message):
                banner(message, color: .red, icon: "exclamationmark.triangle.fill")
            default:
                EmptyView()
            }
        }
    }

    private func banner(_ text: String, color: Color, icon: String, retry: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .padding(.top, 1)
            Text(text)
                .font(.caption.monospaced())
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            if retry {
                Button("Retry now") { connection.retryNow() }
                    .font(.caption)
                    .accessibilityIdentifier("reconnect-now")
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.15))
    }

    private func followKeyboard(_ inset: CGFloat, animated: Bool) {
        guard animated, !reduceMotion else {
            if keyboardInset != KeyboardInset(inset) { keyboardInset = KeyboardInset(inset) }
            if shownInset != inset { shownInset = inset }
            return
        }
        keyboardInset.move(to: inset)
        withAnimation(keyboardMotion(duration: UITestFlags.keyboardResize ? 0.25 : keyboard.duration)) {
            shownInset = inset
        } completion: {
            keyboardInset.settle(inset)
        }
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
    @State private var recent: [RecentDirectory] = []

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
                if !recent.isEmpty {
                    Section("Recent directories") {
                        ForEach(recent) { directory in
                            Button {
                                Task { await connection.openDirectory(directory.path) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(directory.name)
                                        .font(PocketshellTheme.mono(13, weight: .semibold))
                                    Text(directory.path)
                                        .font(PocketshellTheme.mono(10))
                                        .foregroundStyle(PocketshellTheme.muted)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
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
        recent = await connection.recentDirectories()
    }
}
