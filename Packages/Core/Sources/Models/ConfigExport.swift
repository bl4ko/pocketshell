import Foundation

public struct ConfigExport: Codable, Equatable, Sendable {
    public var version: Int
    public var hosts: [HostConfig]
    public var vncHosts: [VNCHostConfig]
    public var snippets: [Snippet]
    public var toolbarKeys: [ToolbarKey]
    public var knownHosts: [String: String]

    public init(
        hosts: [HostConfig],
        vncHosts: [VNCHostConfig],
        snippets: [Snippet],
        toolbarKeys: [ToolbarKey],
        knownHosts: [String: String]
    ) {
        version = 1
        self.hosts = hosts
        self.vncHosts = vncHosts
        self.snippets = snippets
        self.toolbarKeys = toolbarKeys
        self.knownHosts = knownHosts
    }

    public static func mergeByID<T: Identifiable & Equatable>(existing: [T], incoming: [T]) -> [T] {
        var result = existing
        for item in incoming {
            if let index = result.firstIndex(where: { $0.id == item.id }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }
}
