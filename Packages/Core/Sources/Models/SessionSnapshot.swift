import Foundation

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var host: String
        public var session: String
        public var index: Int
        public var name: String
        public var status: String
        public var lastLine: String

        public init(host: String, session: String, index: Int, name: String, status: String, lastLine: String) {
            self.host = host
            self.session = session
            self.index = index
            self.name = name
            self.status = status
            self.lastLine = lastLine
        }
    }

    public var windows: [Window]
    public var updatedAt: Date

    public init(windows: [Window], updatedAt: Date) {
        self.windows = windows
        self.updatedAt = updatedAt
    }
}

public struct SnapshotStore: Sendable {
    public static let appGroup = "group.com.bl4ko.pocketshell"

    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("session-snapshot.json")
    }

    public static var shared: SnapshotStore {
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SnapshotStore(directory: dir)
    }

    public static func save(_ snapshot: SessionSnapshot) {
        shared.save(snapshot)
    }

    public func save(_ snapshot: SessionSnapshot) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
