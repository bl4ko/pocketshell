import Foundation
import HerdrKit
import Testing

@MainActor
private final class FakeHerdr {
    var snapshot: HerdrSnapshot
    var commands: [String] = []
    var reachable = true
    var holdZoomIn = false
    private(set) var held: CheckedContinuation<Void, Never>?

    init() {
        let json = """
            {"result":{"snapshot":{"version":"0.9.5","protocol":3,"focused_workspace_id":"w1","focused_tab_id":"w1:t1",
            "focused_pane_id":"w1:p1",
            "workspaces":[{"workspace_id":"w1","number":1,"label":"home","agent_status":"working","focused":true}],
            "agents":[{"agent":"claude","agent_status":"working","focused":true,"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}],
            "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"3d print","number":1},
                    {"tab_id":"w1:t2","workspace_id":"w1","label":"logs","number":2}],
            "panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"claude","agent_status":"working","focused":true},
                     {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","agent_status":"unknown","focused":false},
                     {"pane_id":"w1:p3","workspace_id":"w1","tab_id":"w1:t2","agent_status":"unknown","focused":false},
                     {"pane_id":"w1:p4","workspace_id":"w1","tab_id":"w1:t2","agent_status":"unknown","focused":false}],
            "layouts":[{"tab_id":"w1:t1","focused_pane_id":"w1:p1","zoomed":false,"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]},
                       {"tab_id":"w1:t2","focused_pane_id":"w1:p3","zoomed":false,"panes":[{"pane_id":"w1:p3"},{"pane_id":"w1:p4"}]}]
            }}}
            """
        snapshot = Herdr.parseSnapshot(json)!
    }

    var zoomedTabs: Set<String> {
        Set((snapshot.layouts ?? []).filter(\.zoomed).map(\.tabID))
    }

    var zoomCommands: [String] { commands.filter { $0.contains("pane zoom") } }

    func focus(tab tabID: String) {
        guard let layout = snapshot.layouts?.first(where: { $0.tabID == tabID }) else { return }
        snapshot.focusedTabID = tabID
        snapshot.focusedPaneID = layout.focusedPaneID
    }

    func setZoom(tab tabID: String, _ on: Bool) {
        snapshot.layouts = snapshot.layouts?.map {
            var layout = $0
            if layout.tabID == tabID { layout.zoomed = on }
            return layout
        }
    }

    func releaseHeld() {
        held?.resume()
        held = nil
    }

    lazy var exec: HerdrZoomKeeper.Exec = { [unowned self] command in await self.run(command) }

    private func run(_ command: String) async -> String? {
        commands.append(command)
        guard reachable else { return nil }
        if command.hasSuffix("api snapshot") {
            let data = try! JSONEncoder().encode(["result": ["snapshot": snapshot]])
            return String(decoding: data, as: UTF8.self)
        }
        let zooms = command.matches(of: /pane zoom '([^']+)' --(on|off)/)
        if holdZoomIn, zooms.contains(where: { $0.2 == "on" }) {
            await withCheckedContinuation { held = $0 }
        }
        for zoom in zooms {
            let pane = String(zoom.1)
            guard let tab = snapshot.panes?.first(where: { $0.paneID == pane })?.tabID else { continue }
            setZoom(tab: tab, zoom.2 == "on")
        }
        return ""
    }
}

@MainActor
private func keeper(_ defaults: UserDefaults) -> HerdrZoomKeeper {
    HerdrZoomKeeper(ledgerKey: "host-1", defaults: defaults)
}

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "herdr-zoom-\(UUID().uuidString)")!
}

@MainActor
@Test func focusModeZoomsTheFocusedSplitAndExitUndoesIt() async {
    let herdr = FakeHerdr()
    let zoom = keeper(freshDefaults())

    await zoom.setFocusMode(true, session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs == ["w1:t1"])
    await zoom.setFocusMode(false, session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs.isEmpty)
    #expect(zoom.owned(session: "default").isEmpty)
}

@MainActor
@Test func aZoomLeftByAKilledAppIsUndoneOnTheNextConnect() async {
    let herdr = FakeHerdr()
    let defaults = freshDefaults()
    await keeper(defaults).setFocusMode(true, session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs == ["w1:t1"])

    let relaunched = keeper(defaults)
    await relaunched.settle(session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs.isEmpty)
    #expect(relaunched.owned(session: "default").isEmpty)
}

@MainActor
@Test func anExitThatCannotReachHerdrKeepsTheZoomToUndoLater() async {
    let herdr = FakeHerdr()
    let zoom = keeper(freshDefaults())
    await zoom.setFocusMode(true, session: "default", exec: herdr.exec)

    herdr.reachable = false
    await zoom.setFocusMode(false, session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs == ["w1:t1"])
    #expect(zoom.owned(session: "default") == ["w1:t1"])

    herdr.reachable = true
    await zoom.settle(session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs.isEmpty)
}

@MainActor
@Test func theBackgroundUndoesTheZoomAndTheForegroundRestoresFocusMode() async {
    let herdr = FakeHerdr()
    let zoom = keeper(freshDefaults())
    await zoom.setFocusMode(true, session: "default", exec: herdr.exec)

    await zoom.release(session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs.isEmpty)
    #expect(zoom.focusMode)

    await zoom.settle(session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs == ["w1:t1"])
}

@MainActor
@Test func everyTabFocusModeVisitsIsUndoneOnExit() async {
    let herdr = FakeHerdr()
    let zoom = keeper(freshDefaults())
    await zoom.setFocusMode(true, session: "default", exec: herdr.exec)
    herdr.focus(tab: "w1:t2")
    await zoom.settle(session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs == ["w1:t1", "w1:t2"])

    await zoom.setFocusMode(false, session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs.isEmpty)
}

@MainActor
@Test func aUsersOwnZoomIsNeitherClaimedNorUndone() async {
    let herdr = FakeHerdr()
    herdr.setZoom(tab: "w1:t1", true)
    let zoom = keeper(freshDefaults())

    await zoom.setFocusMode(true, session: "default", exec: herdr.exec)
    await zoom.setFocusMode(false, session: "default", exec: herdr.exec)
    await zoom.settle(session: "default", exec: herdr.exec)
    #expect(herdr.zoomCommands.isEmpty)
    #expect(herdr.zoomedTabs == ["w1:t1"])
}

@MainActor
@Test func aZoomHerdrAlreadyUndidIsForgottenSoALaterUserZoomStays() async {
    let herdr = FakeHerdr()
    let zoom = keeper(freshDefaults())
    await zoom.setFocusMode(true, session: "default", exec: herdr.exec)
    herdr.setZoom(tab: "w1:t1", false)
    herdr.focus(tab: "w1:t2")
    await zoom.settle(session: "default", exec: herdr.exec)
    #expect(zoom.owned(session: "default") == ["w1:t2"])

    herdr.setZoom(tab: "w1:t1", true)
    await zoom.setFocusMode(false, session: "default", exec: herdr.exec)
    #expect(herdr.zoomedTabs == ["w1:t1"])
}

@MainActor
@Test func leavingFocusModeWhileItsZoomIsInFlightStillUndoesIt() async {
    let herdr = FakeHerdr()
    herdr.holdZoomIn = true
    let zoom = keeper(freshDefaults())

    let entering = Task { await zoom.setFocusMode(true, session: "default", exec: herdr.exec) }
    while herdr.held == nil { await Task.yield() }
    let leaving = Task { await zoom.setFocusMode(false, session: "default", exec: herdr.exec) }
    for _ in 0..<20 { await Task.yield() }
    herdr.releaseHeld()
    await entering.value
    await leaving.value

    #expect(herdr.zoomedTabs.isEmpty)
    #expect(zoom.owned(session: "default").isEmpty)
}

@MainActor
@Test func zoomsAreKeptPerSessionAndNothingIsSentWithoutOne() async {
    let herdr = FakeHerdr()
    let zoom = keeper(freshDefaults())
    await zoom.setFocusMode(true, session: "default", exec: herdr.exec)
    #expect(zoom.owned(session: "other").isEmpty)

    let quiet = FakeHerdr()
    await keeper(freshDefaults()).settle(session: "default", exec: quiet.exec)
    #expect(quiet.commands.isEmpty)
}
