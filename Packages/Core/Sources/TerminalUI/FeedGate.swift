import Foundation

public struct FeedGate {
    private var live = true
    private var pending = Data()

    public init() {}

    public mutating func ingest(_ data: Data) -> Data? {
        if live { return data }
        pending.append(data)
        return nil
    }

    public mutating func setLive(_ live: Bool) -> Data? {
        self.live = live
        return live ? drain() : nil
    }

    public mutating func drain() -> Data? {
        guard !pending.isEmpty else { return nil }
        let out = pending
        pending = Data()
        return out
    }
}
