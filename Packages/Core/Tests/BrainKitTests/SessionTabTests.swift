import Foundation
import Testing

@testable import BrainKit

@Test func sessionNoteNamesEverySessionByTitleAndNumbersTabs() throws {
    let note = SessionCatalog.snapshot(try titleCatalog(titleTabs))
    #expect(
        note
            == "[app: Sessions now: tab 1 \"claude\" aka \"CPAMC\" (tmux dev, claude); "
            + "tab 2 \"herdr\" aka \"POCKETSHELL\" (Herdr, busy, current); tab 3 \"3\" (shell); "
            + "tmux window 0 \"zsh\" in dev; tmux window 2 \"QBIT-FIX\" aka \"web|tools\" in dev (codex); "
            + "tmux window 3 \"node\" in dev (busy); "
            + "Herdr workspace 1 \"infra\": tab 1 \"HW-PROXY | iris\" aka \"hw\" (claude, done); "
            + "Herdr workspace 2 \"pocketshell\" (current): tab 1 \"POCKETSHELL\" (claude, busy, current), tab 2 \"2\".]"
    )
}

@Test func ordinalTabsFollowTheHerdrTabBarWhenHerdrIsOnScreen() throws {
    let sessions = try titleCatalog(titleTabs)
    #expect(resolvedID("second tab", in: sessions) == "herdr-tab:default:w2:t2")
    #expect(resolvedID("the 2nd tab", in: sessions) == "herdr-tab:default:w2:t2")
    #expect(resolvedID("tab 1", in: sessions) == "herdr-tab:default:w2:t1")
    #expect(resolvedID("tab two", in: sessions) == "herdr-tab:default:w2:t2")
    #expect(resolvedID("last tab", in: sessions) == "herdr-tab:default:w2:t2")
    #expect(resolvedID("next tab", in: sessions) == "herdr-tab:default:w2:t2")
    #expect(resolvedID("previous tab", in: sessions) == "herdr-tab:default:w2:t2")
    #expect(resolvedID("app tab 3", in: sessions) == "tab:t3")
    #expect(resolvedID("first workspace", in: sessions) == "herdr-workspace:default:w1")
    #expect(resolvedID("workspace 2", in: sessions) == "herdr-workspace:default:w2")
    #expect(resolvedID("fifth tab", in: sessions) == nil)
}

@Test func ordinalTabsFollowTheAppTabStripAndWindowsTheTmuxSession() throws {
    let sessions = try titleCatalog(titleTabsWith(currentID: "t1"))
    #expect(resolvedID("second tab", in: sessions) == "tab:t2")
    #expect(resolvedID("tab 3", in: sessions) == "tab:t3")
    #expect(resolvedID("last tab", in: sessions) == "tab:t3")
    #expect(resolvedID("second window", in: sessions) == "window:@2")
    #expect(resolvedID("window 3", in: sessions) == "window:@4")
    #expect(resolvedID("next window", in: sessions) == "window:@3")
    #expect(resolvedID("tmux tab 0", in: sessions) == "window:@1")
    #expect(resolvedID("herdr tab 2", in: sessions) == "herdr-tab:default:w2:t2")
}

@MainActor
private final class FocusRecorder {
    var tabs = titleTabs
    var commands: [String] = []
    var focused: [BrainSession.Place] = []
}

@MainActor
@Test func focusSessionSwitchesHerdrAndAppTabsByPosition() async throws {
    let list = try fixture("list-titles.txt")
    let state = FocusRecorder()
    let toolbox = SessionToolbox(
        io: .init(
            exec: { command in
                state.commands.append(command)
                return command.contains("list-panes -a") ? list : ""
            },
            tabs: { state.tabs },
            focus: { place in
                state.focused.append(place)
                return true
            }))
    toolbox.ingest(list, agents: HostAgents.parse(list))
    func focus(_ target: String) async -> String {
        guard
            case .done(let result) = await toolbox.call(
                ToolCall(id: "c", name: "focus_session", arguments: "{\"target\":\"\(target)\"}"), refresh: {})
        else { return "" }
        return result
    }

    #expect(await focus("second tab").contains("\"done\""))
    #expect(state.focused.last == .herdrTab(session: "default", workspaceID: "w2", tabID: "w2:t2"))
    #expect(state.commands.last?.hasSuffix("tab focus 'w2:t2'") == true)

    _ = await focus("hw-proxy")
    #expect(state.focused.last == .herdrTab(session: "default", workspaceID: "w1", tabID: "w1:t1"))
    #expect(state.commands.last?.hasSuffix("tab focus 'w1:t1'") == true)

    state.tabs = titleTabsWith(currentID: "t3")
    _ = await focus("second tab")
    #expect(state.focused.last == .tab(id: "t2", backend: .herdr(session: "default", workspaceID: "w2")))
}
