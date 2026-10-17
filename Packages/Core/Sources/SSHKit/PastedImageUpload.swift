import Foundation

public enum PastedImageUpload {
    @MainActor
    public static func run(
        _ data: Data,
        exec: (String) async throws -> Void,
        isCurrent: () -> Bool,
        paste: (String) -> Void,
        fail: (Error) -> Void
    ) async {
        guard isCurrent() else { return }
        let path = RemoteFileUpload.remotePath()
        for command in RemoteFileUpload.commands(base64: data.base64EncodedString(), remotePath: path) {
            do {
                try await exec(command)
            } catch {
                if isCurrent() { fail(error) }
                return
            }
        }
        if isCurrent() { paste(path) }
    }
}
