import Foundation

@testable import BrainKit

enum FakeInput: Equatable {
    case text(String)
    case key(String)

    static func parse(_ command: String) -> [FakeInput] {
        guard let range = command.range(of: "send-keys -t '%", options: .backwards) else { return [] }
        let rest = command[range.upperBound...].drop { $0 != " " }.dropFirst()
        if rest.hasPrefix("-l -- ") {
            var quoted = String(rest.dropFirst(6))
            if let end = quoted.range(of: " && ") { quoted = String(quoted[..<end.lowerBound]) }
            return [.text(unquote(quoted))]
        }
        return rest.split(separator: " ").map { .key(String($0)) }
    }

    static func unquote(_ quoted: String) -> String {
        var text = quoted
        if text.hasPrefix("'") { text.removeFirst() }
        if text.hasSuffix("'") { text.removeLast() }
        return text.replacingOccurrences(of: "'\\''", with: "'")
    }
}

@MainActor
class FakePane {
    var commands: [String] = []
    var inputs: [FakeInput] = []
    var listsScreen = false

    func exec(_ command: String) -> String? {
        commands.append(command)
        if command.contains("list-panes") {
            guard listsScreen else { return (try? fixture("list-agents.txt")) ?? "" }
            return "@@psh-tmux:%3|4101|claude|work|2|@7|api@@\n@@psh-cwd@@\n/home/dev/src/api\n@@psh-screen@@\n"
                + screen()
        }
        if command.contains("capture-pane") { return screen() }
        for input in FakeInput.parse(command) {
            inputs.append(input)
            switch input {
            case .text(let text):
                if text.count == 1, let digit = Int(text) { press("\(digit)") } else { type(text) }
            case .key(let key): press(key)
            }
        }
        return ""
    }

    func screen() -> String { "" }
    func press(_ key: String) {}
    func type(_ text: String) {}

    var pressedKeys: [String] {
        inputs.map {
            switch $0 {
            case .key(let key): key
            case .text(let text): "«\(text)»"
            }
        }
    }
}

@MainActor
final class FakeClaudeAsk: FakePane {
    struct Question {
        var header: String
        var text: String
        var options: [(label: String, detail: String)]
        var multi = false
    }

    let questions: [Question]
    let window: Int
    var index = 0
    var focus = 0
    var top = 0
    var onButton = false
    var reviewFocus = 0
    var checked: [Int: Set<Int>] = [:]
    var picked: [Int: Int] = [:]
    var other: [Int: String] = [:]
    var answered: [Int: String] = [:]
    var outcome: String?

    init(_ questions: [Question], window: Int = 9) {
        self.questions = questions
        self.window = window
    }

    var question: Question { questions[index] }
    var hideSubmitTab: Bool { questions.count == 1 && !questions[0].multi }
    var onReview: Bool { index == questions.count }
    var rowCount: Int { question.options.count + 1 }

    override func press(_ key: String) {
        guard outcome == nil else { return }
        if onReview { return reviewKey(key) }
        if key == "Escape" { return finish("declined") }
        if !hideSubmitTab, key == "Left" || key == "Right" {
            index = max(0, min(questions.count, index + (key == "Left" ? -1 : 1)))
            focus = 0
            top = 0
            onButton = false
            return
        }
        switch key {
        case "Up":
            if onButton {
                onButton = false
            } else {
                focus = max(0, focus - 1)
            }
        case "Down":
            if focus == rowCount - 1, question.multi {
                onButton = true
            } else if !onButton {
                focus = min(rowCount - 1, focus + 1)
            }
        case "Space":
            if question.multi, !onButton { toggle(focus) }
        case "Enter":
            if question.multi {
                if onButton { advance(label: summary()) } else { toggle(focus) }
            } else if focus < question.options.count {
                pick(focus)
            } else if let text = other[index], !text.isEmpty {
                picked[index] = focus
                advance(label: text)
            }
        default:
            guard let digit = Int(key), digit >= 1 else { return }
            if question.multi, focus != rowCount - 1 {
                if digit <= rowCount { toggle(digit - 1) }
            } else if !question.multi, focus != rowCount - 1 {
                if digit <= question.options.count {
                    pick(digit - 1)
                } else if digit == rowCount {
                    focus = digit - 1
                }
            } else {
                type(key)
            }
        }
        scroll()
    }

    override func type(_ text: String) {
        guard outcome == nil, !onReview, !onButton else { return }
        if focus == rowCount - 1 {
            other[index, default: ""] += text
            if question.multi { checked[index, default: []].insert(focus) }
        }
    }

    private func toggle(_ row: Int) {
        var set = checked[index, default: []]
        if set.contains(row) { set.remove(row) } else { set.insert(row) }
        checked[index] = set
        answered[index] = set.isEmpty ? nil : summary()
    }

    private func pick(_ row: Int) {
        picked[index] = row
        advance(label: question.options[row].label)
    }

    private func summary() -> String {
        checked[index, default: []].sorted().map {
            $0 < question.options.count ? question.options[$0].label : other[index] ?? ""
        }
        .joined(separator: ", ")
    }

    private func advance(label: String) {
        answered[index] = label.isEmpty ? nil : label
        if hideSubmitTab { return finish("answered") }
        index += 1
        focus = 0
        top = 0
        onButton = false
        reviewFocus = 0
    }

    private func reviewKey(_ key: String) {
        switch key {
        case "Up", "1": reviewFocus = 0
        case "Down", "2": reviewFocus = 1
        case "Left": index -= 1
        case "Escape": finish("declined")
        default: break
        }
        if key == "Enter" || key == "1" || key == "2" { finish(reviewFocus == 0 ? "answered" : "declined") }
    }

    private func finish(_ result: String) {
        outcome = result
    }

    private func scroll() {
        if focus < top { top = focus }
        if focus >= top + window { top = focus - window + 1 }
    }

    override func screen() -> String {
        var lines = ["⏺ Working on it.", "", "❯ plan the cache work", String(repeating: "─", count: 80)]
        if let outcome {
            let summary = (0..<questions.count).compactMap { i in
                answered[i].map { "     · \(questions[i].text) → \($0)" }
            }
            lines +=
                outcome == "answered"
                ? ["⏺ User answered Claude's questions:"] + summary : ["⏺ User declined to answer questions"]
            return
                (lines + [
                    "", String(repeating: "─", count: 80), "❯ ", String(repeating: "─", count: 80), "  ? for shortcuts",
                ])
                .joined(separator: "\n")
        }
        if hideSubmitTab {
            lines.append(" ☐ \(question.header)")
        } else {
            let tabs = questions.indices.map { "\(answered[$0] == nil ? "☐" : "☒") \(questions[$0].header)" }
            lines.append("←  " + tabs.joined(separator: "  ") + "  ✔ Submit  →")
        }
        lines.append("")
        if onReview { return (lines + review()).joined(separator: "\n") }
        lines += [question.text, ""]
        let bottom = min(rowCount, top + window)
        for row in top..<bottom {
            let marker =
                !onButton && row == focus
                ? "❯" : row == top && top > 0 ? "↑" : row == bottom - 1 && bottom < rowCount ? "↓" : " "
            let isOther = row == question.options.count
            let text = other[index].flatMap { $0.isEmpty ? nil : $0 }
            if question.multi {
                let box = checked[index, default: []].contains(row) ? "[✔]" : "[ ]"
                lines.append(
                    "\(marker) \(row + 1). \(box) " + (isOther ? text ?? "Type something" : question.options[row].label)
                )
                if !isOther, !question.options[row].detail.isEmpty {
                    lines.append("         " + question.options[row].detail)
                }
            } else {
                lines.append(
                    "\(marker) \(row + 1). " + (isOther ? text ?? "Type something." : question.options[row].label))
                if !isOther, !question.options[row].detail.isEmpty {
                    lines.append("     " + question.options[row].detail)
                }
            }
        }
        if question.multi {
            lines.append((onButton ? "❯" : " ") + "    " + (index == questions.count - 1 ? "Submit" : "Next"))
        }
        lines += [String(repeating: "─", count: 80), "  \(rowCount + 1). Chat about this", ""]
        lines.append(
            "Enter to select · " + (questions.count == 1 ? "↑/↓ to navigate" : "Tab/Arrow keys to navigate")
                + " · Esc to cancel")
        return lines.joined(separator: "\n")
    }

    private func review() -> [String] {
        var lines = ["Review your answers", ""]
        if answered.count < questions.count { lines += ["⚠ You have not answered all questions", ""] }
        for i in questions.indices {
            guard let answer = answered[i] else { continue }
            lines += [" ● \(questions[i].text)", "   → \(answer)"]
        }
        lines += ["", "Ready to submit your answers?", ""]
        lines.append("\(reviewFocus == 0 ? "❯" : " ") 1. Submit answers")
        lines.append("\(reviewFocus == 1 ? "❯" : " ") 2. Cancel")
        return lines
    }
}

@MainActor
final class FakeCodexAsk: FakePane {
    struct Question {
        var text: String
        var options: [(label: String, detail: String)]
    }

    let questions: [Question]
    var index = 0
    var selected: [Int: Int] = [:]
    var committed: Set<Int> = []
    var notes: [Int: String] = [:]
    var notesFocus = false
    var confirm: Int?
    var outcome: String?

    init(_ questions: [Question]) {
        self.questions = questions
    }

    var rowCount: Int { questions[index].options.count + 1 }
    var unanswered: Int { questions.indices.filter { !committed.contains($0) }.count }

    override func press(_ key: String) {
        guard outcome == nil else { return }
        if let focus = confirm {
            switch key {
            case "Up", "Down": confirm = 1 - focus
            case "1": proceed()
            case "2", "Escape": goBack()
            case "Enter": focus == 0 ? proceed() : goBack()
            default: break
            }
            return
        }
        let current = selected[index] ?? 0
        switch key {
        case "Up", "Down":
            selected[index] = (current + (key == "Up" ? rowCount - 1 : 1)) % rowCount
            committed.remove(index)
        case "Left", "Right":
            guard !notesFocus else { return }
            index = max(0, min(questions.count - 1, index + (key == "Left" ? -1 : 1)))
        case "Escape":
            if notesFocus {
                notesFocus = false
                notes[index] = nil
            } else {
                outcome = "interrupted"
            }
        case "Enter":
            if !notesFocus, current == rowCount - 1 {
                notesFocus = true
            } else {
                commit()
            }
        default:
            guard let digit = Int(key) else { return }
            if notesFocus { return type(key) }
            guard (1...rowCount).contains(digit) else { return }
            selected[index] = digit - 1
            commit()
        }
    }

    override func type(_ text: String) {
        guard outcome == nil, notesFocus else { return }
        notes[index, default: ""] += text
    }

    private func commit() {
        committed.insert(index)
        notesFocus = false
        if index + 1 >= questions.count {
            if unanswered > 0 { confirm = 0 } else { outcome = "submitted" }
        } else {
            index += 1
        }
    }

    private func proceed() {
        confirm = nil
        outcome = "submitted"
    }

    private func goBack() {
        confirm = nil
        index = questions.indices.first { !committed.contains($0) } ?? index
    }

    func answer(_ i: Int) -> String? {
        guard committed.contains(i) else { return nil }
        let row = selected[i] ?? 0
        return row < questions[i].options.count
            ? questions[i].options[row].label : "None of the above: \(notes[i] ?? "")"
    }

    override func screen() -> String {
        var lines = ["• I need a few answers before I continue.", ""]
        if let outcome {
            lines +=
                outcome == "submitted"
                ? ["• Thanks, continuing.", "", "› Ask Codex to do anything", "", "  86% context left"]
                : ["■ Conversation interrupted", "", "› Ask Codex to do anything", "", "  86% context left"]
            return lines.joined(separator: "\n")
        }
        if let focus = confirm {
            lines += [
                "  Submit with unanswered questions?",
                "  \(unanswered) unanswered question\(unanswered == 1 ? "" : "s")",
                "",
                "\(focus == 0 ? "›" : " ") 1. Proceed  Submit with \(unanswered) unanswered question\(unanswered == 1 ? "" : "s")",
                "\(focus == 1 ? "›" : " ") 2. Go back  Return to the first unanswered question", "",
                "  Press enter to confirm or esc to go back",
            ]
            return lines.joined(separator: "\n")
        }
        let question = questions[index]
        lines.append(
            "  Question \(index + 1)/\(questions.count)" + (unanswered > 0 ? " (\(unanswered) unanswered)" : ""))
        lines.append("  \(question.text)")
        let current = selected[index] ?? 0
        for row in 0..<rowCount {
            let label = row < question.options.count ? question.options[row].label : "None of the above"
            let detail =
                row < question.options.count ? question.options[row].detail : "Optionally, add details in notes (tab)"
            lines.append("  \(row == current ? "›" : " ") \(row + 1). \(label)  \(detail)")
        }
        if notesFocus { lines += ["", "  › \(notes[index] ?? "")"] }
        let tips =
            (notesFocus ? "tab or esc to clear notes" : "tab to add notes")
            + (index + 1 == questions.count ? " | enter to submit all" : " | enter to submit answer")
            + (questions.count > 1 && !notesFocus ? " | ←/→ to navigate questions" : "")
        lines.append("  " + tips)
        return lines.joined(separator: "\n")
    }
}
