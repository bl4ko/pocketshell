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
        result.append("base64 -d \(staging) > '\(remotePath)' && rm \(staging)")
        return result
    }

    public static func remotePath() -> String {
        "/tmp/psh-\(UUID().uuidString.prefix(8).lowercased()).jpg"
    }
}
