import Foundation
import MonitorKit
import Testing
import TmuxKit

@testable import BrainKit

private func picker(_ name: String) throws -> ModelPicker {
    try #require(ModelPicker.parse(try fixture(name)))
}

private func allRows(_ names: [String]) throws -> [ModelRow] {
    var rows: [Int: ModelRow] = [:]
    for name in names {
        for row in try picker(name).rows where rows[row.number] == nil {
            var row = row
            row.isHighlighted = false
            rows[row.number] = row
        }
    }
    return rows.values.sorted { $0.number < $1.number }
}

private func claudeRows() throws -> [ModelRow] {
    try allRows(["claude-model-picker-top.txt", "claude-model-picker-bottom.txt"])
}

private func codexRows() throws -> [ModelRow] {
    try allRows(["codex-model-picker.txt", "codex-model-picker-bottom.txt"])
}

@Test func parsesClaudeModelMenusFromCapturedScreens() throws {
    let middle = try picker("claude-model-picker.txt")
    #expect(middle.step == .model)
    #expect(middle.rows.map(\.number) == Array(4...13))
    #expect(middle.highlighted == 13)
    #expect(middle.moreAbove && middle.moreBelow)
    let sonnet = try #require(middle.rows.last)
    #expect(sonnet.label == "Sonnet" && sonnet.isCurrent)
    #expect(sonnet.detail.hasPrefix("Sonnet 5.5 · Efficient for routine tasks"))

    let top = try picker("claude-model-picker-top.txt")
    #expect(top.rows.map(\.number) == Array(1...10))
    #expect(top.highlighted == 1 && !top.moreAbove && top.moreBelow)
    #expect(top.rows[0].label == "Default (recommended)")

    let bottom = try picker("claude-model-picker-bottom.txt")
    #expect(bottom.rows.map(\.number) == Array(5...14))
    #expect(bottom.moreAbove && !bottom.moreBelow)
    #expect(bottom.rows.last?.label == "Haiku" && bottom.rows.last?.isCurrent == true)
    #expect(bottom.rows.last?.detail.contains("for prompts over 100k") == true)
    #expect(try claudeRows().count == 14)
}

@Test func parsesCodexModelAndReasoningMenusFromCapturedScreens() throws {
    let top = try picker("codex-model-picker.txt")
    #expect(top.step == .model)
    #expect(top.rows.map(\.number) == Array(1...8))
    #expect(top.rows[0].label == "GPT-6.1-Sol" && top.rows[0].isCurrent && top.highlighted == 1)
    #expect(top.moreBelow && !top.moreAbove)

    let bottom = try picker("codex-model-picker-bottom.txt")
    #expect(bottom.moreAbove && !bottom.moreBelow)
    #expect(bottom.highlighted == 13 && bottom.rows.last?.label == "Claude Sonnet 5.5")
    #expect(bottom.rows.first { $0.number == 9 }?.detail.contains("spreadsheet, and slide work.") == true)

    let effort = try picker("codex-model-effort.txt")
    #expect(effort.step == .effort)
    #expect(effort.rows.map(\.label) == ["Low", "Medium (default)", "High", "Extra high", "More reasoning…"])
    #expect(effort.highlighted == 2)
    #expect(try codexRows().count == 13)
}

@Test func readsTheActiveModelFromTheScreenAfterASwitch() throws {
    let claude = try fixture("claude-model-switched.txt")
    #expect(ModelPicker.parse(claude) == nil)
    #expect(ModelPicker.confirmation(claude) == "Sonnet 5.5")
    #expect(AgentStatus.classify(claude) == .idle)
    #expect(ModelPicker.kept(try fixture("claude-model-kept.txt")) == "Sonnet 5.5")

    let codex = try fixture("codex-model-switched.txt")
    #expect(ModelPicker.confirmation(codex) == "gpt-6-luna high")
    #expect(ModelPicker.effort(in: codex, model: "GPT-6-Luna") == "high")
    let idle = try fixture("codex-model-idle.txt")
    #expect(ModelPicker.effort(in: idle, model: "GPT-6.1-Sol") == "high")
    #expect(AgentStatus.classify(idle) == .idle)
}

@Test func spokenModelNamesMapToMenuRows() throws {
    let claude = try claudeRows()
    func claudeMatch(_ text: String) -> Int? {
        if case .found(let row) = ModelMatch.resolve(text, in: claude) { return row.number }
        return nil
    }
    #expect(claudeMatch("sonnet") == 13)
    #expect(claudeMatch("Sonnet.") == 13)
    #expect(claudeMatch("opus") == 2)
    #expect(claudeMatch("opus five five") == 2)
    #expect(claudeMatch("Opus 5.5") == 2)
    #expect(claudeMatch("claude-sonnet-5-5") == 13)
    #expect(claudeMatch("the fast one") == 14)
    #expect(claudeMatch("haiku") == 14)
    #expect(claudeMatch("the default model") == 1)
    #expect(claudeMatch("claude fable five point two") == 4)
    #expect(ModelMatch.resolve("fable", in: claude) == .ambiguous(claude.filter { [3, 4].contains($0.number) }))
    #expect(ModelMatch.resolve("gemini", in: claude) == .none)
    #expect(ModelMatch.resolve("opus 4.1", in: claude) == .none)

    let codex = try codexRows()
    func codexMatch(_ text: String) -> Int? {
        if case .found(let row) = ModelMatch.resolve(text, in: codex) { return row.number }
        return nil
    }
    #expect(codexMatch("sonnet") == 13)
    #expect(codexMatch("gpt six point one sol") == 1)
    #expect(codexMatch("GPT 5.5") == 8)
    #expect(codexMatch("astra") == 2)
    if case .ambiguous(let options) = ModelMatch.resolve("luna", in: codex) {
        #expect(options.map(\.label) == ["GPT-6-Luna", "GPT-5.6-Luna"])
    } else {
        Issue.record("luna should be ambiguous")
    }
}

@Test func modelMenuCommandsTargetThePaneOrHerdrAgent() {
    let tmux = BrainAgent(
        kind: .claude, name: "api", location: .tmux(session: "work", windowIndex: 2, windowID: "@7", paneID: "%3"),
        status: .idle)
    let herdr = BrainAgent(
        kind: .codex, name: "infra",
        location: .herdr(session: "default", paneID: "w1:p3", tabID: "t", workspaceID: "w"),
        status: .idle)
    #expect(AgentControl.arrowCommand(tmux, up: false, count: 3).hasSuffix("send-keys -t '%3' Down Down Down"))
    #expect(AgentControl.arrowCommand(tmux, up: true, count: 1).hasSuffix("send-keys -t '%3' Up"))
    #expect(AgentControl.arrowCommand(herdr, up: true, count: 2).contains("agent send-keys 'w1:p3' up up"))
    let slash = AgentControl.slashCommand(tmux, "/model")
    #expect(slash.contains("send-keys -t '%3' -l -- '/model' && sleep 0.3 && "))
    #expect(slash.hasSuffix("send-keys -t '%3' Enter"))
}

@MainActor
final class FakeModelMenu {
    struct Row {
        var label: String
        var detail: String
    }

    let kind: AgentKind
    let rows: [Row]
    let window: Int
    var current: Int
    var effort: String
    var open = false
    var effortStep = false
    var highlight = 1
    var top = 1
    var effortHighlight = 2
    var messages: [String] = []
    var savedDefault = false
    var commands: [String] = []
    var screenOverride: String?

    init(kind: AgentKind, rows: [ModelRow], window: Int, current: Int, effort: String = "high") {
        self.kind = kind
        self.rows = rows.map { Row(label: $0.label, detail: $0.detail) }
        self.window = window
        self.current = current
        self.effort = effort
    }

    static let efforts = ["Low", "Medium (default)", "High", "Extra high", "More reasoning…"]

    func exec(_ command: String) -> String? {
        commands.append(command)
        if command.contains("list-panes") { return (try? fixture("list-agents.txt")) ?? "" }
        if command.contains("capture-pane") { return screenOverride ?? screen() }
        if command.contains("-l -- '/model'") {
            open = true
            effortStep = false
            highlight = current
            top = max(1, current - window + 1)
            return ""
        }
        if command.hasSuffix("-l -- 's'") {
            guard open else { return "" }
            if kind == .claude {
                current = highlight
                messages.append("  ⎿  Set model to \(name(current)) for this session only")
            } else if effortStep {
                current = highlight
                effort = Self.efforts[effortHighlight - 1].replacingOccurrences(of: " (default)", with: "")
                    .lowercased()
                messages.append(
                    "• Model changed to \(rows[current - 1].label.lowercased()) \(effort) for this session only")
            }
            open = false
            effortStep = false
            return ""
        }
        guard let range = command.range(of: "send-keys -t '%", options: .backwards) else { return "" }
        let keys = command[range.upperBound...].split(separator: " ").dropFirst()
        for key in keys {
            switch key {
            case "Down", "Up": press(up: key == "Up")
            case "Escape":
                if effortStep {
                    effortStep = false
                } else if open {
                    open = false
                    if kind == .claude { messages.append("  ⎿  Kept model as \(name(current))") }
                }
            case "Enter":
                guard open else { continue }
                if kind == .claude {
                    current = highlight
                    savedDefault = true
                    open = false
                } else if effortStep {
                    savedDefault = true
                    open = false
                } else {
                    effortStep = true
                    effortHighlight = 2
                }
            default: break
            }
        }
        return ""
    }

    func name(_ number: Int) -> String {
        let head = rows[number - 1].detail.components(separatedBy: " · ").first ?? ""
        return head.contains(where: \.isNumber) ? head : rows[number - 1].label
    }

    private func press(up: Bool) {
        guard open else { return }
        if effortStep {
            effortHighlight = (effortHighlight + (up ? -2 : 0) + Self.efforts.count) % Self.efforts.count + 1
            return
        }
        highlight = up ? (highlight == 1 ? rows.count : highlight - 1) : (highlight == rows.count ? 1 : highlight + 1)
        if highlight < top { top = highlight }
        if highlight >= top + window { top = highlight - window + 1 }
    }

    private func screen() -> String {
        var lines = ["", "", ""] + messages
        if open {
            lines += kind == .claude ? claudeMenu() : codexMenu()
        } else if kind == .claude {
            lines += [String(repeating: "─", count: 60), "❯ ", String(repeating: "─", count: 60), "  ? for shortcuts"]
        } else {
            lines += ["› Ask Codex to do anything", "", "  \(rows[current - 1].label) \(effort) · /Users/dev/src/web"]
        }
        return lines.joined(separator: "\n")
    }

    private func claudeMenu() -> [String] {
        var lines = ["   Select model", "   Switch between Claude models.", ""]
        let bottom = min(rows.count, top + window - 1)
        for number in top...bottom {
            let marker =
                number == highlight
                ? "❯" : number == top && top > 1 ? "↑" : number == bottom && bottom < rows.count ? "↓" : " "
            let label = rows[number - 1].label + (number == current ? " ✔" : "")
            lines.append(
                "   \(marker) \(number).  \(label.padding(toLength: 24, withPad: " ", startingAt: 0))  "
                    + rows[number - 1].detail)
        }
        if bottom < rows.count { lines.append("      … +\(rows.count - bottom) models") }
        return lines + ["", "   Enter to set as default · s to use this session only · Esc to cancel"]
    }

    private func codexMenu() -> [String] {
        if effortStep {
            var lines = ["  Select Reasoning Level for \(rows[highlight - 1].label)"]
            for (index, label) in Self.efforts.enumerated() {
                lines.append("\(index + 1 == effortHighlight ? "›" : " ") \(index + 1). \(label)  Reasoning")
            }
            return lines + ["  enter default · s session · esc back"]
        }
        var lines = ["  Select Model and Effort"]
        if top > 1 { lines.append("↑") }
        let bottom = min(rows.count, top + window - 1)
        for number in top...bottom {
            let label = rows[number - 1].label + (number == current ? " (current)" : "")
            lines.append("\(number == highlight ? "›" : " ") \(number). \(label)  \(rows[number - 1].detail)")
        }
        if bottom < rows.count { lines.append("↓") }
        return lines + ["  enter select · esc back"]
    }
}

@MainActor
private func toolbox(_ menu: FakeModelMenu, unsent: String? = nil) -> AgentToolbox {
    AgentToolbox(
        io: .init(
            exec: { menu.exec($0) }, focus: { _ in true }, unsentPrompt: { _ in unsent }, sleep: { _ in }))
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

@MainActor
@Test func setModelSwitchesClaudeForThisSessionOnlyThroughItsMenu() async throws {
    let menu = FakeModelMenu(kind: .claude, rows: try claudeRows(), window: 10, current: 14)
    let result = try object(
        await toolbox(menu).call(
            ToolCall(id: "1", name: "set_model", arguments: #"{"agent":"Claude in api","model":"sonnet five five"}"#)))
    #expect(result["model"] as? String == "Sonnet 5.5")
    #expect(result["switched"] as? Bool == true)
    #expect(menu.current == 13 && !menu.open)
    #expect(!menu.savedDefault)
    let afterOpen = menu.commands.drop { !$0.contains("'/model'") }.dropFirst()
    #expect(!afterOpen.contains { $0.hasSuffix(" Enter") })
    #expect(afterOpen.contains { $0.hasSuffix("-l -- 's'") })
}

@MainActor
@Test func setModelPagesThroughAMenuLongerThanItsWindow() async throws {
    let menu = FakeModelMenu(kind: .claude, rows: try claudeRows(), window: 4, current: 2)
    let result = try object(
        await toolbox(menu).call(
            ToolCall(id: "1", name: "set_model", arguments: #"{"agent":"api","model":"the fast one"}"#)))
    #expect(result["model"] as? String == "Haiku 5.5")
    #expect(menu.current == 14 && !menu.savedDefault)
}

@MainActor
@Test func getModelReadsTheActiveModelAndChoicesAndLeavesItUnchanged() async throws {
    let menu = FakeModelMenu(kind: .claude, rows: try claudeRows(), window: 10, current: 14)
    let result = try object(
        await toolbox(menu).call(ToolCall(id: "1", name: "get_model", arguments: #"{"agent":"Claude in api"}"#)))
    #expect(result["model"] as? String == "Haiku 5.5")
    let choices = try #require(result["choices"] as? [String])
    #expect(choices.count == 14)
    #expect(choices.contains("Sonnet: Sonnet 5.5, Efficient for routine tasks"))
    #expect(menu.current == 14 && !menu.open && !menu.savedDefault)
}

@MainActor
@Test func unclearModelNamesReturnTheChoicesAndCloseTheMenu() async throws {
    let menu = FakeModelMenu(kind: .claude, rows: try claudeRows(), window: 10, current: 14)
    let box = toolbox(menu)
    let unknown = try object(
        await box.call(ToolCall(id: "1", name: "set_model", arguments: #"{"agent":"api","model":"gemini"}"#)))
    #expect((unknown["error"] as? String)?.contains("gemini") == true)
    #expect((unknown["choices"] as? [String])?.count == 14)
    #expect(!menu.open && menu.current == 14)
    let ambiguous = try object(
        await box.call(ToolCall(id: "2", name: "set_model", arguments: #"{"agent":"api","model":"fable"}"#)))
    #expect(ambiguous["choices"] as? [String] == ["Claude Fable 5.1", "Claude Fable 5.2"])
    #expect(!menu.open && menu.current == 14 && !menu.savedDefault)
}

@MainActor
@Test func setModelSwitchesCodexAndKeepsTheReasoningLevel() async throws {
    let menu = FakeModelMenu(kind: .codex, rows: try codexRows(), window: 8, current: 1, effort: "high")
    let result = try object(
        await toolbox(menu).call(
            ToolCall(id: "1", name: "set_model", arguments: #"{"agent":"Codex in web","model":"luna six"}"#)))
    #expect(result["model"] as? String == "gpt-6-luna high")
    #expect(menu.current == 4 && menu.effort == "high")
    #expect(!menu.savedDefault && !menu.open)
}

@MainActor
@Test func setModelRefusesABusyAgentOrAnUnsentPromptAndTypesNothing() async throws {
    let menu = FakeModelMenu(kind: .claude, rows: try claudeRows(), window: 10, current: 14)
    menu.screenOverride = "⏺ Working\n\n✻ Thinking… (12s · esc to interrupt)\n> \n  ? for shortcuts"
    let busy = try object(
        await toolbox(menu).call(ToolCall(id: "1", name: "set_model", arguments: #"{"agent":"api","model":"opus"}"#)))
    #expect((busy["error"] as? String)?.contains("is working") == true)
    #expect(!menu.commands.contains { $0.contains("send-keys") })

    menu.screenOverride = nil
    let unsent = try object(
        await toolbox(menu, unsent: "fix the login test").call(
            ToolCall(id: "2", name: "set_model", arguments: #"{"agent":"api","model":"opus"}"#)))
    #expect((unsent["error"] as? String)?.contains("«fix the login test»") == true)
    #expect(!menu.commands.contains { $0.contains("send-keys") })
    #expect(menu.current == 14)
}

@Test func theBrainKnowsItCanSwitchAgentModels() {
    let names = AgentToolbox.definitions.map(\.name)
    #expect(names.contains("set_model") && names.contains("get_model"))
    let prompt = BrainPrompt.system(hostName: "devbox")
    #expect(prompt.contains("set_model"))
    #expect(prompt.contains("Never tell the user to open a menu or a model picker"))
}
