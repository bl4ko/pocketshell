import Foundation

public enum RemoteFileUpload {
    public static func commands(base64: String, remotePath: String, chunkSize: Int = 65536) -> [String] {
        let staging = "'\(remotePath).b64'"
        var result: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let redirect = result.isEmpty ? ">" : ">>"
            result.append("printf '%s' '\(base64[index..<end])' \(redirect) \(staging)")
            index = end
        }
        result.append("base64 -d < \(staging) > '\(remotePath)' && rm \(staging)")
        return result
    }

    public static func remotePath() -> String {
        "/tmp/psh-\(UUID().uuidString.prefix(8).lowercased()).jpg"
    }

    public static func remotePath(filename: String) -> String {
        let name = URL(fileURLWithPath: filename).lastPathComponent
            .replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: "_", options: .regularExpression)
        return "/tmp/psh-\(UUID().uuidString.lowercased())/\(name)"
    }

    public static func quotedPath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SSHConnection {
    public func uploadFile(at url: URL) async throws -> String {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Select a file to attach."])
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let path = RemoteFileUpload.remotePath(filename: url.lastPathComponent)
        let directory = RemoteFileUpload.quotedPath(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        let destination = RemoteFileUpload.quotedPath(path)
        try Task.checkCancellation()
        _ = try await exec("umask 077 && mkdir \(directory)")
        do {
            var append = false
            while let chunk = try file.read(upToCount: 49152), !chunk.isEmpty {
                try Task.checkCancellation()
                _ = try await exec(
                    "umask 077; printf '%s' '\(chunk.base64EncodedString())' | base64 -d \(append ? ">>" : ">") \(destination)"
                )
                append = true
            }
            try Task.checkCancellation()
            if !append { _ = try await exec("umask 077; : > \(destination)") }
            return path
        } catch {
            _ = try? await exec("rm -f \(destination) && rmdir \(directory)")
            throw error
        }
    }
}
