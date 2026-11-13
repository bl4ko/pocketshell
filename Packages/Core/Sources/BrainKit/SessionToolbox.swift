import Foundation
import GitKit
import HerdrKit
import Models
import MonitorKit
import TmuxKit

public enum SessionKey: String, Equatable, Sendable, CaseIterable {
    case esc
    case ctrlC = "ctrl_c"
    case enter
    case tab
    case shiftTab = "shift_tab"
    case up, down, left, right
    case ctrlD = "ctrl_d"

    var tmuxName: String {
        switch self {
        case .esc: "Escape"
        case .ctrlC: "C-c"
        case .enter: "Enter"
        case .tab: "Tab"
        case .shiftTab: "BTab"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .ctrlD: "C-d"
        }
    }

    var herdrName: String {
        switch self {
        case .esc: "esc"
        case .ctrlC: "ctrl+c"
        case .enter: "enter"
        case .tab: "tab"
        case .shiftTab: "shift+tab"
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .ctrlD: "ctrl+d"
        }
    }

    var bytes: String {
        switch self {
        case .esc: "\u{1b}"
        case .ctrlC: "\u{03}"
        case .enter: "\r"
        case .tab: "\t"
        case .shiftTab: "\u{1b}[Z"
        case .up: "\u{1b}[A"
        case .down: "\u{1b}[B"
        case .right: "\u{1b}[C"
        case .left: "\u{1b}[D"
        case .ctrlD: "\u{04}"
        }
    }
}

public struct NewSession: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case shellTab = "shell_tab"
        case tmuxWindow = "tmux_window"
        case tmuxSession = "tmux_session"
        case herdrTab = "herdr_tab"
        case herdrSplit = "herdr_split"
        case herdrWorkspace = "herdr_workspace"
    }

    public var kind: Kind
    public var directory: String?
    public var name: String?
    public var agent: AgentKind?
    public var tmuxSession: String?
    public var herdrSession: String?
    public var workspaceID: String?
    public var paneID: String?

    public init(
        kind: Kind, directory: String? = nil, name: String? = nil, agent: AgentKind? = nil,
        tmuxSession: String? = nil, herdrSession: String? = nil, workspaceID: String? = nil, paneID: String? = nil
    ) {
        self.kind = kind
        self.directory = directory
        self.name = name
        self.agent = agent
        self.tmuxSession = tmuxSession
        self.herdrSession = herdrSession
        self.workspaceID = workspaceID
        self.paneID = paneID
    }
}

public enum SessionAction: Equatable, Sendable {
    case send(target: String, text: String, enter: Bool)
    case key(target: String, key: SessionKey)
    case create(NewSession)
    case close(target: String)
    case skipPermissions(target: String)
    case snippet(name: String, target: String?)
}

enum SessionEndpoint: Equatable, Sendable {
    case tmux(String)
    case herdr(session: String, paneID: String)
    case local(String)
}

public enum SessionCommands {
    static let tmux = AgentControl.tmux
    static func quote(_ value: String) -> String { HostAgents.shellQuote(value) }

    static func read(_ endpoint: SessionEndpoint) -> String? {
        switch endpoint {
        case .tmux(let target): "\(tmux) capture-pane -p -t \(quote(target))"
        case .herdr(let session, let pane):
            "\(Herdr.commandPrefix(session: session)) pane read \(quote(pane)) --source visible"
        case .local: nil
        }
    }

    static func text(_ endpoint: SessionEndpoint, _ text: String, enter: Bool) -> String? {
        switch endpoint {
        case .tmux(let target):
            let send = "\(tmux) send-keys -t \(quote(target)) -l -- \(quote(text))"
            return enter ? "\(send) && sleep 0.1 && \(tmux) send-keys -t \(quote(target)) Enter" : send
        case .herdr(let session, let pane):
            let prefix = Herdr.commandPrefix(session: session)
            let send = "\(prefix) pane send-text \(quote(pane)) \(quote(text))"
            return enter ? "\(send) && \(prefix) pane send-keys \(quote(pane)) enter" : send
        case .local: return nil
        }
    }

    static func key(_ endpoint: SessionEndpoint, _ key: SessionKey) -> String? {
        switch endpoint {
        case .tmux(let target): "\(tmux) send-keys -t \(quote(target)) \(key.tmuxName)"
        case .herdr(let session, let pane):
            "\(Herdr.commandPrefix(session: session)) pane send-keys \(quote(pane)) \(key.herdrName)"
        case .local: nil
        }
    }

    static func newTmux(_ new: NewSession, session: String?) -> String {
        let format = " -P -F '#{session_name}|#{window_index}|#{window_id}|#{pane_id}'"
        let directory = new.directory.map { " -c \(quote($0))" } ?? ""
        let create: String
        if new.kind == .tmuxSession {
            create = "\(tmux) new-session -d" + (new.name.map { " -s \(quote($0))" } ?? "") + directory + format
        } else {
            create =
                "\(tmux) new-window -t \(quote(session ?? ""))" + directory
                + (new.name.map { " -n \(quote($0))" } ?? "") + format
        }
        var script = "info=$(\(create)) || exit 1; echo \"$info\""
        if let agent = new.agent {
            script +=
                "; p=${info##*|}; sleep 0.5; \(tmux) send-keys -t \"$p\" -l -- \(agent.rawValue)"
                + " && \(tmux) send-keys -t \"$p\" Enter"
        }
        return script
    }

    static func rename(_ session: BrainSession, to name: String) -> String? {
        switch session.place {
        case .tab: nil
        case .tmuxSession(let old): "\(tmux) rename-session -t \(quote(old)) \(quote(name))"
        case .tmuxWindow(_, _, let windowID, _): "\(tmux) rename-window -t \(quote(windowID)) \(quote(name))"
        case .herdrWorkspace(let host, let id): Herdr.renameCommand(session: host, target: .workspace(id), label: name)
        case .herdrTab(let host, _, let id): Herdr.renameCommand(session: host, target: .tab(id), label: name)
        case .herdrPane(let host, _, _, let id): Herdr.renameCommand(session: host, target: .pane(id), label: name)
        }
    }

    static func close(_ session: BrainSession) -> String? {
        switch session.place {
        case .tab: nil
        case .tmuxSession(let name): "\(tmux) kill-session -t \(quote(name))"
        case .tmuxWindow(_, _, let windowID, _): "\(tmux) kill-window -t \(quote(windowID))"
        case .herdrWorkspace(let host, let id): Herdr.closeCommand(session: host, target: .workspace(id))
        case .herdrTab(let host, _, let id): Herdr.closeCommand(session: host, target: .tab(id))
        case .herdrPane(let host, _, _, let id): Herdr.closeCommand(session: host, target: .pane(id))
        }
    }

    static func findDirectory(_ name: String) -> String {
        """
        n=\(quote(name)); case "$n" in "~"*) n="$HOME${n#\\~}";; esac
        if [ -d "$n" ]; then cd "$n" && pwd; exit 0; fi
        for v in "$n" "$(printf %s "$n" | tr -d ' ')" "$(printf %s "$n" | tr ' ' -)"; do
        f=$(find "$HOME" -maxdepth 3 -type d -iname "$v" -not -path '*/.*' 2>/dev/null | head -n 1)
        if [ -n "$f" ]; then echo "$f"; exit 0; fi
        done
        exit 0
        """
    }

    static func git(in directory: String) -> String {
        [
            Git.branchCommand(in: directory), "echo '@@psh-status@@'", Git.statusCommand(in: directory),
            "echo '@@psh-log@@'", Git.logCommand(in: directory, count: 3),
        ].joined(separator: "; ")
    }

    static func cleanScreen(_ text: String, lines: Int = 60, characters: Int = 4000) -> String {
        var rows = text.replacingOccurrences(of: "\u{0}", with: " ").split(
            separator: "\n", omittingEmptySubsequences: false
        )
        .map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while rows.last?.isEmpty == true { rows.removeLast() }
        while rows.first?.isEmpty == true { rows.removeFirst() }
        let joined = rows.suffix(lines).joined(separator: "\n")
        return joined.count > characters ? "…" + String(joined.suffix(characters)) : joined
    }
}

@MainActor
public final class SessionToolbox {
    public struct IO {
        public var exec: @MainActor (String) async -> String?
        public var tabs: @MainActor () -> [AppTab]
        public var screen: @MainActor (String) -> String?
        public var type: @MainActor (String, String) -> Bool
        public var focus: @MainActor (BrainSession.Place) async -> Bool
        public var newTab: @MainActor (_ directory: String?, _ name: String?) async -> Bool
        public var renameTab: @MainActor (String, String) -> Bool
        public var closeTab: @MainActor (String) -> Bool
        public var tmuxSessionRenamed: @MainActor (String, String) -> Void
        public var unseen: @MainActor (String, Int) -> Bool
        public var skipPermissions: @MainActor () async -> String?
        public var snippets: @MainActor () -> [Snippet]
        public var defaultTmuxSession: @MainActor () -> String?

        public init(
            exec: @escaping @MainActor (String) async -> String?,
            tabs: @escaping @MainActor () -> [AppTab],
            screen: @escaping @MainActor (String) -> String? = { _ in nil },
            type: @escaping @MainActor (String, String) -> Bool = { _, _ in false },
            focus: @escaping @MainActor (BrainSession.Place) async -> Bool = { _ in false },
            newTab: @escaping @MainActor (String?, String?) async -> Bool = { _, _ in false },
            renameTab: @escaping @MainActor (String, String) -> Bool = { _, _ in false },
            closeTab: @escaping @MainActor (String) -> Bool = { _ in false },
            tmuxSessionRenamed: @escaping @MainActor (String, String) -> Void = { _, _ in },
            unseen: @escaping @MainActor (String, Int) -> Bool = { _, _ in false },
            skipPermissions: @escaping @MainActor () async -> String? = { "Not available." },
            snippets: @escaping @MainActor () -> [Snippet] = { [] },
            defaultTmuxSession: @escaping @MainActor () -> String? = { nil }
        ) {
            self.exec = exec
            self.tabs = tabs
            self.screen = screen
            self.type = type
            self.focus = focus
            self.newTab = newTab
            self.renameTab = renameTab
            self.closeTab = closeTab
            self.tmuxSessionRenamed = tmuxSessionRenamed
            self.unseen = unseen
            self.skipPermissions = skipPermissions
            self.snippets = snippets
            self.defaultTmuxSession = defaultTmuxSession
        }
    }

    public enum Outcome: Equatable, Sendable {
        case done(String)
        case confirm(SessionAction, question: String)
    }

    public private(set) var layout = HostLayout()
    public private(set) var ingested = false
    public var spokenTurns: [String]?
    private var agents: [BrainAgent] = []
    private let io: IO

    public init(io: IO) {
        self.io = io
    }

    public func ingest(_ output: String, agents: [BrainAgent]) {
        layout = HostLayout.parse(output)
        self.agents = agents
        ingested = true
    }

    public var sessions: [BrainSession] {
        SessionCatalog.build(tabs: io.tabs(), layout: layout, agents: agents, unseen: io.unseen)
    }

    public var snapshot: String? {
        ingested ? SessionCatalog.snapshot(sessions) : nil
    }

    public static let toolNames: Set<String> = Set(definitions.map(\.name))

    public func call(_ call: ToolCall, refresh: @MainActor () async -> Void) async -> Outcome {
        let arguments = call.argumentObject
        func string(_ key: String) -> String? {
            (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let refreshed = !ingested
        if refreshed { await refresh() }
        let target = string("target") ?? string("agent")
        switch call.name {
        case "list_sessions":
            if !refreshed { await refresh() }
            return .done(AgentToolbox.json(["sessions": sessions.prefix(80).map(SessionCatalog.summary)]))
        case "focus_session":
            return await withTarget(target, refresh: refresh) { .done(await self.focus($0)) }
        case "read_screen":
            return await withTarget(target, refresh: refresh) { .done(await self.read($0)) }
        case "send_text":
            guard let text = arguments["text"] as? String, !text.isEmpty else {
                return .done(Self.error("text is empty"))
            }
            let enter = arguments["enter"] as? Bool ?? false
            return await withTarget(target, refresh: refresh) { session in
                let action = SessionAction.send(target: session.id, text: text, enter: enter)
                if session.agent != nil, let turns = self.spokenTurns, !PromptFidelity.isVerbatim(text, turns: turns) {
                    return .confirm(action, question: PromptFidelity.readBack(text, agent: session.spokenName))
                }
                if session.isBusy || SafetyPolicy.mentionsRisk(text) {
                    return .confirm(
                        action, question: "Should I type \(Self.quoted(text)) into the \(session.spokenName)?")
                }
                return .done(await self.perform(action, refresh: refresh))
            }
        case "send_key":
            guard let key = SessionKey(rawValue: string("key") ?? "") else {
                return .done(
                    Self.error("key must be one of " + SessionKey.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            return await withTarget(target, refresh: refresh) { session in
                let action = SessionAction.key(target: session.id, key: key)
                guard let question = await self.keyQuestion(key, session) else {
                    return .done(await self.perform(action, refresh: refresh))
                }
                return .confirm(action, question: question)
            }
        case "new_session":
            return await newSession(arguments, refresh: refresh)
        case "rename":
            guard let name = string("name") else { return .done(Self.error("name is empty")) }
            return await withTarget(target, refresh: refresh) { .done(await self.rename($0, to: name)) }
        case "close":
            return await withTarget(target, refresh: refresh) { session in
                let stops = session.kind == .tab ? "" : " Its programs stop."
                return .confirm(
                    .close(target: session.id), question: "Should I close the \(session.spokenName)?\(stops)")
            }
        case "skip_permissions":
            return await withAgentTarget(target, refresh: refresh) { session in
                let what =
                    session.agent == AgentKind.codex.rawValue ? "give Codex full access" : "turn off permission prompts"
                return .confirm(
                    .skipPermissions(target: session.id), question: "Should I \(what) in the \(session.spokenName)?")
            }
        case "git_status":
            if let directory = string("directory") {
                switch await resolveDirectory(directory) {
                case .success(let path): return .done(await git(path ?? directory))
                case .failure(let failure): return .done(Self.error(failure.message))
                }
            }
            return await withTarget(target, refresh: refresh) { session in
                guard let cwd = session.cwd ?? self.agentCwd(session), !cwd.isEmpty else {
                    return .done(
                        Self.error("The folder of the \(session.spokenName) is not known. Ask for the folder."))
                }
                return .done(await self.git(cwd))
            }
        case "run_snippet":
            guard let name = string("name") else { return .done(Self.error("name is empty")) }
            guard let snippet = snippet(named: name) else {
                let names = io.snippets().map(\.name)
                return .done(
                    Self.error(
                        "No snippet matches \(name). Snippets: "
                            + (names.isEmpty ? "none" : names.joined(separator: ", "))))
            }
            if snippet.runMode == .execAndShowOutput {
                let action = SessionAction.snippet(name: snippet.name, target: nil)
                if SafetyPolicy.mentionsRisk(snippet.command) {
                    return .confirm(action, question: "Should I run the snippet \(snippet.name)?")
                }
                return .done(await perform(action, refresh: refresh))
            }
            return await withTarget(target, refresh: refresh) { session in
                let action = SessionAction.snippet(name: snippet.name, target: session.id)
                if session.isBusy || SafetyPolicy.mentionsRisk(snippet.command) {
                    return .confirm(
                        action, question: "Should I run the snippet \(snippet.name) in the \(session.spokenName)?")
                }
                return .done(await self.perform(action, refresh: refresh))
            }
        default:
            return .done(Self.error("Unknown tool \(call.name)"))
        }
    }

    public func perform(_ action: SessionAction, refresh: @MainActor () async -> Void) async -> String {
        if case .create(let new) = action { return await create(new) }
        if case .snippet(let name, .none) = action {
            guard let snippet = snippet(named: name) else { return Self.error("That snippet is gone.") }
            guard let output = await io.exec(snippet.command) else { return Self.error("The host is not connected.") }
            return AgentToolbox.json([
                "snippet": snippet.name, "output": SessionCommands.cleanScreen(output, lines: 80, characters: 3000),
            ])
        }
        let id: String =
            switch action {
            case .send(let target, _, _), .key(let target, _), .close(let target), .skipPermissions(let target): target
            case .snippet(_, let target): target ?? ""
            case .create: ""
            }
        var found = sessions.first { $0.id == id }
        if found == nil {
            await refresh()
            found = sessions.first { $0.id == id }
        }
        guard let session = found else { return Self.error("That session is gone.") }
        switch action {
        case .send(_, let text, let enter):
            return await type(text, enter: enter, into: session)
        case .key(_, let key):
            guard let endpoint = endpoint(session) else { return Self.error("Nothing to type into there.") }
            if case .local(let tab) = endpoint {
                return io.type(tab, key.bytes)
                    ? AgentToolbox.json(["key": key.rawValue, "target": session.spokenName])
                    : Self.error("The tab is not connected.")
            }
            return await run(SessionCommands.key(endpoint, key) ?? "", herdr: session.isHerdr) {
                AgentToolbox.json(["key": key.rawValue, "target": session.spokenName])
            }
        case .close:
            return await close(session)
        case .skipPermissions:
            guard await io.focus(session.place) else { return Self.error("Could not show the \(session.spokenName).") }
            if let failure = await io.skipPermissions() { return Self.error(failure) }
            return AgentToolbox.json(["skipped_permissions": session.spokenName])
        case .snippet(let name, _):
            guard let snippet = snippet(named: name) else { return Self.error("That snippet is gone.") }
            return await type(snippet.command, enter: true, into: session)
        case .create:
            return Self.error("unreachable")
        }
    }

    public func herdrStart(
        kind: AgentKind, directory: String?, current: CurrentTarget?, hasTmux: Bool,
        refresh: @MainActor () async -> Void
    ) async -> String? {
        if !ingested { await refresh() }
        guard let host = current?.herdrSession ?? (hasTmux ? nil : layout.herdrSessions.first) else { return nil }
        var new = NewSession(
            kind: .herdrTab, agent: kind, herdrSession: host, workspaceID: layout.snapshot(host)?.focusedWorkspaceID)
        if let directory {
            switch await resolveDirectory(directory) {
            case .success(let path): new.directory = path ?? directory
            case .failure(let failure): return Self.error(failure.message)
            }
        }
        return await create(new)
    }

    private func newSession(_ arguments: [String: Any], refresh: @MainActor () async -> Void) async -> Outcome {
        func string(_ key: String) -> String? {
            (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        var new = NewSession(
            kind: string("kind").flatMap(NewSession.Kind.init(rawValue:)) ?? defaultKind(), name: string("name"),
            agent: string("agent").flatMap { AgentKind(rawValue: $0.lowercased()) })
        if let directory = string("directory") {
            switch await resolveDirectory(directory) {
            case .success(let path): new.directory = path
            case .failure(let failure): return .done(Self.error(failure.message))
            }
        }
        var place: BrainSession?
        if let within = string("in") {
            switch SessionResolver.resolve(within, in: sessions) {
            case .found(let session): place = session
            case .none: return .done(Self.error("Nothing matches \(within)."))
            case .ambiguous(let options):
                return .done(Self.error("Which one? " + options.map(\.spokenName).joined(separator: ", ")))
            }
        }
        place = place ?? sessions.first { $0.isCurrent && $0.kind == .tab }
        switch new.kind {
        case .shellTab:
            if new.agent != nil { return .done(Self.error("Start agents in a tmux window or a Herdr tab.")) }
        case .tmuxWindow, .tmuxSession:
            new.tmuxSession = place.flatMap(tmuxSession) ?? io.defaultTmuxSession() ?? layout.tmuxSessions.first
            if new.kind == .tmuxWindow, new.tmuxSession == nil {
                return .done(Self.error("There is no tmux session here. Open a tmux session first."))
            }
        case .herdrTab, .herdrSplit, .herdrWorkspace:
            guard let host = place.flatMap(herdrSession) ?? layout.herdrSessions.first else {
                return .done(Self.error("Herdr is not running on this host."))
            }
            new.herdrSession = host
            let snapshot = layout.snapshot(host)
            new.workspaceID = place.flatMap(workspaceID) ?? snapshot?.focusedWorkspaceID
            if new.kind == .herdrSplit {
                if let place, case .herdr(_, let pane) = endpoint(place) { new.paneID = pane }
                new.paneID = new.paneID ?? snapshot?.focusedPaneID
                if new.paneID == nil { return .done(Self.error("There is no Herdr pane to split.")) }
            } else if new.kind == .herdrTab, new.workspaceID == nil {
                return .done(Self.error("There is no Herdr workspace for a new tab."))
            }
        }
        if let agent = new.agent {
            let folder = new.directory.map { " in \(($0 as NSString).lastPathComponent)" } ?? ""
            return .confirm(.create(new), question: "Should I start a new \(agent.displayName) session\(folder)?")
        }
        return .done(await create(new))
    }

    private func defaultKind() -> NewSession.Kind {
        switch io.tabs().first(where: \.isCurrent)?.backend {
        case .tmux: .tmuxWindow
        case .herdr: .herdrTab
        case .shell, nil: .shellTab
        }
    }

    private func create(_ new: NewSession) async -> String {
        var result: [String: Any] = ["opened": new.kind.rawValue]
        if let name = new.name { result["name"] = name }
        if let directory = new.directory { result["directory"] = directory }
        switch new.kind {
        case .shellTab:
            guard await io.newTab(new.directory, new.name) else { return Self.error("A new tab cannot open here.") }
            return AgentToolbox.json(result)
        case .tmuxWindow, .tmuxSession:
            guard let raw = await io.exec(AgentControl.checked(SessionCommands.newTmux(new, session: new.tmuxSession)))
            else { return Self.error("The host is not connected.") }
            let (output, status) = AgentControl.splitExit(raw)
            let fields =
                output.split(separator: "\n").first { $0.split(separator: "|").count >= 4 }?
                .split(separator: "|", omittingEmptySubsequences: false).map(String.init) ?? []
            guard status == 0, fields.count >= 4, let index = Int(fields[fields.count - 3]) else {
                return Self.error(
                    "tmux did not open it. " + output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))
            }
            let session = Tmux.baseSessionName(fields[0..<(fields.count - 3)].joined(separator: "|"))
            result["tmux_session"] = session
            if let agent = new.agent { result["started"] = agent.displayName }
            let shown = await io.focus(
                .tmuxWindow(
                    session: session, windowIndex: index, windowID: fields[fields.count - 2],
                    paneID: fields[fields.count - 1]))
            result["shown"] = shown
            return AgentToolbox.json(result)
        case .herdrTab, .herdrSplit, .herdrWorkspace:
            guard let host = new.herdrSession else { return Self.error("Herdr is not running on this host.") }
            let item: HerdrNewItem
            switch new.kind {
            case .herdrSplit: item = .split(paneID: new.paneID ?? "", direction: .right)
            case .herdrWorkspace: item = .workspace
            default: item = .tab(workspaceID: new.workspaceID ?? "")
            }
            guard
                let output = await io.exec(
                    Herdr.createCommand(session: host, item: item, label: new.name ?? "", cwd: new.directory))
            else { return Self.error("The host is not connected.") }
            guard case .done(let created) = Herdr.parseActionResult(output), let pane = created else {
                if case .failed(_, let message) = Herdr.parseActionResult(output) { return Self.error(message) }
                return Self.error("Herdr did not open it.")
            }
            if item.isSplit, let name = new.name {
                _ = await io.exec(Herdr.renameCommand(session: host, target: .pane(pane), label: name))
            }
            if let agent = new.agent {
                let taken = layout.snapshot(host)?.agents.compactMap(\.name) ?? []
                let started = await io.exec(
                    Herdr.startAgentCommand(
                        session: host, name: Herdr.agentName(kind: agent.rawValue, taken: taken), kind: agent.rawValue,
                        paneID: pane))
                let parsed =
                    started.map(Herdr.parseActionResult) ?? .failed(code: "", message: "The host is not connected.")
                if !Herdr.agentStarted(parsed), case .failed(_, let message) = parsed { return Self.error(message) }
                result["started"] = agent.displayName
            }
            result["shown"] = await io.focus(
                .herdrPane(session: host, workspaceID: new.workspaceID ?? "", tabID: "", paneID: pane))
            return AgentToolbox.json(result)
        }
    }

    private func focus(_ session: BrainSession) async -> String {
        var place = session.place
        if case .tmuxSession(let name) = place,
            let window = layout.windows.first(where: { $0.session == name && $0.active })
                ?? layout.windows.first(where: { $0.session == name })
        {
            place = .tmuxWindow(
                session: name, windowIndex: window.index, windowID: window.windowID, paneID: window.paneID)
        }
        guard await io.focus(place) else { return Self.error("Could not show the \(session.spokenName).") }
        if let command = herdrFocusCommand(place), await io.exec(command) == nil {
            return Self.error("Could not switch Herdr to the \(session.spokenName).")
        }
        return AgentToolbox.json(["focused": session.spokenName])
    }

    private func herdrFocusCommand(_ place: BrainSession.Place) -> String? {
        switch place {
        case .herdrWorkspace(let host, let id): Herdr.focusWorkspaceCommand(session: host, workspaceID: id)
        case .herdrTab(let host, _, let id): Herdr.focusTabCommand(session: host, tabID: id)
        case .herdrPane(let host, _, _, let pane):
            layout.snapshot(host).map { Herdr.focusCommand(session: host, paneID: pane, in: $0) }
                ?? Herdr.zoomCommand(session: host, paneID: pane, on: true)
        case .tab, .tmuxSession, .tmuxWindow: nil
        }
    }

    private func read(_ session: BrainSession) async -> String {
        guard let endpoint = endpoint(session) else { return Self.error("There is no screen to read there.") }
        let text: String?
        if case .local(let tab) = endpoint {
            text = io.screen(tab)
        } else if let command = SessionCommands.read(endpoint) {
            text = await io.exec(command)
        } else {
            text = nil
        }
        guard let text else { return Self.error("The host is not connected.") }
        var result: [String: Any] = ["target": session.spokenName, "screen": SessionCommands.cleanScreen(text)]
        if let status = session.status { result["status"] = status.rawValue }
        return AgentToolbox.json(result)
    }

    private func type(_ text: String, enter: Bool, into session: BrainSession) async -> String {
        guard let endpoint = endpoint(session) else { return Self.error("Nothing to type into there.") }
        let done = AgentToolbox.json(["typed": text, "target": session.spokenName, "enter": enter])
        if case .local(let tab) = endpoint {
            return io.type(tab, text + (enter ? "\r" : "")) ? done : Self.error("The tab is not connected.")
        }
        return await run(SessionCommands.text(endpoint, text, enter: enter) ?? "", herdr: session.isHerdr) { done }
    }

    private func rename(_ session: BrainSession, to name: String) async -> String {
        let done = AgentToolbox.json(["renamed": session.spokenName, "name": name])
        if case .tab(let id, _) = session.place {
            return io.renameTab(id, name) ? done : Self.error("Could not rename the tab.")
        }
        let result = await run(SessionCommands.rename(session, to: name) ?? "", herdr: session.isHerdr) { done }
        if case .tmuxSession(let old) = session.place, result == done { io.tmuxSessionRenamed(old, name) }
        return result
    }

    private func close(_ session: BrainSession) async -> String {
        let done = AgentToolbox.json(["closed": session.spokenName])
        if case .tab(let id, _) = session.place {
            return io.closeTab(id) ? done : Self.error("Could not close the tab.")
        }
        let result = await run(SessionCommands.close(session) ?? "", herdr: session.isHerdr) { done }
        guard result == done else { return result }
        for tab in io.tabs() {
            guard case .tmux(let name, let index, let windowID) = tab.backend else { continue }
            switch session.place {
            case .tmuxSession(let killed) where Tmux.baseSessionName(name) == killed:
                _ = io.closeTab(tab.id)
            case .tmuxWindow(let killed, let killedIndex, let killedID, _) where Tmux.baseSessionName(name) == killed:
                if windowID.map({ $0 == killedID }) ?? (index == killedIndex) { _ = io.closeTab(tab.id) }
            default:
                break
            }
        }
        return result
    }

    private func git(_ directory: String) async -> String {
        guard let output = await io.exec(SessionCommands.git(in: directory)) else {
            return Self.error("The host is not connected.")
        }
        guard !output.contains("not a git repository") else {
            return Self.error("\((directory as NSString).lastPathComponent) is not a git repository.")
        }
        let parts = output.components(separatedBy: "@@psh-status@@")
        let rest = parts.count > 1 ? parts[1].components(separatedBy: "@@psh-log@@") : []
        let changes = Git.parseStatus(rest.first ?? "")
        let commits = Git.parseLog(rest.count > 1 ? rest[1] : "")
        return AgentToolbox.json([
            "directory": directory,
            "branch": parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
            "changed_files": changes.count,
            "files": changes.prefix(15).map { "\($0.index)\($0.worktree) \($0.path)" },
            "recent_commits": commits.map { "\($0.date) \($0.subject)" },
        ])
    }

    private func run(_ command: String, herdr: Bool, done: () -> String) async -> String {
        guard !command.isEmpty else { return Self.error("That cannot be done there.") }
        guard let raw = await io.exec(AgentControl.checked(command)) else {
            return Self.error("The host is not connected.")
        }
        let (output, status) = AgentControl.splitExit(raw)
        if herdr, let failure = AgentControl.herdrFailure(output) { return Self.error(failure) }
        if status != 0 {
            return Self.error(
                "The command failed with status \(status). "
                    + output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))
        }
        return done()
    }

    private func keyQuestion(_ key: SessionKey, _ session: BrainSession) async -> String? {
        switch key {
        case .esc, .ctrlC:
            return session.status == .busy ? "Should I interrupt the \(session.spokenName)?" : nil
        case .ctrlD:
            return "Should I press control D in the \(session.spokenName)? It can end the shell there."
        case .enter:
            guard let screen = await screenText(session) else { return nil }
            let lastLine = screen.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if SafetyPolicy.isApprovalPrompt(screen)
                || (AgentStatus.classify(screen) == .waiting && SafetyPolicy.mentionsRisk(screen))
                || SafetyPolicy.mentionsRisk(String(lastLine ?? ""))
            {
                return "Should I press enter in the \(session.spokenName)? It approves what the screen asks."
            }
            return nil
        case .tab, .shiftTab, .up, .down, .left, .right:
            return nil
        }
    }

    private func screenText(_ session: BrainSession) async -> String? {
        guard let endpoint = endpoint(session) else { return nil }
        if case .local(let tab) = endpoint { return io.screen(tab) }
        guard let command = SessionCommands.read(endpoint) else { return nil }
        return await io.exec(command)
    }

    func endpoint(_ session: BrainSession) -> SessionEndpoint? {
        switch session.place {
        case .tab(let id, .shell):
            return .local(id)
        case .tab(_, .tmux(let name, let index, let windowID)):
            if let window = layout.windows.first(where: { SessionCatalog.windowMatches($0, name, index, windowID) }) {
                return .tmux(window.paneID)
            }
            return windowID.map(SessionEndpoint.tmux) ?? index.map { .tmux("\(name):\($0)") }
        case .tab(_, .herdr(let host, _)):
            return layout.snapshot(host).flatMap { HerdrOutline($0).focusedPaneID }.map {
                .herdr(session: host, paneID: $0)
            }
        case .tmuxSession(let name):
            let window =
                layout.windows.first(where: { $0.session == name && $0.active })
                ?? layout.windows.first(where: { $0.session == name })
            return .tmux(window?.paneID ?? "\(name):")
        case .tmuxWindow(_, _, _, let pane):
            return .tmux(pane)
        case .herdrWorkspace(let host, let id):
            guard
                let workspace = layout.snapshot(host).map(HerdrOutline.init)?.workspaces.first(where: {
                    $0.workspaceID == id
                }),
                let tab = workspace.tabs.first(where: \.focused) ?? workspace.tabs.first,
                let pane = tab.panes.first(where: \.focused) ?? tab.panes.first
            else { return nil }
            return .herdr(session: host, paneID: pane.paneID)
        case .herdrTab(let host, _, let id):
            guard let snapshot = layout.snapshot(host) else { return nil }
            let tab = HerdrOutline(snapshot).workspaces.flatMap(\.tabs).first { $0.tabID == id }
            let focused = snapshot.layouts?.first { $0.tabID == id }?.focusedPaneID
            guard let pane = focused ?? tab?.panes.first(where: \.focused)?.paneID ?? tab?.panes.first?.paneID else {
                return nil
            }
            return .herdr(session: host, paneID: pane)
        case .herdrPane(let host, _, _, let pane):
            return .herdr(session: host, paneID: pane)
        }
    }

    private func tmuxSession(_ session: BrainSession) -> String? {
        switch session.place {
        case .tmuxSession(let name), .tmuxWindow(let name, _, _, _), .tab(_, .tmux(let name, _, _)):
            Tmux.baseSessionName(name)
        default: nil
        }
    }

    private func herdrSession(_ session: BrainSession) -> String? {
        switch session.place {
        case .herdrWorkspace(let host, _), .herdrTab(let host, _, _), .herdrPane(let host, _, _, _),
            .tab(_, .herdr(let host, _)):
            host
        default: nil
        }
    }

    private func workspaceID(_ session: BrainSession) -> String? {
        switch session.place {
        case .herdrWorkspace(_, let id), .herdrTab(_, let id, _), .herdrPane(_, let id, _, _): id
        case .tab(_, .herdr(let host, let id)): id ?? layout.snapshot(host)?.focusedWorkspaceID
        default: nil
        }
    }

    private func agentCwd(_ session: BrainSession) -> String? {
        guard case .herdrPane(let host, _, _, let pane) = session.place else { return nil }
        return agents.first {
            if case .herdr(let agentHost, let agentPane, _, _) = $0.location {
                return agentHost == host && agentPane == pane
            }
            return false
        }?.cwd
    }

    private func snippet(named name: String) -> Snippet? {
        let key = AgentResolver.normalize(name)
        let snippets = io.snippets()
        return snippets.first { AgentResolver.normalize($0.name) == key }
            ?? snippets.first {
                let candidate = AgentResolver.normalize($0.name)
                return !candidate.isEmpty && (candidate.contains(key) || key.contains(candidate))
            }
    }

    struct DirectoryFailure: Error {
        let message: String
    }

    func resolveDirectory(_ spoken: String) async -> Result<String?, DirectoryFailure> {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { return .success(trimmed) }
        let key = Self.folderKey(trimmed)
        let known = (sessions.compactMap(\.cwd) + agents.compactMap(\.cwd)).filter { $0.hasPrefix("/") }
        if let match = known.first(where: { Self.folderKey(($0 as NSString).lastPathComponent) == key }) {
            return .success(match)
        }
        guard let output = await io.exec(SessionCommands.findDirectory(trimmed)) else {
            return .failure(DirectoryFailure(message: "The host is not connected."))
        }
        guard let path = output.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix("/") }) else {
            return .failure(DirectoryFailure(message: "No folder named \(trimmed) was found. Ask for the full path."))
        }
        return .success(path)
    }

    static func folderKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private func withTarget(
        _ name: String?, refresh: @MainActor () async -> Void, _ body: (BrainSession) async -> Outcome
    ) async -> Outcome {
        switch SessionResolver.resolve(name, in: sessions) {
        case .found(let session): return await body(session)
        case .ambiguous(let options):
            return .done(Self.error("Which one? " + options.prefix(6).map(\.spokenName).joined(separator: ", ")))
        case .none:
            await refresh()
            switch SessionResolver.resolve(name, in: sessions) {
            case .found(let session): return await body(session)
            case .ambiguous(let options):
                return .done(Self.error("Which one? " + options.prefix(6).map(\.spokenName).joined(separator: ", ")))
            case .none:
                if case .found(let agent) = AgentResolver.resolve(name, in: agents), let session = session(for: agent) {
                    return await body(session)
                }
                return .done(
                    Self.error("Nothing matches \(name ?? "the current tab"). Call list_sessions to see the names."))
            }
        }
    }

    private func withAgentTarget(
        _ name: String?, refresh: @MainActor () async -> Void, _ body: (BrainSession) async -> Outcome
    ) async -> Outcome {
        if case .found(let agent) = AgentResolver.resolve(name, in: agents), let session = session(for: agent) {
            return await body(session)
        }
        return await withTarget(name, refresh: refresh, body)
    }

    private func session(for agent: BrainAgent) -> BrainSession? {
        let all = sessions
        switch agent.location {
        case .tmux(_, _, let windowID, _):
            return all.first {
                if case .tab(_, .tmux(_, _, let shown)) = $0.place { return shown == windowID }
                return false
            } ?? all.first { $0.id == "window:\(windowID)" }
        case .herdr(let host, let pane, _, _):
            return all.first { $0.id == "herdr-pane:\(host):\(pane)" }
        }
    }

    static func quoted(_ text: String) -> String {
        "«" + (text.count > 80 ? String(text.prefix(80)) + "…" : text) + "»"
    }

    static func error(_ message: String) -> String { AgentToolbox.error(message) }

    nonisolated public static let definitions: [ToolDefinition] = [
        tool(
            "list_sessions",
            "List every terminal session on this host: the app's tabs (plain shell, tmux, Herdr), tmux sessions and "
                + "windows, and Herdr workspaces, tabs, and panes, with status, folder, and which one is current.",
            [:]),
        tool(
            "focus_session",
            "Show a tab, tmux window or session, or Herdr workspace, tab, or pane on the phone screen.",
            ["target": targetParameter]),
        tool(
            "read_screen", "Read the visible text of any tab, window, or pane, plain shells included.",
            ["target": targetParameter]),
        tool(
            "send_text", "Type text into any tab, window, or pane. Set enter to press Return after the text.",
            [
                "target": targetParameter, "text": .object(["type": "string", "description": "The exact text."]),
                "enter": .object(["type": "boolean"]),
            ], required: ["text"]),
        tool(
            "new_session",
            "Open a new terminal: a shell tab, a tmux window or session, or a Herdr tab, split, or workspace. Omit kind "
                + "to open the same kind as the current tab. It opens on the phone screen.",
            [
                "kind": .object([
                    "type": "string", "enum": .array(NewSession.Kind.allCases.map { .string($0.rawValue) }),
                ]),
                "directory": .object(["type": "string", "description": "Folder path, or just a folder name."]),
                "name": .object(["type": "string", "description": "Name for the new tab, window, or workspace."]),
                "agent": .object(["type": "string", "enum": .array(["claude", "codex"])]),
                "in": .object([
                    "type": "string",
                    "description":
                        "Where to open it: a tmux session or a Herdr workspace or pane. Omit for the current one.",
                ]),
            ]),
        tool(
            "rename", "Rename a tab, a tmux window or session, or a Herdr workspace, tab, or pane.",
            ["target": targetParameter, "name": .object(["type": "string"])], required: ["name"]),
        tool(
            "close",
            "Close a tab, or end a tmux window or session, or a Herdr workspace, tab, or pane. Closing an app tab that "
                + "shows tmux or Herdr keeps the window running.",
            ["target": targetParameter]),
        tool(
            "skip_permissions",
            "Restart Claude without permission prompts, or give Codex full access, for an agent.",
            [
                "agent": .object([
                    "type": "string", "description": "Agent or tab name. Omit for the agent in the current tab.",
                ])
            ]),
        tool(
            "git_status",
            "Read the git branch, changed files, and recent commits in the folder of a tab, window, or pane.",
            [
                "target": targetParameter,
                "directory": .object(["type": "string", "description": "Folder instead of a target."]),
            ]),
        tool(
            "run_snippet",
            "Run one of the user's saved snippets by name. Snippets that type into a terminal go to the target.",
            ["name": .object(["type": "string"]), "target": targetParameter], required: ["name"]),
    ]

    nonisolated static let targetParameter: JSONValue = .object([
        "type": "string",
        "description": .string(
            "Tab, window, pane, session, or workspace name as the app lists it, for example \"build tab\". "
                + "Omit for the current tab."),
    ])

    nonisolated private static func tool(
        _ name: String, _ description: String, _ properties: [String: JSONValue], required: [String] = []
    ) -> ToolDefinition {
        ToolDefinition(
            name: name, description: description,
            parameters: .object([
                "type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
            ]))
    }

    nonisolated public static let prompt = """
        The app also lists every terminal session in notes like "[app: Sessions now: ...]": the app's tabs, tmux \
        windows that no tab shows, and Herdr tabs and split panes. "This tab" is the current tab. You can show, \
        read, type into, open, rename, and close any of them with the session tools. Use read_screen to answer what \
        a tab or window shows, and summarize it. When the user asks for a new tab, call new_session without a kind \
        unless they name one; pass a folder name as directory when they name a folder.
        """
}

extension BrainSession {
    var isHerdr: Bool {
        switch place {
        case .herdrWorkspace, .herdrTab, .herdrPane, .tab(_, .herdr): true
        default: false
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
