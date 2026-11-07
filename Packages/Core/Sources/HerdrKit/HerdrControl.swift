import Foundation

public struct HerdrOutline: Equatable, Sendable {
    public struct Pane: Equatable, Sendable, Identifiable {
        public var id: String { paneID }
        public var paneID: String
        public var tabID: String
        public var workspaceID: String
        public var title: String
        public var detail: String
        public var status: HerdrAgentStatus?
        public var focused: Bool
        public var cwd: String?
        public var label: String?
    }

    public struct Tab: Equatable, Sendable, Identifiable {
        public var id: String { tabID }
        public var tabID: String
        public var workspaceID: String
        public var label: String
        public var status: HerdrAgentStatus?
        public var focused: Bool
        public var zoomed: Bool
        public var panes: [Pane]
    }

    public struct Workspace: Equatable, Sendable, Identifiable {
        public var id: String { workspaceID }
        public var workspaceID: String
        public var number: Int
        public var label: String
        public var status: HerdrAgentStatus?
        public var focused: Bool
        public var isGitRepository: Bool
        public var tabs: [Tab]
    }

    public var workspaces: [Workspace]
    public var focusedPaneID: String?

    public init(_ snapshot: HerdrSnapshot) {
        let agents = Dictionary(snapshot.agents.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        let panes =
            snapshot.panes
            ?? snapshot.agents.map {
                HerdrPane(
                    paneID: $0.paneID, workspaceID: $0.workspaceID, tabID: $0.tabID, agent: $0.agent, label: nil,
                    cwd: nil, foregroundCwd: nil, status: $0.status, focused: $0.focused)
            }
        let tabs =
            snapshot.tabs
            ?? panes.reduce(into: [HerdrTab]()) { tabs, pane in
                guard !tabs.contains(where: { $0.tabID == pane.tabID }) else { return }
                tabs.append(
                    HerdrTab(
                        tabID: pane.tabID, workspaceID: pane.workspaceID,
                        label: String(pane.tabID.split(separator: ":").last ?? "")))
            }
        let layouts = Dictionary(
            (snapshot.layouts ?? []).map { ($0.tabID, $0) }, uniquingKeysWith: { first, _ in first })
        let focusedPaneID = snapshot.focusedPaneID ?? snapshot.agents.first(where: \.focused)?.paneID
        self.focusedPaneID = focusedPaneID

        func outlinePane(_ pane: HerdrPane) -> Pane {
            let agent = agents[pane.paneID]
            let hasAgent = agent != nil || pane.agent != nil
            let kind = agent?.displayAgent ?? pane.agent ?? agent?.agent
            let cwd = pane.foregroundCwd ?? pane.cwd
            let title =
                [agent?.name, pane.label, kind, cwd.map(Self.folderName)]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? "shell"
            let detail = [kind == title ? nil : kind, agent?.title, cwd.map(Self.shortPath)]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return Pane(
                paneID: pane.paneID, tabID: pane.tabID, workspaceID: pane.workspaceID, title: title, detail: detail,
                status: hasAgent ? agent?.status ?? pane.status : nil,
                focused: focusedPaneID.map { $0 == pane.paneID } ?? pane.focused, cwd: cwd, label: pane.label)
        }

        func outlineTab(_ tab: HerdrTab) -> Tab {
            let own = panes.filter { $0.tabID == tab.tabID }
            let layout = layouts[tab.tabID]
            let spatial = (layout?.panes ?? []).compactMap { entry in own.first { $0.paneID == entry.paneID } }
            let ordered = spatial + own.filter { pane in !spatial.contains { $0.paneID == pane.paneID } }
            let outlined = ordered.map(outlinePane)
            let agentStatus = outlined.contains { $0.status != nil } ? tab.status : nil
            return Tab(
                tabID: tab.tabID, workspaceID: tab.workspaceID, label: tab.label,
                status: agentStatus ?? Self.mostUrgent(outlined.compactMap(\.status)),
                focused: snapshot.focusedTabID.map { $0 == tab.tabID } ?? outlined.contains(where: \.focused),
                zoomed: layout?.zoomed ?? false, panes: outlined)
        }

        workspaces = snapshot.workspaces.enumerated()
            .sorted { ($0.element.number, $0.offset) < ($1.element.number, $1.offset) }
            .map(\.element)
            .map { workspace in
                let own = tabs.enumerated().filter { $0.element.workspaceID == workspace.workspaceID }
                    .sorted { ($0.element.number ?? .max, $0.offset) < ($1.element.number ?? .max, $1.offset) }
                    .map { outlineTab($0.element) }
                let hasAgent = own.contains { tab in tab.panes.contains { $0.status != nil } }
                return Workspace(
                    workspaceID: workspace.workspaceID, number: workspace.number, label: workspace.label,
                    status: hasAgent ? workspace.status : nil, focused: workspace.focused,
                    isGitRepository: workspace.worktree != nil, tabs: own)
            }
    }

    public var panes: [Pane] { workspaces.flatMap { $0.tabs.flatMap(\.panes) } }

    public var needingInput: [Pane] { panes.filter { $0.status == .blocked } }

    public var focusedPane: Pane? { panes.first { $0.paneID == focusedPaneID } }

    public func tab(containing paneID: String) -> Tab? {
        workspaces.lazy.flatMap(\.tabs).first { tab in tab.panes.contains { $0.paneID == paneID } }
    }

    public var focusedWorkspace: Workspace? {
        workspaces.first(where: \.focused)
            ?? focusedPane.flatMap { pane in workspaces.first { $0.workspaceID == pane.workspaceID } }
    }

    public var hasAgents: Bool { panes.contains { $0.status != nil } }

    public func agentsOnly() -> HerdrOutline {
        guard hasAgents else { return self }
        var result = self
        result.workspaces = workspaces.compactMap { workspace in
            var kept = workspace
            kept.tabs = workspace.tabs.compactMap { tab in
                var kept = tab
                kept.panes = tab.panes.filter { $0.status != nil }
                return kept.panes.isEmpty ? nil : kept
            }
            return kept.tabs.isEmpty ? nil : kept
        }
        return result
    }

    public func filtered(by query: String) -> HerdrOutline {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return self }
        func matches(_ fields: String?...) -> Bool {
            fields.contains { $0?.localizedStandardContains(query) ?? false }
        }
        var result = self
        result.workspaces = workspaces.compactMap { workspace in
            if matches(workspace.label) { return workspace }
            var kept = workspace
            kept.tabs = workspace.tabs.compactMap { tab in
                if matches(tab.label) { return tab }
                var kept = tab
                kept.panes = tab.panes.filter {
                    matches($0.title, $0.detail, $0.label, $0.cwd, $0.status?.rawValue, $0.status?.switcherLabel)
                }
                return kept.panes.isEmpty ? nil : kept
            }
            return kept.tabs.isEmpty ? nil : kept
        }
        return result
    }

    static func mostUrgent(_ statuses: [HerdrAgentStatus]) -> HerdrAgentStatus? {
        let order: [HerdrAgentStatus] = [.blocked, .working, .done, .idle, .unknown]
        return order.first(where: statuses.contains)
    }

    static func folderName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 2 else { return path }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }
}

public enum HerdrSplitDirection: String, Sendable, Hashable, CaseIterable {
    case right, down
}

public enum HerdrNewItem: Equatable, Sendable, Hashable {
    case tab(workspaceID: String)
    case split(paneID: String, direction: HerdrSplitDirection)
    case workspace
    case worktree(workspaceID: String)

    public var isSplit: Bool {
        if case .split = self { return true }
        return false
    }

    public var isWorktree: Bool {
        if case .worktree = self { return true }
        return false
    }
}

public enum HerdrTarget: Equatable, Sendable, Hashable {
    case workspace(String)
    case tab(String)
    case pane(String)
}

public enum HerdrActionResult: Equatable, Sendable {
    case done(paneID: String?)
    case failed(code: String, message: String)
}

extension Herdr {
    public static let agentKinds = [
        "claude", "codex", "gemini", "opencode", "copilot", "cursor", "amp", "pi", "droid", "qwen", "kimi", "kiro",
        "cline", "grok", "devin", "agy", "omp", "mastracode", "hermes", "kilo", "qodercli", "letta", "maki", "muse",
    ]

    public static func focusCommand(session: String, paneID: String, in snapshot: HerdrSnapshot) -> String {
        let outline = HerdrOutline(snapshot)
        guard let tab = outline.tab(containing: paneID) else {
            return zoomCommand(session: session, paneID: paneID, on: true)
        }
        if let pane = tab.panes.first(where: { $0.paneID == paneID }), pane.status != nil {
            return focusAgentCommand(session: session, paneID: paneID, tabID: tab.tabID)
        }
        if tab.panes.count <= 1 {
            return focusTabCommand(session: session, tabID: tab.tabID)
        }
        let zoomIn = zoomCommand(session: session, paneID: paneID, on: true)
        return tab.zoomed ? zoomIn : "\(zoomIn) && \(zoomCommand(session: session, paneID: paneID, on: false))"
    }

    public static func zoomCommand(session: String, paneID: String, on: Bool) -> String {
        "\(commandPrefix(session: session)) pane zoom \(shellQuote(paneID)) \(on ? "--on" : "--off")"
    }

    public static func zoomTarget(in snapshot: HerdrSnapshot) -> (paneID: String, tabID: String)? {
        let outline = HerdrOutline(snapshot)
        guard let paneID = outline.focusedPaneID, let tab = outline.tab(containing: paneID), tab.panes.count > 1,
            !tab.zoomed
        else { return nil }
        return (paneID, tab.tabID)
    }

    public static func unzoomCommands(session: String, tabIDs: Set<String>, in snapshot: HerdrSnapshot) -> [String] {
        (snapshot.layouts ?? []).filter { tabIDs.contains($0.tabID) && $0.zoomed }.compactMap { layout in
            (layout.focusedPaneID ?? layout.panes.first?.paneID).map {
                zoomCommand(session: session, paneID: $0, on: false)
            }
        }
    }

    public static func createCommand(
        session: String, item: HerdrNewItem, label: String = "", cwd: String? = nil, branch: String = ""
    ) -> String {
        var arguments: [String]
        switch item {
        case .tab(let workspaceID):
            arguments = ["tab", "create", "--workspace", shellQuote(workspaceID)]
        case .split(let paneID, let direction):
            arguments = ["pane", "split", shellQuote(paneID), "--direction", direction.rawValue]
        case .workspace:
            arguments = ["workspace", "create"]
        case .worktree(let workspaceID):
            arguments = ["worktree", "create", "--workspace", shellQuote(workspaceID)]
            let branch = branch.trimmingCharacters(in: .whitespaces)
            if !branch.isEmpty { arguments += ["--branch", shellQuote(branch)] }
        }
        if !item.isWorktree, let cwd = cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            arguments += ["--cwd", shellQuote(cwd)]
        }
        let label = label.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty, !item.isSplit {
            arguments += ["--label", shellQuote(label)]
        }
        return action("\(commandPrefix(session: session)) \(arguments.joined(separator: " ")) --focus")
    }

    public static func startAgentCommand(session: String, name: String, kind: String, paneID: String) -> String {
        action(
            "\(commandPrefix(session: session)) agent start \(shellQuote(name)) --kind \(shellQuote(kind)) --pane \(shellQuote(paneID))"
        )
    }

    public static func agentName(kind: String, taken: [String]) -> String {
        let base = String(
            kind.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(28))
        let stem = base.first?.isLetter == true ? base : "agent"
        let used = Set(taken)
        var name = stem
        var number = 1
        while used.contains(name) {
            number += 1
            name = "\(stem)-\(number)"
        }
        return name
    }

    public static func agentStarted(_ result: HerdrActionResult) -> Bool {
        switch result {
        case .done: true
        case .failed(let code, _): code == "agent_not_ready"
        }
    }

    public static func renameCommand(session: String, target: HerdrTarget, label: String) -> String {
        let label = label.trimmingCharacters(in: .whitespaces)
        let prefix = commandPrefix(session: session)
        switch target {
        case .workspace(let id):
            return action("\(prefix) workspace rename \(shellQuote(id)) \(shellQuote(label))")
        case .tab(let id):
            return action("\(prefix) tab rename \(shellQuote(id)) \(shellQuote(label))")
        case .pane(let id):
            return action("\(prefix) pane rename \(shellQuote(id)) \(label.isEmpty ? "--clear" : shellQuote(label))")
        }
    }

    public static func closeCommand(session: String, target: HerdrTarget) -> String {
        let prefix = commandPrefix(session: session)
        switch target {
        case .workspace(let id): return action("\(prefix) workspace close \(shellQuote(id))")
        case .tab(let id): return action("\(prefix) tab close \(shellQuote(id))")
        case .pane(let id): return action("\(prefix) pane close \(shellQuote(id))")
        }
    }

    public static func parseActionResult(_ output: String) -> HerdrActionResult {
        let lines = output.split(whereSeparator: \.isNewline).reversed()
        for line in lines {
            guard let envelope = decode(ActionEnvelope.self, from: String(line)) else { continue }
            if let error = envelope.error {
                return .failed(code: error.code, message: error.message)
            }
            if let result = envelope.result {
                return .done(paneID: result.rootPane?.paneID ?? result.pane?.paneID ?? result.agent?.paneID)
            }
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(code: "unreadable", message: text.isEmpty ? "Herdr returned nothing." : text)
    }

    public static func configCommand() -> String {
        #"cat "${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}" 2>/dev/null || true"#
    }

    public static func sidebarToggleKeys(config: String) -> [UInt8]? {
        var section = ""
        var keys: [String: String] = [:]
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            guard section == "keys", let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"") {
                keys[name] = String(rest.dropFirst().prefix { $0 != "\"" })
            } else {
                keys[name] = String(rest.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
            }
        }
        let toggle = (keys["toggle_sidebar"] ?? "prefix+b").lowercased()
        guard toggle.hasPrefix("prefix+"), let prefix = keyBytes(keys["prefix"] ?? "ctrl+b"),
            let key = keyBytes(String(toggle.dropFirst("prefix+".count))), key.count == 1, key[0] >= 0x20
        else { return nil }
        return prefix + key
    }

    public static func sidebarExpanded(screen: String) -> Bool {
        guard let first = screen.split(whereSeparator: \.isNewline).first else { return false }
        return first.trimmingCharacters(in: .whitespaces).hasPrefix("spaces") && first.contains("│")
    }

    static func action(_ command: String) -> String {
        "\(command) 2>&1 || true"
    }

    private static func keyBytes(_ spec: String) -> [UInt8]? {
        let spec = spec.lowercased()
        if spec == "esc" { return [0x1b] }
        if spec.hasPrefix("ctrl+"), let letter = spec.dropFirst("ctrl+".count).first, spec.count == 6,
            let ascii = letter.asciiValue, letter.isLetter
        {
            return [ascii & 0x1f]
        }
        if spec.count == 1, let ascii = spec.first?.asciiValue, ascii >= 0x20, ascii < 0x7f {
            return [ascii]
        }
        return nil
    }
}

private struct ActionEnvelope: Decodable {
    struct PaneReference: Decodable {
        var paneID: String

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
        }
    }

    struct Result: Decodable {
        var rootPane: PaneReference?
        var pane: PaneReference?
        var agent: PaneReference?

        enum CodingKeys: String, CodingKey {
            case rootPane = "root_pane"
            case pane, agent
        }
    }

    struct Failure: Decodable {
        var code: String
        var message: String
    }

    var result: Result?
    var error: Failure?
}
