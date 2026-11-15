import Foundation

@MainActor
public final class ConversationLogMirror {
    nonisolated public static let homeRoot = "$HOME/.local/share/pocketshell/voice-logs"
    nonisolated public static let testRoot = "$PSH_VOICE_LOGS"
    nonisolated static let marker = "psh-voice-log"

    public let store: ConversationLogStore
    public let hostID: String
    public let root: String
    public var chunkLimit = 60_000
    public var maxExecs = 8
    private let exec: @MainActor (String) async -> String?
    private var syncing = false
    private var loop: Task<Void, Never>?

    public init(
        store: ConversationLogStore, hostID: String, root: String = homeRoot,
        exec: @escaping @MainActor (String) async -> String?
    ) {
        self.store = store
        self.hostID = hostID
        self.root = root
        self.exec = exec
    }

    public func start(every interval: Duration = .seconds(3)) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.sync()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    @discardableResult
    public func sync() async -> Bool {
        guard !syncing else { return false }
        syncing = true
        defer { syncing = false }
        let store = store
        let host = hostID
        let limit = chunkLimit
        for _ in 0..<maxExecs {
            let next = await Task.detached { () -> (ConversationLogStore.Pending, Data)? in
                for item in store.pending(host: host) {
                    if let data = store.chunk(item, limit: limit) { return (item, data) }
                }
                return nil
            }.value
            guard let next else { return true }
            let (item, data) = next
            guard let command = Self.command(root: root, day: item.day, id: item.id, offset: item.sent, data: data),
                let size = Self.size(from: await exec(command))
            else { return false }
            await Task.detached { store.markSent(item.url, sent: size) }.value
            if size == item.sent { return false }
        }
        return false
    }

    nonisolated static func command(root: String, day: String, id: String, offset: Int, data: Data) -> String? {
        let safe = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-")
        guard !day.isEmpty, !id.isEmpty, (day + id).unicodeScalars.allSatisfy(safe.contains) else { return nil }
        let script = """
            r="\(root)"; case "$r" in /*) ;; *) exit 0;; esac
            d="$r/\(day)"; f="$d/\(id).jsonl"
            mkdir -p "$d" || exit 0
            s=0; [ -f "$f" ] && s=$(wc -c < "$f"); s=$((s+0))
            if [ "$s" -eq \(offset) ]; then
              printf '%s' '\(data.base64EncodedString())' | base64 -d >> "$f" && s=$(wc -c < "$f") && s=$((s+0))
            fi
            echo "\(marker) $s"
            """
        return "sh -c " + HostAgents.shellQuote(script)
    }

    nonisolated static func size(from output: String?) -> Int? {
        guard let output else { return nil }
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[0] == marker, let size = Int(parts[1]) { return size }
        }
        return nil
    }
}
