import HerdrKit
import SwiftUI

struct HerdrCreateRequest: Identifiable {
    let id = UUID()
    let item: HerdrNewItem
    let place: String
    let cwd: String?
}

struct HerdrSwitcherSheet: View {
    private struct Rename: Identifiable {
        let target: HerdrTarget
        let title: String
        var id: String { "\(target)" }
    }

    private struct Closing: Identifiable {
        let target: HerdrTarget
        let name: String
        var id: String { "\(target)" }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var state: HerdrState
    @State private var creating: HerdrCreateRequest?
    @State private var renaming: Rename?
    @State private var renameText = ""
    @State private var closing: Closing?
    @State private var failure: String?
    @State private var scrolledToFocus = false
    @State private var query = ""

    let controller: ConnectionController
    let hostName: String

    init(controller: ConnectionController, hostName: String) {
        self.controller = controller
        self.hostName = hostName
        state = controller.herdr
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                List {
                    if let outline = shown {
                        if !outline.needingInput.isEmpty {
                            Section {
                                ForEach(outline.needingInput) { pane in
                                    paneButton(pane, title: pane.title, detail: place(of: pane, in: outline))
                                        .id("needs-input-\(pane.paneID)")
                                }
                            } header: {
                                sectionLabel("Needs input")
                            }
                        }
                        ForEach(outline.workspaces) { workspace in
                            Section {
                                ForEach(workspace.tabs) { tab in
                                    tabRows(tab, in: workspace)
                                }
                            } header: {
                                workspaceHeader(workspace)
                            }
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading Herdr…")
                                .font(PocketshellTheme.mono(12))
                                .foregroundStyle(PocketshellTheme.muted)
                        }
                        .frame(minHeight: 56)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.insetGrouped)
                .overlay {
                    if let shown, shown.workspaces.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .task(id: outline?.focusedPaneID) {
                    guard !scrolledToFocus, let focused = outline?.focusedPaneID else { return }
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    scrolledToFocus = true
                    withAnimation { scroller.scrollTo(focused, anchor: .center) }
                }
            }
            .scrollContentBackground(.hidden)
            .searchable(
                text: $query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Workspace, tab, agent, folder"
            )
            .navigationTitle("Herdr")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(PocketshellTheme.muted)
                        Text(hostName)
                            .font(PocketshellTheme.mono(14, weight: .bold))
                            .foregroundStyle(PocketshellTheme.ink)
                            .lineLimit(1)
                        if let session = controller.herdrTarget?.session, session != "default" {
                            Text(session)
                                .font(PocketshellTheme.mono(11))
                                .foregroundStyle(PocketshellTheme.muted)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("herdr-switcher-done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    createMenu
                }
            }
            .refreshable { _ = await controller.currentHerdrSnapshot() }
            .task {
                while !Task.isCancelled {
                    _ = await controller.currentHerdrSnapshot()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .sheet(item: $creating) { request in
                HerdrCreateSheet(controller: controller, request: request) {
                    creating = nil
                    dismiss()
                }
            }
            .alert(renaming?.title ?? "", isPresented: presence($renaming)) {
                TextField("name", text: $renameText)
                    .accessibilityIdentifier("herdr-rename-field")
                Button("Rename") {
                    if let target = renaming?.target {
                        run { Herdr.renameCommand(session: $0, target: target, label: renameText) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Close \(closing?.name ?? "")? Its processes stop.", isPresented: presence($closing)
            ) {
                Button("Close", role: .destructive) {
                    if let target = closing?.target { run { Herdr.closeCommand(session: $0, target: target) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Herdr", isPresented: presence($failure)) {
                Button("OK") {}
            } message: {
                Text(failure ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .paperScreen()
    }

    private var outline: HerdrOutline? {
        state.snapshot.map(HerdrOutline.init)
    }

    private var shown: HerdrOutline? {
        outline?.filtered(by: query)
    }

    @ViewBuilder
    private func tabRows(_ tab: HerdrOutline.Tab, in workspace: HerdrOutline.Workspace) -> some View {
        if tab.panes.count == 1, let pane = tab.panes.first {
            let named = !Self.isDefaultLabel(tab.label)
            paneButton(
                pane, title: named ? tab.label : pane.title,
                detail: [named ? pane.title : nil, pane.detail].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " · "),
                tab: tab)
        } else {
            Button {
                jump { await controller.focusHerdrTab(id: tab.tabID) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: tab.zoomed ? "rectangle.inset.filled" : "rectangle.split.2x1")
                        .font(.system(size: 17))
                        .foregroundStyle(PocketshellTheme.muted)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.isDefaultLabel(tab.label) ? "Tab \(tab.label)" : tab.label)
                            .font(PocketshellTheme.mono(14, weight: .bold))
                            .foregroundStyle(PocketshellTheme.ink)
                        Text("\(tab.panes.count) panes\(tab.zoomed ? " · zoomed" : "")")
                            .font(PocketshellTheme.mono(11))
                            .foregroundStyle(PocketshellTheme.muted)
                    }
                    Spacer()
                    if tab.focused {
                        focusedMark
                    }
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("herdr-tab-\(tab.tabID)")
            .accessibilityValue(tab.focused ? "focused" : "")
            .contextMenu { tabActions(tab) }
            ForEach(tab.panes) { pane in
                paneButton(pane, title: pane.title, detail: pane.detail, indent: true)
            }
        }
    }

    private func paneButton(
        _ pane: HerdrOutline.Pane, title: String, detail: String, indent: Bool = false, tab: HerdrOutline.Tab? = nil
    ) -> some View {
        Button {
            jump { await controller.focusHerdrPane(pane.paneID) }
        } label: {
            HStack(spacing: 12) {
                HerdrStatusIcon(status: pane.status)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(PocketshellTheme.mono(15, weight: .semibold))
                        .foregroundStyle(PocketshellTheme.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let status = pane.status, status != .unknown {
                            Text(status.switcherLabel)
                                .font(PocketshellTheme.mono(11, weight: .semibold))
                                .foregroundStyle(status.switcherColor)
                        }
                        if !detail.isEmpty {
                            Text(detail)
                                .font(PocketshellTheme.mono(11))
                                .foregroundStyle(PocketshellTheme.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: 4)
                if pane.focused {
                    focusedMark
                }
            }
            .padding(.leading, indent ? 22 : 0)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(pane.status == .blocked ? PocketshellTheme.accentTint : PocketshellTheme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("herdr-pane-\(pane.paneID)")
        .accessibilityValue(pane.focused ? "focused" : "")
        .id(pane.paneID)
        .contextMenu {
            if let tab { tabActions(tab) }
            paneActions(pane)
        }
        .swipeActions(edge: .trailing) {
            Button("Close", role: .destructive) {
                closing = Closing(target: tab.map { .tab($0.tabID) } ?? .pane(pane.paneID), name: title)
            }
        }
        .swipeActions(edge: .leading) {
            Button("Split") {
                creating = HerdrCreateRequest(
                    item: .split(paneID: pane.paneID, direction: .right), place: "next to \(title)", cwd: pane.cwd)
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func paneActions(_ pane: HerdrOutline.Pane) -> some View {
        Button {
            creating = HerdrCreateRequest(
                item: .split(paneID: pane.paneID, direction: .right), place: "right of \(pane.title)", cwd: pane.cwd)
        } label: {
            Label("Split Right", systemImage: "rectangle.split.2x1")
        }
        Button {
            creating = HerdrCreateRequest(
                item: .split(paneID: pane.paneID, direction: .down), place: "below \(pane.title)", cwd: pane.cwd)
        } label: {
            Label("Split Down", systemImage: "rectangle.split.1x2")
        }
        Button {
            renameText = pane.label ?? ""
            renaming = Rename(target: .pane(pane.paneID), title: "Rename pane")
        } label: {
            Label("Rename Pane…", systemImage: "pencil")
        }
        Button(role: .destructive) {
            closing = Closing(target: .pane(pane.paneID), name: pane.title)
        } label: {
            Label("Close Pane", systemImage: "xmark")
        }
    }

    @ViewBuilder
    private func tabActions(_ tab: HerdrOutline.Tab) -> some View {
        Button {
            renameText = Self.isDefaultLabel(tab.label) ? "" : tab.label
            renaming = Rename(target: .tab(tab.tabID), title: "Rename tab")
        } label: {
            Label("Rename Tab…", systemImage: "character.cursor.ibeam")
        }
        if tab.panes.count > 1 {
            Button(role: .destructive) {
                closing = Closing(target: .tab(tab.tabID), name: "tab \(tab.label)")
            } label: {
                Label("Close Tab", systemImage: "xmark.square")
            }
        }
    }

    private func workspaceHeader(_ workspace: HerdrOutline.Workspace) -> some View {
        HStack(spacing: 8) {
            Button {
                jump { await controller.jumpToHerdrWorkspace(workspace.workspaceID) }
            } label: {
                HStack(spacing: 8) {
                    Text("\(workspace.number)")
                        .font(PocketshellTheme.mono(11, weight: .bold))
                        .foregroundStyle(workspace.focused ? Color.white : PocketshellTheme.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            workspace.focused ? PocketshellTheme.accent : PocketshellTheme.secondarySurface,
                            in: RoundedRectangle(cornerRadius: 6))
                    Text(workspace.label)
                        .font(PocketshellTheme.mono(13, weight: .bold))
                        .foregroundStyle(PocketshellTheme.ink)
                        .textCase(nil)
                        .lineLimit(1)
                    if let status = workspace.status, status != .unknown {
                        Circle()
                            .fill(status.switcherColor)
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("herdr-workspace-\(workspace.workspaceID)")
            .accessibilityValue(workspace.focused ? "focused" : "")
            Spacer()
            Menu {
                Button {
                    creating = HerdrCreateRequest(
                        item: .tab(workspaceID: workspace.workspaceID), place: "in \(workspace.label)",
                        cwd: workspaceFolder(workspace))
                } label: {
                    Label("New Tab", systemImage: "plus.rectangle")
                }
                if workspace.isGitRepository {
                    Button {
                        creating = HerdrCreateRequest(
                            item: .worktree(workspaceID: workspace.workspaceID), place: "from \(workspace.label)",
                            cwd: nil)
                    } label: {
                        Label("New Worktree", systemImage: "arrow.triangle.branch")
                    }
                }
                Button {
                    renameText = workspace.label
                    renaming = Rename(target: .workspace(workspace.workspaceID), title: "Rename workspace")
                } label: {
                    Label("Rename Workspace…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    closing = Closing(target: .workspace(workspace.workspaceID), name: "workspace \(workspace.label)")
                } label: {
                    Label("Close Workspace", systemImage: "xmark")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(PocketshellTheme.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("herdr-workspace-menu-\(workspace.workspaceID)")
        }
    }

    private var createMenu: some View {
        let focused = outline?.focusedPane
        let workspace = outline?.focusedWorkspace
        return Menu {
            if let workspace {
                Button {
                    creating = HerdrCreateRequest(
                        item: .tab(workspaceID: workspace.workspaceID), place: "in \(workspace.label)",
                        cwd: focused?.cwd ?? workspaceFolder(workspace))
                } label: {
                    Label("New Tab", systemImage: "plus.rectangle")
                }
                .accessibilityIdentifier("herdr-new-tab")
            }
            if let focused {
                Button {
                    creating = HerdrCreateRequest(
                        item: .split(paneID: focused.paneID, direction: .right), place: "right of \(focused.title)",
                        cwd: focused.cwd)
                } label: {
                    Label("Split Right", systemImage: "rectangle.split.2x1")
                }
                .accessibilityIdentifier("herdr-split-right")
                Button {
                    creating = HerdrCreateRequest(
                        item: .split(paneID: focused.paneID, direction: .down), place: "below \(focused.title)",
                        cwd: focused.cwd)
                } label: {
                    Label("Split Down", systemImage: "rectangle.split.1x2")
                }
                .accessibilityIdentifier("herdr-split-down")
            }
            Button {
                creating = HerdrCreateRequest(item: .workspace, place: "", cwd: focused?.cwd)
            } label: {
                Label("New Workspace", systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("herdr-new-workspace")
            if let workspace, workspace.isGitRepository {
                Button {
                    creating = HerdrCreateRequest(
                        item: .worktree(workspaceID: workspace.workspaceID), place: "from \(workspace.label)", cwd: nil)
                } label: {
                    Label("New Worktree", systemImage: "arrow.triangle.branch")
                }
                .accessibilityIdentifier("herdr-new-worktree")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Create in Herdr")
        .accessibilityIdentifier("herdr-create")
    }

    private var focusedMark: some View {
        Image(systemName: "eye.fill")
            .font(.system(size: 13))
            .foregroundStyle(PocketshellTheme.accent)
            .accessibilityLabel("focused")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(PocketshellTheme.mono(11, weight: .bold))
            .foregroundStyle(PocketshellTheme.waitingText)
    }

    private func place(of pane: HerdrOutline.Pane, in outline: HerdrOutline) -> String {
        let workspace = outline.workspaces.first { $0.workspaceID == pane.workspaceID }
        let tab = outline.tab(containing: pane.paneID)
        return [workspace?.label, tab.map { Self.isDefaultLabel($0.label) ? "tab \($0.label)" : $0.label }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func workspaceFolder(_ workspace: HerdrOutline.Workspace) -> String? {
        workspace.tabs.first(where: \.focused)?.panes.first?.cwd ?? workspace.tabs.first?.panes.first?.cwd
    }

    private func jump(_ action: @escaping () async -> Bool) {
        Task {
            if await action() {
                dismiss()
            } else {
                failure = "Herdr did not switch. The target may have closed."
            }
        }
    }

    private func run(_ command: @escaping (String) -> String) {
        Task {
            if let message = await controller.herdrAction(command) {
                failure = message
            }
        }
    }

    private func presence<Value>(_ binding: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
    }

    static func isDefaultLabel(_ label: String) -> Bool {
        !label.isEmpty && label.allSatisfy(\.isNumber)
    }
}

struct HerdrStatusIcon: View {
    let status: HerdrAgentStatus?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(status?.switcherColor ?? PocketshellTheme.muted)
            .shadow(color: status == .blocked ? PocketshellTheme.waiting.opacity(0.4) : .clear, radius: 4)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch status {
        case .blocked: "exclamationmark.bubble.fill"
        case .working: "circle.dashed"
        case .done: "checkmark.circle.fill"
        case .idle: "circle.fill"
        case .unknown: "questionmark.circle"
        case nil: "terminal"
        }
    }
}

struct HerdrCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.herdrAgentKindKey) private var agentKind = ""
    @State private var label = ""
    @State private var folder = ""
    @State private var branch = ""
    @State private var working = false
    @State private var failure: String?

    let controller: ConnectionController
    let request: HerdrCreateRequest
    let onCreated: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if request.item.isWorktree {
                        TextField("branch", text: $branch)
                            .accessibilityIdentifier("herdr-create-branch")
                    }
                    TextField(request.item.isSplit ? "pane name (optional)" : "name (optional)", text: $label)
                        .accessibilityIdentifier("herdr-create-name")
                    if showsFolder {
                        TextField("folder", text: $folder)
                            .accessibilityIdentifier("herdr-create-folder")
                    }
                } footer: {
                    if !request.place.isEmpty {
                        Text(request.place)
                    }
                }
                .font(PocketshellTheme.mono(14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Section {
                    Picker("Start agent", selection: $agentKind) {
                        Text("None").tag("")
                        ForEach(Herdr.agentKinds, id: \.self) { kind in
                            Text(kind).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("herdr-create-agent")
                } footer: {
                    Text("The agent starts in the new pane. Herdr shows it as soon as it is ready or asks for input.")
                }
                if let failure {
                    Section {
                        Text(failure)
                            .font(PocketshellTheme.mono(12))
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("herdr-create-error")
                    }
                }
                Section {
                    Button {
                        create()
                    } label: {
                        HStack {
                            Spacer()
                            if working {
                                ProgressView()
                            } else {
                                Text("Create")
                                    .font(PocketshellTheme.mono(15, weight: .bold))
                            }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(
                        working || (request.item.isWorktree && branch.trimmingCharacters(in: .whitespaces).isEmpty)
                    )
                    .accessibilityIdentifier("herdr-create-confirm")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { folder = request.cwd ?? "" }
        }
        .presentationDetents([.medium, .large])
        .paperScreen()
    }

    private var title: String {
        switch request.item {
        case .tab: "New Tab"
        case .split(_, .right): "Split Right"
        case .split(_, .down): "Split Down"
        case .workspace: "New Workspace"
        case .worktree: "New Worktree"
        }
    }

    private var showsFolder: Bool {
        switch request.item {
        case .tab, .workspace: true
        case .split, .worktree: false
        }
    }

    private func create() {
        working = true
        failure = nil
        Task {
            let message = await controller.createInHerdr(
                request.item, label: label, cwd: showsFolder ? folder : request.cwd, branch: branch,
                agentKind: agentKind.isEmpty ? nil : agentKind)
            working = false
            if let message {
                failure = message
            } else {
                onCreated()
            }
        }
    }
}

extension HerdrAgentStatus {
    var switcherColor: Color {
        switch self {
        case .working: PocketshellTheme.busyText
        case .blocked: PocketshellTheme.waitingText
        case .done: .blue
        case .idle: PocketshellTheme.idleText
        case .unknown: PocketshellTheme.muted
        }
    }
}
