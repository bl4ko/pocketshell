import Foundation

@MainActor
public final class HerdrZoomKeeper {
    public typealias Exec = @MainActor (String) async -> String?

    public private(set) var focusMode = false
    private let defaults: UserDefaults
    private let ledgerKey: String
    private var tail: Task<Void, Never>?

    public init(ledgerKey: String, defaults: UserDefaults = .standard) {
        self.ledgerKey = ledgerKey
        self.defaults = defaults
    }

    public func owned(session: String) -> Set<String> {
        Set(ledger[session] ?? [])
    }

    public func setFocusMode(_ on: Bool, session: String, exec: @escaping Exec) async {
        focusMode = on
        await settle(session: session, exec: exec)
    }

    public func settle(session: String, exec: @escaping Exec) async {
        await serially { [self] in
            if focusMode {
                await zoomFocused(session: session, exec: exec)
            } else {
                await unzoomOwned(session: session, exec: exec)
            }
        }
    }

    public func release(session: String, exec: @escaping Exec) async {
        await serially { [self] in await unzoomOwned(session: session, exec: exec) }
    }

    private func serially(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }

    private func zoomFocused(session: String, exec: Exec) async {
        guard let output = await exec(Herdr.snapshotCommand(session: session)),
            let snapshot = Herdr.parseSnapshot(output)
        else { return }
        let stillZoomed = Set((snapshot.layouts ?? []).filter(\.zoomed).map(\.tabID))
        var tabs = owned(session: session).intersection(stillZoomed)
        if let target = Herdr.zoomTarget(in: snapshot) {
            tabs.insert(target.tabID)
            store(tabs, session: session)
            _ = await exec(Herdr.zoomCommand(session: session, paneID: target.paneID, on: true))
        } else {
            store(tabs, session: session)
        }
    }

    private func unzoomOwned(session: String, exec: Exec) async {
        let tabs = owned(session: session)
        guard !tabs.isEmpty, let output = await exec(Herdr.snapshotCommand(session: session)),
            let snapshot = Herdr.parseSnapshot(output)
        else { return }
        let commands = Herdr.unzoomCommands(session: session, tabIDs: tabs, in: snapshot)
        if !commands.isEmpty, await exec(commands.joined(separator: "; ")) == nil { return }
        store(owned(session: session).subtracting(tabs), session: session)
    }

    private var ledger: [String: [String]] {
        defaults.dictionary(forKey: ledgerKey) as? [String: [String]] ?? [:]
    }

    private func store(_ tabs: Set<String>, session: String) {
        var ledger = ledger
        ledger[session] = tabs.isEmpty ? nil : tabs.sorted()
        if ledger.isEmpty {
            defaults.removeObject(forKey: ledgerKey)
        } else {
            defaults.set(ledger, forKey: ledgerKey)
        }
    }
}
