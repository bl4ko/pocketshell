import Foundation
import HerdrKit
import Models
import MonitorKit
import TmuxKit

public struct AppTab: Equatable, Sendable {
    public enum Backend: Equatable, Sendable {
        case shell
        case tmux(session: String, windowIndex: Int?, windowID: String?)
        case herdr(session: String, workspaceID: String?)
    }

    public var id: String
    public var label: String
    public var backend: Backend
    public var status: AgentStatus?
    public var unseen: Bool
    public var isCurrent: Bool

    public init(
        id: String, label: String, backend: Backend, status: AgentStatus? = nil, unseen: Bool = false,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.label = label
        self.backend = backend
        self.status = status
        self.unseen = unseen
        self.isCurrent = isCurrent
    }
}

public struct BrainSession: Equatable, Sendable, Identifiable {
    public enum Place: Equatable, Sendable {
        case tab(id: String, backend: AppTab.Backend)
        case tmuxSession(name: String)
        case tmuxWindow(session: String, windowIndex: Int, windowID: String, paneID: String)
        case herdrWorkspace(session: String, workspaceID: String)
        case herdrTab(session: String, workspaceID: String, tabID: String)
        case herdrPane(session: String, workspaceID: String, tabID: String, paneID: String)
    }

    public enum Kind: String, Sendable, CaseIterable {
        case tab
        case tmuxSession = "tmux_session"
        case tmuxWindow = "tmux_window"
        case herdrWorkspace = "herdr_workspace"
        case herdrTab = "herdr_tab"
        case herdrPane = "herdr_pane"

        var spoken: String {
            switch self {
            case .tab: "tab"
            case .tmuxSession: "tmux session"
            case .tmuxWindow: "tmux window"
            case .herdrWorkspace: "Herdr workspace"
            case .herdrTab: "Herdr tab"
            case .herdrPane: "Herdr pane"
            }
        }
    }

    public var place: Place
    public var name: String
    public var aka: String? {
        didSet { if SessionTitle.same(aka, name) { aka = nil } }
    }
    public var status: BrainAgent.Status?
    public var agent: String?
    public var command: String?
    public var cwd: String?
    public var parent: String?
    public var number: Int?
    public var unseen = false
    public var isCurrent = false

    public init(
        place: Place, name: String, aka: String? = nil, status: BrainAgent.Status? = nil, agent: String? = nil,
        command: String? = nil, cwd: String? = nil, parent: String? = nil, number: Int? = nil, unseen: Bool = false,
        isCurrent: Bool = false
    ) {
        self.place = place
        self.name = name
        self.aka = SessionTitle.same(aka, name) ? nil : aka
        self.status = status
        self.agent = agent
        self.command = command
        self.cwd = cwd
        self.parent = parent
        self.number = number
        self.unseen = unseen
        self.isCurrent = isCurrent
    }

    public var kind: Kind {
        switch place {
        case .tab: .tab
        case .tmuxSession: .tmuxSession
        case .tmuxWindow: .tmuxWindow
        case .herdrWorkspace: .herdrWorkspace
        case .herdrTab: .herdrTab
        case .herdrPane: .herdrPane
        }
    }

    public var id: String {
        switch place {
        case .tab(let id, _): "tab:\(id)"
        case .tmuxSession(let name): "tmux-session:\(name)"
        case .tmuxWindow(_, _, let windowID, _): "window:\(windowID)"
        case .herdrWorkspace(let session, let workspaceID): "herdr-workspace:\(session):\(workspaceID)"
        case .herdrTab(let session, _, let tabID): "herdr-tab:\(session):\(tabID)"
        case .herdrPane(let session, _, _, let paneID): "herdr-pane:\(session):\(paneID)"
        }
    }

    public var spokenName: String {
        let base = "\(name) \(kind.spoken)"
        return parent.map { "\(base) in \($0)" } ?? base
    }

    var isBusy: Bool { status == .busy || status == .waiting }

    var isShellTab: Bool {
        if case .tab(_, .shell) = place { return true }
        return false
    }
}

public struct HostLayout: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var session: String
        public var index: Int
        public var windowID: String
        public var paneID: String
        public var command: String
        public var path: String
        public var active: Bool
        public var name: String
        public var title: String?
    }

    public var windows: [Window] = []
    public var herdr: [(session: String, snapshot: HerdrSnapshot)] = []

    public init(windows: [Window] = [], herdr: [(session: String, snapshot: HerdrSnapshot)] = []) {
        self.windows = windows
        self.herdr = herdr
    }

    public static func == (lhs: HostLayout, rhs: HostLayout) -> Bool {
        lhs.windows == rhs.windows && lhs.herdr.map(\.session) == rhs.herdr.map(\.session)
            && lhs.herdr.map(\.snapshot) == rhs.herdr.map(\.snapshot)
    }

    public var tmuxSessions: [String] {
        windows.map(\.session).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    public var herdrSessions: [String] { herdr.map(\.session) }

    public func snapshot(_ session: String) -> HerdrSnapshot? {
        herdr.first { $0.session == session }?.snapshot
    }

    static let windowsMarker = "windows"

    static let windowsScript =
        "echo '@@psh-windows@@'; tmux list-panes -a -F "
        + "'#{pane_active}\t#{window_active}\t#{session_name}\t#{window_index}\t#{window_id}\t#{pane_id}"
        + "\t#{pane_current_command}\t#{pane_current_path}\t#{host}\t#{pane_title}\t#{window_name}' 2>/dev/null"

    private static func sections(_ output: String) -> [(marker: String, lines: [Substring])] {
        var sections: [(marker: String, lines: [Substring])] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@psh-"), line.hasSuffix("@@") {
                sections.append((String(line.dropFirst(6).dropLast(2)), []))
            } else if !sections.isEmpty {
                sections[sections.count - 1].lines.append(line)
            }
        }
        return sections
    }

    private static func paneFields(_ line: Substring) -> [String]? {
        let fields = line.split(separator: "\t", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 11, Int(fields[3]) != nil, fields[4].hasPrefix("@") else { return nil }
        return fields
    }

    public static func paneTitles(_ output: String) -> [String: String] {
        var titles: [String: String] = [:]
        for section in sections(output) where section.marker == windowsMarker {
            for line in section.lines {
                guard let fields = paneFields(line),
                    let title = SessionTitle.clean(fields[9], host: fields[8], cwd: fields[7])
                else { continue }
                titles[fields[5]] = title
            }
        }
        return titles
    }

    public static func parse(_ output: String) -> HostLayout {
        var layout = HostLayout()
        var seen: [String: Int] = [:]
        for section in sections(output) {
            if section.marker == windowsMarker {
                for line in section.lines {
                    guard let fields = paneFields(line), fields[0] == "1", let index = Int(fields[3]) else { continue }
                    let session = Tmux.baseSessionName(fields[2])
                    let clone = session != fields[2]
                    let window = Window(
                        session: session, index: index, windowID: fields[4], paneID: fields[5], command: fields[6],
                        path: fields[7], active: fields[1] == "1", name: fields[10],
                        title: Tmux.sessionTitle(
                            paneTitle: fields[9], command: fields[6], host: fields[8], cwd: fields[7]))
                    if let existing = seen[window.windowID] {
                        if !clone { layout.windows[existing] = window }
                        continue
                    }
                    seen[window.windowID] = layout.windows.count
                    layout.windows.append(window)
                }
            } else if section.marker.hasPrefix("herdr:") {
                let session = String(section.marker.dropFirst(6))
                if let snapshot = Herdr.parseSnapshot(section.lines.joined(separator: "\n")) {
                    layout.herdr.append((session, snapshot))
                }
            }
        }
        layout.windows.sort { ($0.session, $0.index) < ($1.session, $1.index) }
        return layout
    }
}

public enum SessionCatalog {
    public static func build(
        tabs: [AppTab], layout: HostLayout, agents: [BrainAgent], unseen: (String, Int) -> Bool
    ) -> [BrainSession] {
        let current = tabs.first(where: \.isCurrent)?.backend
        let paneAgents = Dictionary(
            agents.compactMap { agent -> (String, BrainAgent)? in
                if case .tmux(_, _, _, let pane) = agent.location { return (pane, agent) }
                return nil
            }, uniquingKeysWith: { first, _ in first })
        var result: [BrainSession] = []

        func windowStatus(_ window: HostLayout.Window) -> (BrainAgent.Status, String?) {
            if let agent = paneAgents[window.paneID] { return (agent.status, agent.kind.rawValue) }
            return (Tmux.isInteractiveShell(window.command) ? .idle : .busy, nil)
        }

        func windowTitle(_ window: HostLayout.Window) -> String? {
            paneAgents[window.paneID]?.title ?? window.title
        }

        for tab in tabs {
            var session = BrainSession(
                place: .tab(id: tab.id, backend: tab.backend), name: tab.label, status: tab.status.map(Self.status),
                unseen: tab.unseen, isCurrent: tab.isCurrent)
            switch tab.backend {
            case .shell:
                session.parent = nil
            case .tmux(let name, let index, let windowID):
                session.parent = "tmux \(name)"
                if let window = layout.windows.first(where: { windowMatches($0, name, index, windowID) }) {
                    let (status, agent) = windowStatus(window)
                    if session.status == nil || agent != nil { session.status = status }
                    session.agent = agent
                    session.command = window.command
                    session.cwd = window.path
                    session.aka = windowTitle(window)
                }
            case .herdr(let name, _):
                session.parent = name == "default" ? "Herdr" : "Herdr \(name)"
                if let snapshot = layout.snapshot(name) {
                    let outline = HerdrOutline(snapshot)
                    if session.status == nil { session.status = outline.focusedWorkspace?.status.map(Self.status) }
                    session.cwd = outline.focusedPane?.cwd
                    session.aka = outline.focusedPane?.sessionTitle
                }
            }
            result.append(session)
        }

        for name in layout.tmuxSessions {
            let windows = layout.windows.filter { $0.session == name }
            let currentSession: String? = {
                if case .tmux(let session, _, _) = current { return session }
                return nil
            }()
            result.append(
                BrainSession(
                    place: .tmuxSession(name: name), name: name, cwd: windows.first(where: \.active)?.path,
                    isCurrent: currentSession == name))
            for window in windows {
                let (status, agent) = windowStatus(window)
                var isCurrent = false
                if case .tmux(let session, let index, let windowID) = current {
                    isCurrent = windowMatches(window, session, index, windowID)
                }
                let windowName = Tmux.isPlaceholderWindowName(window.name) ? "window \(window.index)" : window.name
                let title = windowTitle(window)
                result.append(
                    BrainSession(
                        place: .tmuxWindow(
                            session: name, windowIndex: window.index, windowID: window.windowID, paneID: window.paneID),
                        name: title ?? windowName, aka: title == nil ? nil : windowName,
                        status: status, agent: agent, command: window.command, cwd: window.path, parent: name,
                        number: window.index, unseen: unseen(name, window.index), isCurrent: isCurrent))
            }
        }

        for (name, snapshot) in layout.herdr {
            let outline = HerdrOutline(snapshot)
            let agentKinds = Dictionary(
                snapshot.agents.map { ($0.paneID, $0.agent ?? $0.displayAgent) },
                uniquingKeysWith: { first, _ in first })
            var currentHerdr = false
            if case .herdr(let session, _) = current { currentHerdr = session == name }
            let host = name == "default" ? nil : name
            for workspace in outline.workspaces {
                let label = workspace.label.isEmpty ? "workspace \(workspace.number)" : workspace.label
                result.append(
                    BrainSession(
                        place: .herdrWorkspace(session: name, workspaceID: workspace.workspaceID), name: label,
                        status: workspace.status.map(Self.status), parent: host, number: workspace.number,
                        unseen: workspace.status == .done, isCurrent: currentHerdr && workspace.focused))
                for (position, tab) in workspace.tabs.enumerated() {
                    let single = tab.panes.count == 1 ? tab.panes.first : nil
                    result.append(
                        BrainSession(
                            place: .herdrTab(session: name, workspaceID: workspace.workspaceID, tabID: tab.tabID),
                            name: tab.sessionTitle ?? tab.label, aka: tab.sessionTitle == nil ? nil : tab.label,
                            status: tab.status.map(Self.status),
                            agent: single.flatMap { agentKinds[$0.paneID] ?? nil }, cwd: tab.panes.first?.cwd,
                            parent: label, number: tab.number ?? position + 1, unseen: tab.status == .done,
                            isCurrent: currentHerdr && tab.focused))
                    for pane in tab.panes {
                        result.append(
                            BrainSession(
                                place: .herdrPane(
                                    session: name, workspaceID: workspace.workspaceID, tabID: tab.tabID,
                                    paneID: pane.paneID),
                                name: pane.title, aka: pane.sessionTitle == nil ? nil : pane.name,
                                status: pane.status.map(Self.status),
                                agent: agentKinds[pane.paneID] ?? nil, cwd: pane.cwd,
                                parent: tab.panes.count > 1 ? "\(label) tab \(tab.label)" : label,
                                unseen: pane.status == .done, isCurrent: currentHerdr && pane.focused))
                    }
                }
            }
        }
        return result
    }

    static func windowMatches(_ window: HostLayout.Window, _ session: String, _ index: Int?, _ windowID: String?)
        -> Bool
    {
        guard window.session == Tmux.baseSessionName(session) else { return false }
        if let windowID { return window.windowID == windowID }
        return index == window.index
    }

    static func status(_ status: AgentStatus) -> BrainAgent.Status {
        switch status {
        case .busy: .busy
        case .waiting: .waiting
        case .idle: .idle
        }
    }

    static func status(_ status: HerdrAgentStatus) -> BrainAgent.Status {
        switch status {
        case .working: .busy
        case .blocked: .waiting
        case .done: .done
        case .idle: .idle
        case .unknown: .unknown
        }
    }

    public static let snapshotPrefix = "[app: Sessions now: "

    public static func snapshot(_ sessions: [BrainSession], limit: Int = 30) -> String {
        let shownWindows = Set(
            sessions.compactMap { session -> String? in
                guard case .tab(_, .tmux(_, _, let windowID)) = session.place else { return nil }
                return windowID
            })
        let paneCounts = Dictionary(grouping: sessions.filter { $0.kind == .herdrPane }) { session -> String in
            if case .herdrPane(let host, _, let tab, _) = session.place { return "\(host):\(tab)" }
            return ""
        }.mapValues(\.count)
        var items: [String] = []
        var workspaces: [String: (item: Int, tabs: [String])] = [:]
        var position = 0
        for session in sessions {
            switch session.place {
            case .tab(_, let backend):
                position += 1
                let place =
                    switch backend {
                    case .shell: "shell"
                    case .tmux(let name, _, _): "tmux \(name)"
                    case .herdr: "Herdr"
                    }
                items.append(
                    "tab \(position) \"\(session.name)\"\(aka(session)) (\(([place] + flags(session)).joined(separator: ", ")))"
                )
            case .tmuxWindow(_, let index, let windowID, _):
                guard !shownWindows.contains(windowID) else { continue }
                items.append(
                    "tmux window \(index) \"\(session.name)\"\(aka(session)) in \(session.parent ?? "")"
                        + detail(session))
            case .herdrWorkspace(let host, let id):
                workspaces["\(host):\(id)"] = (items.count, [])
                let place = session.parent.map { " in Herdr \($0)" } ?? ""
                items.append(
                    "Herdr workspace \(session.number.map(String.init) ?? "") \"\(session.name)\"\(place)"
                        + (session.isCurrent ? " (current)" : ""))
            case .herdrTab(let host, let workspace, let tab):
                let panes = paneCounts["\(host):\(tab)"].flatMap { $0 > 1 ? "\($0) panes" : nil }
                let flags = [panes].compactMap { $0 } + flags(session)
                let number = session.number.map { "\($0) " } ?? ""
                workspaces["\(host):\(workspace)"]?.tabs.append(
                    "tab \(number)\"\(session.name)\"\(aka(session))"
                        + (flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"))
            case .herdrPane(let host, _, let tab, _):
                guard (paneCounts["\(host):\(tab)"] ?? 0) > 1 else { continue }
                items.append(
                    "Herdr pane \"\(session.name)\"\(aka(session)) in \(session.parent ?? "")" + detail(session))
            case .tmuxSession:
                continue
            }
        }
        for workspace in workspaces.values where !workspace.tabs.isEmpty {
            items[workspace.item] += ": " + workspace.tabs.joined(separator: ", ")
        }
        guard !items.isEmpty else { return snapshotPrefix + "none.]" }
        let shown = items.prefix(limit).joined(separator: "; ")
        let more = items.count > limit ? "; and \(items.count - limit) more, call list_sessions" : ""
        return snapshotPrefix + shown + more + ".]"
    }

    private static func aka(_ session: BrainSession) -> String {
        session.aka.map { " aka \"\($0)\"" } ?? ""
    }

    private static func flags(_ session: BrainSession) -> [String] {
        var flags: [String] = []
        if let agent = session.agent { flags.append(agent) }
        if let status = session.status, status != .idle, status != .unknown { flags.append(status.rawValue) }
        if session.unseen, session.status != .done { flags.append("unseen") }
        if session.isCurrent { flags.append("current") }
        return flags
    }

    private static func detail(_ session: BrainSession) -> String {
        let flags = flags(session)
        return flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
    }

    static func summary(_ session: BrainSession) -> [String: Any] {
        var item: [String: Any] = ["name": session.name, "id": session.id, "kind": session.kind.rawValue]
        if let aka = session.aka { item["aka"] = aka }
        if let number = session.number { item["number"] = number }
        if let status = session.status { item["status"] = status.rawValue }
        if let agent = session.agent { item["agent"] = agent }
        if let parent = session.parent { item["in"] = parent }
        if let cwd = session.cwd, !cwd.isEmpty { item["cwd"] = cwd }
        if let command = session.command, session.agent == nil, !Tmux.isInteractiveShell(command) {
            item["running"] = command
        }
        if session.unseen { item["unseen_finished"] = true }
        if session.isCurrent { item["current"] = true }
        if case .tab(_, let backend) = session.place {
            item["shows"] =
                switch backend {
                case .shell: "shell"
                case .tmux: "tmux window"
                case .herdr: "Herdr"
                }
        }
        return item
    }
}

public enum SessionResolver {
    public enum Match: Equatable, Sendable {
        case found(BrainSession)
        case none
        case ambiguous([BrainSession])
    }

    static let currentWords: Set<String> = ["this", "current", "it", "here", "that", "one", "the", "this one"]
    static let fillers: Set<String> = ["the", "a", "my", "in", "on", "of", "called", "named", "one"]

    public static func resolve(_ name: String?, in sessions: [BrainSession]) -> Match {
        let key = AgentResolver.normalize(name ?? "")
        if let exact = sessions.first(where: { $0.id == name }) { return .found(exact) }
        let words = key.split(separator: " ").map(String.init)
        let kinds = mentionedKinds(words)
        if let positioned = positional(words, in: sessions) { return .found(positioned) }
        let core = words.filter { !kindWords.keys.contains($0) && !fillers.contains($0) && !currentWords.contains($0) }
        let named = sessions.filter { session in
            !key.isEmpty && [session.name, session.aka].contains { AgentResolver.normalize($0 ?? "") == key }
        }
        if core.isEmpty, named.count == 1 { return .found(named[0]) }
        if core.isEmpty {
            let wanted = kinds.isEmpty ? [BrainSession.Kind.tab] : kinds
            for kind in wanted {
                if let current = sessions.first(where: { $0.isCurrent && $0.kind == kind }) { return .found(current) }
            }
            if let current = sessions.first(where: { $0.isCurrent && $0.kind == .tab }) { return .found(current) }
            return .none
        }
        let coreKey = core.joined(separator: " ")
        let scored = sessions.map { (session: $0, score: score(coreKey, words: core, kinds: kinds, $0)) }
            .filter { $0.score > 0 }
        guard let best = scored.map(\.score).max() else { return .none }
        let top = scored.filter { $0.score == best }.map(\.session)
        if top.count == 1 { return .found(top[0]) }
        let tabs = top.filter { $0.kind == .tab }
        if tabs.count == 1, kinds.isEmpty || kinds.contains(.tab) { return .found(tabs[0]) }
        if let current = top.first(where: \.isCurrent) { return .found(current) }
        let ranked = top.map { (session: $0, rank: tieRank.firstIndex(of: $0.kind) ?? tieRank.count) }
        let bestRank = ranked.map(\.rank).min()
        let preferred = ranked.filter { $0.rank == bestRank }
        if preferred.count == 1 { return .found(preferred[0].session) }
        return .ambiguous(top)
    }

    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5, "6th": 6, "7th": 7, "8th": 8,
        "9th": 9, "10th": 10,
    ]
    static let numbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]
    static let positionalNoise: Set<String> = [
        "the", "a", "my", "to", "go", "switch", "show", "open", "me", "please", "number", "no", "herdr", "tmux", "app",
    ]

    enum Position: Equatable {
        case ordinal(Int), number(Int), last, next, previous
    }

    static func positional(_ words: [String], in sessions: [BrainSession]) -> BrainSession? {
        let rest = words.filter { !positionalNoise.contains($0) }
        guard rest.count == 2,
            let kindWord = rest.first(where: { ["tab", "window", "workspace"].contains($0) }),
            let token = rest.first(where: { $0 != kindWord })
        else { return nil }
        let position: Position
        if let value = ordinals[token] {
            position = .ordinal(value)
        } else if let value = Int(token) ?? numbers[token] {
            position = .number(value)
        } else if token == "last" {
            position = .last
        } else if token == "next" {
            position = .next
        } else if ["previous", "prev"].contains(token) {
            position = .previous
        } else {
            return nil
        }
        let currentTab = sessions.first { $0.kind == .tab && $0.isCurrent }
        var herdrCurrent = false
        if case .tab(_, .herdr) = currentTab?.place { herdrCurrent = true }
        let herdrWorkspace = sessions.first { $0.kind == .herdrWorkspace && $0.isCurrent }
        let tmuxSession = sessions.first { $0.kind == .tmuxSession && $0.isCurrent }
        let candidates: [BrainSession]
        switch kindWord {
        case "tab" where words.contains("tmux"):
            candidates = windows(of: tmuxSession, in: sessions)
        case "tab" where words.contains("herdr") || (herdrCurrent && !words.contains("app")):
            candidates = tabs(of: herdrWorkspace, in: sessions)
        case "tab":
            candidates = sessions.filter { $0.kind == .tab }
        case "window":
            candidates = windows(of: tmuxSession, in: sessions)
        default:
            var host: String?
            if case .herdrWorkspace(let session, _) = herdrWorkspace?.place { host = session }
            candidates = sessions.filter {
                guard case .herdrWorkspace(let session, _) = $0.place else { return false }
                return host == nil || session == host
            }
        }
        guard !candidates.isEmpty else { return nil }
        let current = candidates.firstIndex(where: \.isCurrent)
        switch position {
        case .ordinal(let value):
            return candidates.indices.contains(value - 1) ? candidates[value - 1] : nil
        case .number(let value):
            if let match = candidates.first(where: { $0.number == value || $0.name == String(value) }) {
                return match
            }
            return candidates.first?.number == nil && candidates.indices.contains(value - 1)
                ? candidates[value - 1] : nil
        case .last:
            return candidates.last
        case .next:
            return current.map { candidates[($0 + 1) % candidates.count] }
        case .previous:
            return current.map { candidates[($0 + candidates.count - 1) % candidates.count] }
        }
    }

    private static func windows(of session: BrainSession?, in sessions: [BrainSession]) -> [BrainSession] {
        guard case .tmuxSession(let name) = session?.place else { return [] }
        return sessions.filter {
            if case .tmuxWindow(name, _, _, _) = $0.place { return true }
            return false
        }
    }

    private static func tabs(of workspace: BrainSession?, in sessions: [BrainSession]) -> [BrainSession] {
        guard case .herdrWorkspace(let host, let id) = workspace?.place else { return [] }
        return sessions.filter {
            if case .herdrTab(host, id, _) = $0.place { return true }
            return false
        }
    }

    static let tieRank: [BrainSession.Kind] = [.tab, .tmuxWindow, .herdrTab, .herdrPane, .tmuxSession, .herdrWorkspace]

    static let kindWords: [String: [BrainSession.Kind]] = [
        "tab": [.tab, .herdrTab], "tabs": [.tab, .herdrTab], "window": [.tmuxWindow], "session": [.tmuxSession],
        "workspace": [.herdrWorkspace], "pane": [.herdrPane, .tmuxWindow], "split": [.herdrPane],
        "shell": [], "terminal": [.tab], "tmux": [.tmuxWindow, .tmuxSession],
        "herdr": [.herdrTab, .herdrPane, .herdrWorkspace],
    ]

    static func mentionedKinds(_ words: [String]) -> [BrainSession.Kind] {
        var kinds: [BrainSession.Kind] = []
        if words.contains("tmux") {
            if words.contains("session") { kinds.append(.tmuxSession) }
            if words.contains("window") || words.contains("tab") || words.contains("pane") {
                kinds.append(.tmuxWindow)
            }
        }
        if words.contains("herdr") {
            if words.contains("workspace") { kinds.append(.herdrWorkspace) }
            if words.contains("tab") { kinds.append(.herdrTab) }
            if words.contains("pane") || words.contains("split") { kinds.append(.herdrPane) }
        }
        for word in words { kinds += kindWords[word] ?? [] }
        return kinds.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    static func score(_ key: String, words: [String], kinds: [BrainSession.Kind], _ session: BrainSession) -> Int {
        let name = AgentResolver.normalize(session.name)
        let aka = AgentResolver.normalize(session.aka ?? "")
        let folder = AgentResolver.normalize(session.cwd.map { ($0 as NSString).lastPathComponent } ?? "")
        let parent = AgentResolver.normalize(session.parent ?? "")
        var score =
            [name, aka].map { name in
                if !name.isEmpty, key == name { return 100 }
                if !name.isEmpty, name.count >= 2, key.contains(name) || name.contains(key) { return 40 }
                return 0
            }.max() ?? 0
        if !folder.isEmpty, words.contains(folder) || key == folder { score += 30 }
        if let agent = session.agent, words.contains(agent.lowercased()) { score += 20 }
        if !parent.isEmpty,
            words.contains(where: { $0.count > 2 && parent.split(separator: " ").contains(Substring($0)) })
        {
            score += 10
        }
        if let number = words.compactMap(Int.init).first, session.number == number || name == String(number) {
            score += 50
        }
        guard score > 0 else { return 0 }
        if let rank = kinds.firstIndex(of: session.kind) { score += 15 - min(rank, 5) }
        return score
    }
}
