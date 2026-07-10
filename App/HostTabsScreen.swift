import Models
import MonitorKit
import SwiftUI
import TmuxKit
import UserNotifications

struct TerminalTab: Identifiable {
    let id = UUID()
    let controller: ConnectionController
    var name: String?
}

struct TabJumpItem: Identifiable {
    let id: UUID
    let label: String
    let status: AgentStatus?
    let preview: String
    let selected: Bool
}

struct HostTabsScreen: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var router = NotificationRouter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tabs: [TerminalTab] = []
    @State private var selectedTab: UUID?
    @State private var tabStatuses: [UUID: AgentStatus] = [:]
    @State private var tabTracker = AgentActivityTracker()
    @State private var showSnippets = false
    @State private var showTmuxJump = false
    @State private var showFiles = false
    @State private var showForward = false
    @State private var addingSnippet = false
    @State private var editingSnippet: Snippet?
    @State private var renamingTab: UUID?
    @State private var renameText = ""

    let host: HostConfig

    var body: some View {
        VStack(spacing: 0) {
            if tabs.count > 1 {
                tabStrip
            }
            ZStack {
                ForEach(tabs) { tab in
                    TerminalScreen(connection: tab.controller, host: host)
                        .opacity(tab.id == selectedTab ? 1 : 0)
                        .allowsHitTesting(tab.id == selectedTab)
                }
            }
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTmuxJump = true
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showFiles = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    Button {
                        showForward = true
                    } label: {
                        Label("Port forward", systemImage: "network")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSnippets = true
                } label: {
                    Image(systemName: "text.badge.plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addTab()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
            }
        }
        .sheet(isPresented: $showSnippets) {
            snippetPicker
        }
        .sheet(isPresented: $showTmuxJump) {
            TmuxJumpSheet(controller: activeController, tabItems: tabJumpItems, orderKey: host.id.uuidString) { id in
                selectedTab = id
            }
        }
        .sheet(isPresented: $showFiles) {
            FileBrowserView(controller: activeController)
        }
        .sheet(isPresented: $showForward) {
            PortForwardSheet(controller: activeController)
        }
        .onAppear {
            if tabs.isEmpty {
                restoreTabs()
            }
            consumePendingTarget()
        }
        .onChange(of: router.pending) { _, _ in
            consumePendingTarget()
        }
        .onDisappear {
            for tab in tabs {
                Task { await tab.controller.stop() }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                pollTabs()
            }
        }
        .themedScreen()
    }

    private var activeController: ConnectionController? {
        tabs.first { $0.id == selectedTab }?.controller
    }

    private var tabJumpItems: [TabJumpItem] {
        tabs.enumerated().map { index, tab in
            TabJumpItem(
                id: tab.id,
                label: tab.name ?? "tab \(index + 1)",
                status: tabStatuses[tab.id],
                preview: Tmux.previewLines(tab.controller.bridge.visibleText(), count: 1),
                selected: tab.id == selectedTab
            )
        }
    }

    private func makeController() -> ConnectionController {
        ConnectionController(
            host: host,
            key: (try? store.key(for: host)) ?? .software(.init()),
            knownHosts: store.knownHosts
        )
    }

    private func addTab() {
        let controller = makeController()
        let tab = TerminalTab(controller: controller)
        controller.onExit = { closeTab(id: tab.id) }
        tabs.append(tab)
        selectedTab = tab.id
        persistTabs()
    }

    private func restoreTabs() {
        let records = store.savedTabs[host.id.uuidString] ?? []
        guard !records.isEmpty else {
            addTab()
            return
        }
        for record in records {
            let controller = makeController()
            if let session = record.tmuxSession {
                controller.preset(session: session, windowIndex: record.windowIndex)
            } else {
                controller.presetPlain()
            }
            let tab = TerminalTab(controller: controller, name: record.name)
            controller.onExit = { closeTab(id: tab.id) }
            tabs.append(tab)
        }
        selectedTab = tabs.first?.id
    }

    private func consumePendingTarget() {
        guard let target = router.pending, target.hostID == host.id else { return }
        router.pending = nil
        guard let session = target.session else { return }
        if let tab = tabs.first(where: { $0.controller.tmuxTarget?.session == session }) {
            selectedTab = tab.id
            Task { await tab.controller.jump(toSession: session, windowIndex: target.windowIndex) }
        } else {
            let controller = makeController()
            controller.preset(session: session, windowIndex: target.windowIndex)
            let tab = TerminalTab(controller: controller)
            controller.onExit = { closeTab(id: tab.id) }
            tabs.append(tab)
            selectedTab = tab.id
            persistTabs()
        }
    }

    private func closeTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        Task { await tab.controller.stop() }
        tabs.removeAll { $0.id == id }
        tabStatuses[id] = nil
        if selectedTab == id {
            selectedTab = tabs.last?.id
        }
        persistTabs()
        if tabs.isEmpty {
            dismiss()
        }
    }

    private func persistTabs() {
        let records = tabs.map { tab in
            let target = tab.controller.tmuxTarget
            return TabRecord(name: tab.name, tmuxSession: target?.session, windowIndex: target?.windowIndex)
        }
        if store.savedTabs[host.id.uuidString] != records {
            store.savedTabs[host.id.uuidString] = records
        }
    }

    private func pollTabs() {
        var samples: [AgentActivityTracker.Sample] = []
        for (index, tab) in tabs.enumerated() {
            let status = AgentStatus.detectAgent(tab.controller.bridge.visibleText())
            tabStatuses[tab.id] = status
            guard let status, !tab.controller.isTmuxAttached else { continue }
            samples.append(.init(
                key: "tab-\(tab.id.uuidString)",
                title: "\(host.name) \(tab.name ?? "tab \(index + 1)")",
                status: status
            ))
        }
        let transitions = tabTracker.update(samples)
        persistTabs()
        guard UserDefaults.standard.bool(forKey: AppSettings.agentNotifyKey) else { return }
        for transition in transitions {
            let content = UNMutableNotificationContent()
            content.title = transition.status == .waiting ? "Agent needs input" : "Agent finished"
            content.body = transition.title
            content.sound = .default
            content.userInfo = ["hostID": host.id.uuidString]
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "\(transition.key)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            ))
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    HStack(spacing: 5) {
                        if let status = tabStatuses[tab.id] {
                            Circle()
                                .fill(statusColor(status))
                                .frame(width: 6, height: 6)
                        }
                        Text(tab.name ?? "\(index + 1)")
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        tab.id == selectedTab
                            ? Color.accentColor.opacity(0.35)
                            : Color.secondary.opacity(0.15)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        selectedTab = tab.id
                    }
                    .contextMenu {
                        Button("Rename Tab") {
                            renameText = tab.name ?? ""
                            renamingTab = tab.id
                        }
                        Button("Close Tab", role: .destructive) {
                            closeTab(id: tab.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.thinMaterial)
        .alert("Rename tab", isPresented: renameAlertShown) {
            TextField("name", text: $renameText)
            Button("Save") { applyRename() }
            Button("Cancel", role: .cancel) { renamingTab = nil }
        }
    }

    private var renameAlertShown: Binding<Bool> {
        Binding(
            get: { renamingTab != nil },
            set: { if !$0 { renamingTab = nil } }
        )
    }

    private func applyRename() {
        guard let id = renamingTab,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        tabs[index].name = trimmed.isEmpty ? nil : trimmed
        renamingTab = nil
        persistTabs()
    }

    private func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .busy: .orange
        case .waiting: .purple
        case .idle: .green
        }
    }

    private var snippetPicker: some View {
        NavigationStack {
            List {
                ForEach(terminalSnippets) { snippet in
                    Button {
                        activeController?.sendText(snippet.command + "\n")
                        showSnippets = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.name)
                                .foregroundStyle(.primary)
                            Text(snippet.command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            store.snippets.removeAll { $0.id == snippet.id }
                        }
                        Button("Edit") {
                            editingSnippet = snippet
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button("Edit") { editingSnippet = snippet }
                        Button("Delete", role: .destructive) {
                            store.snippets.removeAll { $0.id == snippet.id }
                        }
                    }
                }
            }
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addingSnippet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay {
                if terminalSnippets.isEmpty {
                    ContentUnavailableView {
                        Label("No snippets", systemImage: "text.badge.plus")
                    } description: {
                        Text("Tap + to save a command. Tapping a snippet types it into the terminal.")
                    } actions: {
                        Button("Add Snippet") { addingSnippet = true }
                    }
                }
            }
            .sheet(isPresented: $addingSnippet) {
                SnippetFormView(snippet: nil)
            }
            .sheet(item: $editingSnippet) { snippet in
                SnippetFormView(snippet: snippet)
            }
            .themedScreen()
        }
        .presentationDetents([.medium, .large])
    }

    private var terminalSnippets: [Snippet] {
        store.snippets
            .filter { $0.runMode == .typeIntoTerminal && ($0.hostID == nil || $0.hostID == host.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }
}

struct TmuxJumpSheet: View {
    private enum Prompt: Identifiable {
        case newSession
        case renameSession(String)
        case renameWindow(session: String, index: Int)

        var id: String {
            switch self {
            case .newSession: "new"
            case .renameSession(let name): "rs-\(name)"
            case .renameWindow(let session, let index): "rw-\(session)-\(index)"
            }
        }

        var title: String {
            switch self {
            case .newSession: "New tmux session"
            case .renameSession: "Rename session"
            case .renameWindow: "Rename window"
            }
        }
    }

    private enum KillTarget {
        case session(String)
        case window(session: String, index: Int, name: String)

        var confirmTitle: String {
            switch self {
            case .session(let name):
                "Delete tmux session \(name)? Kills all its windows."
            case .window(_, _, let name):
                "Delete window \(name)? Kills its shell."
            }
        }
    }

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [TmuxSession] = []
    @State private var windowsBySession: [String: [WindowDashboardItem]] = [:]
    @State private var expandedSessions: Set<String> = []
    @State private var loaded = false
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var killTarget: KillTarget?
    @State private var choosingRenameWindow = false

    let controller: ConnectionController?
    var tabItems: [TabJumpItem] = []
    var orderKey: String?
    var onSelectTab: ((UUID) -> Void)?

    private var attached: Bool {
        controller?.isTmuxAttached ?? false
    }

    private var currentSession: String? {
        controller?.tmuxTarget?.session
    }

    var body: some View {
        NavigationStack {
            List {
                if tabItems.count > 1 {
                    Section("Tabs") {
                        ForEach(tabItems) { item in
                            Button {
                                onSelectTab?(item.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        if let status = item.status {
                                            Circle()
                                                .fill(tabStatusColor(status))
                                                .frame(width: 8, height: 8)
                                        }
                                        Text(item.label)
                                            .font(.subheadline.weight(.medium))
                                        if let status = item.status {
                                            Text(status.label)
                                                .font(.caption2)
                                                .foregroundStyle(tabStatusColor(status))
                                        }
                                        if item.selected {
                                            Spacer()
                                            Image(systemName: "eye")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if !item.preview.isEmpty {
                                        Text(item.preview)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                if !sessions.isEmpty {
                    Section {
                        ForEach(sessions) { session in
                            DisclosureGroup(isExpanded: expandedBinding(session.name)) {
                                ForEach(windowsBySession[session.name] ?? []) { item in
                                    Button {
                                        jump(toSession: session.name, windowIndex: item.window.index)
                                    } label: {
                                        DashboardRow(item: item)
                                    }
                                    .contextMenu {
                                        Button("Rename…") {
                                            promptText = item.window.name
                                            prompt = .renameWindow(session: session.name, index: item.window.index)
                                        }
                                        Button("Delete", role: .destructive) {
                                            killTarget = .window(session: session.name, index: item.window.index, name: item.window.name)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button("Delete", role: .destructive) {
                                            killTarget = .window(session: session.name, index: item.window.index, name: item.window.name)
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button("Rename") {
                                            promptText = item.window.name
                                            prompt = .renameWindow(session: session.name, index: item.window.index)
                                        }
                                        .tint(.blue)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(session.name)
                                        .font(.subheadline.weight(.medium))
                                    Text("\(session.windows)w")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if session.attached {
                                        Image(systemName: "eye")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contextMenu {
                                    Button("Attach") {
                                        jump(toSession: session.name, windowIndex: nil)
                                    }
                                    Button("Rename…") {
                                        promptText = session.name
                                        prompt = .renameSession(session.name)
                                    }
                                    Button("Delete", role: .destructive) {
                                        killTarget = .session(session.name)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    killTarget = .session(session.name)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Rename") {
                                    promptText = session.name
                                    prompt = .renameSession(session.name)
                                }
                                .tint(.blue)
                            }
                        }
                        .onMove { from, to in
                            sessions.move(fromOffsets: from, toOffset: to)
                            if let orderKey {
                                store.sessionOrder[orderKey] = sessions.map(\.name)
                            }
                        }
                    } header: {
                        Text("Sessions")
                    } footer: {
                        Text("Tap window re-attaches this tab. Swipe row to rename/delete, drag session to reorder.")
                    }
                }
                if attached {
                    Section("Quick") {
                        Button("Next window") {
                            controller?.sendText(Tmux.nextWindowKeys)
                            dismiss()
                        }
                        Button("Previous window") {
                            controller?.sendText(Tmux.previousWindowKeys)
                            dismiss()
                        }
                        Button("Next pane") {
                            controller?.sendText(Tmux.nextPaneKeys)
                            dismiss()
                        }
                        Button("Zoom pane") {
                            controller?.sendText(Tmux.zoomPaneKeys)
                            dismiss()
                        }
                        Button("New window") {
                            controller?.sendText(Tmux.newWindowKeys)
                            dismiss()
                        }
                        Button("Split side by side") {
                            controller?.sendText(Tmux.splitHorizontalKeys)
                            dismiss()
                        }
                        Button("Split stacked") {
                            controller?.sendText(Tmux.splitVerticalKeys)
                            dismiss()
                        }
                        Button("Rename window…") {
                            choosingRenameWindow = true
                        }
                        Button("Rename session…") {
                            guard let currentSession else { return }
                            promptText = currentSession
                            prompt = .renameSession(currentSession)
                        }
                        Button("Delete window…", role: .destructive) {
                            guard let currentSession,
                                  let active = (windowsBySession[currentSession] ?? []).first(where: { $0.window.active })
                            else { return }
                            killTarget = .window(session: currentSession, index: active.window.index, name: active.window.name)
                        }
                        Button("Delete session…", role: .destructive) {
                            guard let currentSession else { return }
                            killTarget = .session(currentSession)
                        }
                    }
                }
                Section {
                    Button("New session…") {
                        promptText = ""
                        prompt = .newSession
                    }
                }
                if loaded && sessions.isEmpty {
                    Text("No tmux sessions found")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("tmux")
            .presentationDetents([.medium, .large])
            .task {
                await load()
            }
            .alert(prompt?.title ?? "", isPresented: promptShown) {
                TextField("name", text: $promptText)
                Button("OK") { applyPrompt() }
                Button("Cancel", role: .cancel) { prompt = nil }
            }
            .confirmationDialog(
                killTarget?.confirmTitle ?? "",
                isPresented: killShown,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { applyKill() }
                Button("Cancel", role: .cancel) { killTarget = nil }
            }
            .confirmationDialog(
                "Rename which window?",
                isPresented: $choosingRenameWindow,
                titleVisibility: .visible
            ) {
                ForEach(windowsBySession[currentSession ?? ""] ?? []) { item in
                    Button("\(item.window.index): \(item.window.name)\(item.window.active ? " (current)" : "")") {
                        promptText = item.window.name
                        prompt = .renameWindow(session: currentSession ?? "", index: item.window.index)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .themedScreen()
        }
    }

    private var promptShown: Binding<Bool> {
        Binding(
            get: { prompt != nil },
            set: { if !$0 { prompt = nil } }
        )
    }

    private var killShown: Binding<Bool> {
        Binding(
            get: { killTarget != nil },
            set: { if !$0 { killTarget = nil } }
        )
    }

    private func applyPrompt() {
        guard let prompt else { return }
        self.prompt = nil
        let name = promptText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let controller = controller
        switch prompt {
        case .newSession:
            Task { await controller?.createTmuxSession(named: name) }
            dismiss()
        case .renameSession(let old):
            if let orderKey, var saved = store.sessionOrder[orderKey], let index = saved.firstIndex(of: old) {
                saved[index] = name
                store.sessionOrder[orderKey] = saved
            }
            Task {
                await controller?.renameTmuxSession(from: old, to: name)
                await load()
            }
        case .renameWindow(let session, let index):
            Task {
                await controller?.renameTmuxWindow(session: session, windowIndex: index, name: name)
                await load()
            }
        }
    }

    private func applyKill() {
        guard let killTarget else { return }
        self.killTarget = nil
        let controller = controller
        switch killTarget {
        case .session(let name):
            let isCurrent = name == currentSession
            Task {
                await controller?.killTmuxSession(named: name)
                if isCurrent {
                    dismiss()
                } else {
                    await load()
                }
            }
        case .window(let session, let index, _):
            Task {
                await controller?.killTmuxWindow(session: session, windowIndex: index)
                await load()
            }
        }
    }

    private func jump(toSession session: String, windowIndex: Int?) {
        let controller = controller
        Task { await controller?.jump(toSession: session, windowIndex: windowIndex) }
        dismiss()
    }

    private func tabStatusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .busy: .orange
        case .waiting: .purple
        case .idle: .green
        }
    }

    private func expandedBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { expandedSessions.contains(name) },
            set: { expanded in
                if expanded {
                    expandedSessions.insert(name)
                } else {
                    expandedSessions.remove(name)
                }
            }
        )
    }

    private func load() async {
        guard let controller else {
            loaded = true
            return
        }
        var list = await controller.tmuxSessions()
        if let orderKey, let saved = store.sessionOrder[orderKey], !saved.isEmpty {
            let positions = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($1, $0) })
            list = list.enumerated()
                .sorted {
                    (positions[$0.element.name] ?? saved.count + $0.offset)
                        < (positions[$1.element.name] ?? saved.count + $1.offset)
                }
                .map(\.element)
        }
        sessions = list
        var map: [String: [WindowDashboardItem]] = [:]
        for session in sessions {
            map[session.name] = await controller.dashboardItems(session: session.name)
        }
        windowsBySession = map
        if expandedSessions.isEmpty {
            let initial = currentSession ?? sessions.first { $0.attached }?.name ?? sessions.first?.name
            if let initial {
                expandedSessions = [initial]
            }
        }
        loaded = true
    }
}
