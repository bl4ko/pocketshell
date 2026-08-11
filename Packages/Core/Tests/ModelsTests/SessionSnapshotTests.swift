import Foundation
import Models
import Testing

@Test func snapshotCodableRoundtrip() throws {
    let snapshot = SessionSnapshot(
        windows: [
            .init(
                host: "mac-mini",
                session: "default",
                index: 1,
                name: "PocketShell · Codex",
                status: "busy",
                lastLine: "working",
                backend: "herdr",
                workspaceID: "w1",
                paneID: "w1:p1"),
            .init(host: "mac-mini", session: "claude", index: 1, name: "1: slocar", status: "idle", lastLine: ""),
        ],
        updatedAt: Date(timeIntervalSince1970: 1000)
    )
    #expect(snapshot.windows[1].index == 1)
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
    #expect(decoded == snapshot)
    #expect(decoded.windows[0].workspaceID == "w1")
}

@Test func snapshotStoreSaveLoadRoundtrip() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapshot-test-\(UUID().uuidString)", isDirectory: true)
    let store = SnapshotStore(directory: dir)
    #expect(store.load() == nil)
    let snapshot = SessionSnapshot(
        windows: [.init(host: "h", session: "s", index: 0, name: "w", status: "idle", lastLine: "x")],
        updatedAt: Date(timeIntervalSince1970: 42)
    )
    store.save(snapshot)
    #expect(store.load() == snapshot)
    try? FileManager.default.removeItem(at: dir)
}
