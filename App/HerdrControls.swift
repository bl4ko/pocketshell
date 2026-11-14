import Foundation
import HerdrKit

@MainActor
final class HerdrState: ObservableObject {
    @Published var snapshot: HerdrSnapshot?
    let zoom: HerdrZoomKeeper
    var collapsedSidebarKeys: [UInt8]?

    init(hostID: UUID) {
        zoom = HerdrZoomKeeper(ledgerKey: "pocketshell.herdrZoomed.\(hostID.uuidString)")
    }

    var focusMode: Bool { zoom.focusMode }
}

extension ConnectionController {
    func focusHerdrPane(_ paneID: String) async -> Bool {
        guard let snapshot = await currentHerdrSnapshot(),
            await herdrExec({ Herdr.focusCommand(session: $0, paneID: paneID, in: snapshot) }) != nil
        else { return false }
        await settleHerdrZoom()
        return true
    }

    func focusHerdrTab(id tabID: String) async -> Bool {
        guard await herdrExec({ Herdr.focusTabCommand(session: $0, tabID: tabID) }) != nil else { return false }
        await settleHerdrZoom()
        return true
    }

    func jumpToHerdrWorkspace(_ workspaceID: String) async -> Bool {
        guard await herdrExec({ Herdr.focusWorkspaceCommand(session: $0, workspaceID: workspaceID) }) != nil
        else { return false }
        await settleHerdrZoom()
        return true
    }

    func setHerdrFocusMode(_ on: Bool) async {
        if let session = herdrTarget?.session {
            await herdr.zoom.setFocusMode(on, session: session, exec: herdrZoomExec)
        }
        if on {
            _ = await currentHerdrSnapshot()
            await collapseHerdrSidebar()
            return
        }
        if let keys = herdr.collapsedSidebarKeys {
            herdr.collapsedSidebarKeys = nil
            if !Herdr.sidebarExpanded(screen: bridge.visibleText()) {
                bridge.sendToHost?(Data(keys))
            }
        }
        _ = await currentHerdrSnapshot()
    }

    func createInHerdr(
        _ item: HerdrNewItem, label: String, cwd: String?, branch: String, agentKind: String?
    ) async -> String? {
        guard
            let output = await herdrExec({
                Herdr.createCommand(session: $0, item: item, label: label, cwd: cwd, branch: branch)
            })
        else { return "PocketShell is not connected to Herdr." }
        let paneID: String?
        switch Herdr.parseActionResult(output) {
        case .failed(_, let message): return message
        case .done(let created): paneID = created
        }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if item.isSplit, !trimmed.isEmpty, let paneID {
            _ = await herdrExec { Herdr.renameCommand(session: $0, target: .pane(paneID), label: trimmed) }
        }
        if let agentKind, let paneID {
            let taken = await currentHerdrSnapshot()?.agents.compactMap(\.name) ?? []
            let name = Herdr.agentName(kind: agentKind, taken: taken)
            guard
                let output = await herdrExec({
                    Herdr.startAgentCommand(session: $0, name: name, kind: agentKind, paneID: paneID)
                })
            else { return "PocketShell lost the connection before \(agentKind) started." }
            let result = Herdr.parseActionResult(output)
            if !Herdr.agentStarted(result), case .failed(_, let message) = result { return message }
        }
        await settleHerdrZoom()
        return nil
    }

    func herdrAction(_ command: (String) -> String) async -> String? {
        guard let output = await herdrExec(command) else { return "PocketShell is not connected to Herdr." }
        _ = await currentHerdrSnapshot()
        if case .failed(_, let message) = Herdr.parseActionResult(output) { return message }
        return nil
    }

    func settleHerdrZoom() async {
        if let session = herdrTarget?.session {
            await herdr.zoom.settle(session: session, exec: herdrZoomExec)
        }
        _ = await currentHerdrSnapshot()
    }

    func releaseHerdrZoomInBackground() {
        guard let session = herdrTarget?.session, !herdr.zoom.owned(session: session).isEmpty else { return }
        let keepAlive = BackgroundKeepAlive()
        keepAlive.begin()
        Task {
            await herdr.zoom.release(session: session, exec: herdrZoomExec)
            keepAlive.end()
        }
    }

    var herdrZoomExec: HerdrZoomKeeper.Exec {
        { [weak self] command in await self?.run(command) }
    }

    private func collapseHerdrSidebar() async {
        guard herdr.collapsedSidebarKeys == nil, Herdr.sidebarExpanded(screen: bridge.visibleText()),
            let config = await herdrExec({ _ in Herdr.configCommand() }),
            let keys = Herdr.sidebarToggleKeys(config: config)
        else { return }
        bridge.sendToHost?(Data(keys))
        herdr.collapsedSidebarKeys = keys
    }
}
