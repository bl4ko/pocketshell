import Foundation

public enum WorkspaceSync {
    public enum Action: Equatable, Sendable {
        case push
        case apply(HostWorkspace)
        case none
    }

    public static let readCommand = "cat \"$HOME/.config/pocketshell/workspace.json\" 2>/dev/null"

    public static func writeCommand(_ workspace: HostWorkspace) -> String? {
        guard let data = try? JSONEncoder().encode(workspace) else { return nil }
        let payload = data.base64EncodedString()
        return "mkdir -p \"$HOME/.config/pocketshell\" && printf '%s' '\(payload)'"
            + " | base64 -d > \"$HOME/.config/pocketshell/workspace.json\""
    }

    public static func decode(_ output: String) -> HostWorkspace? {
        guard let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HostWorkspace.self, from: data)
    }

    public static func action(localUpdatedAt: Date?, remote: HostWorkspace?) -> Action {
        switch (localUpdatedAt, remote) {
        case (nil, nil):
            return .none
        case (nil, let remote?):
            return .apply(remote)
        case (.some, nil):
            return .push
        case let (local?, remote?):
            if remote.updatedAt > local { return .apply(remote) }
            if remote.updatedAt < local { return .push }
            return .none
        }
    }
}
