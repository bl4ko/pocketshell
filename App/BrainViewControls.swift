import Foundation
import HerdrKit
import TerminalUI
import TmuxKit

extension ConnectionController {
    func scrollToInput() async {
        bridge.scrollToBottom()
        if let clone = tmuxCloneTarget {
            _ = await run(Tmux.leaveCopyModeCommand(target: clone))
        } else if isHerdrAttached {
            await scrollHerdrPane(toBottom: true)
        }
    }

    func scrollToHistoryTop() async {
        if let clone = tmuxCloneTarget {
            _ = await run(Tmux.historyTopCommand(target: clone))
        } else if isHerdrAttached {
            await scrollHerdrPane(toBottom: false)
        } else {
            bridge.scrollToTop()
        }
    }

    private func scrollHerdrPane(toBottom: Bool) async {
        guard bridge.wheelReachesHost else { return }
        let lines = await herdrScrollLines()
        var previous: Int?
        for _ in 0..<4 {
            guard let snapshot = await currentHerdrSnapshot(),
                let pane = snapshot.panes?.first(where: { $0.paneID == snapshot.focusedPaneID })
                    ?? snapshot.panes?.first(where: \.focused),
                let scroll = pane.scroll
            else { return }
            let wheels = scroll.wheels(toBottom: toBottom, linesPerWheel: lines)
            guard wheels > 0, scroll.offsetFromBottom != previous else { return }
            previous = scroll.offsetFromBottom
            bridge.sendWheel(up: !toBottom, count: min(wheels, 2000))
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func herdrScrollLines() async -> Int {
        if let lines = herdr.scrollLines { return lines }
        let lines = Herdr.mouseScrollLines(config: await herdrExec { _ in Herdr.configCommand() } ?? "")
        herdr.scrollLines = lines
        return lines
    }
}
