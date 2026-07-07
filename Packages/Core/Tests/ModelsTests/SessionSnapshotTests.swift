import Foundation
import Models
import Testing

@Test func snapshotCodableRoundtrip() throws {
    let snapshot = SessionSnapshot(
        windows: [
            .init(host: "mac-mini", name: "0: homeops", status: "busy", lastLine: "$ make"),
            .init(host: "mac-mini", name: "1: slocar", status: "idle", lastLine: ""),
        ],
        updatedAt: Date(timeIntervalSince1970: 1000)
    )
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
    #expect(decoded == snapshot)
}

@Test func snapshotStoreSaveLoadRoundtrip() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapshot-test-\(UUID().uuidString)", isDirectory: true)
    let store = SnapshotStore(directory: dir)
    #expect(store.load() == nil)
    let snapshot = SessionSnapshot(
        windows: [.init(host: "h", name: "w", status: "idle", lastLine: "x")],
        updatedAt: Date(timeIntervalSince1970: 42)
    )
    store.save(snapshot)
    #expect(store.load() == snapshot)
    try? FileManager.default.removeItem(at: dir)
}
