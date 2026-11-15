import Foundation

public enum SessionTitle {
    static let defaults: Set<String> = ["claude", "claude code", "codex", "openai codex", "shell", "terminal"]
    static let keptLeading: Set<Character> = ["(", "[", "{", "<", "\"", "'", "#", "@", "~", "/", ".", "$"]

    public static func clean(_ raw: String?, host: String? = nil, cwd: String? = nil) -> String? {
        guard let raw else { return nil }
        var title = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        title = title.drop { !$0.isLetter && !$0.isNumber && !keptLeading.contains($0) }
        var text = title.trimmingCharacters(in: .whitespaces)
        if let folder = cwd.map({ ($0 as NSString).lastPathComponent }), !folder.isEmpty, text.hasSuffix(" | \(folder)")
        {
            text = String(text.dropLast(folder.count + 3)).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let lowered = text.lowercased()
        if defaults.contains(lowered) { return nil }
        if let host = host?.lowercased(), !host.isEmpty {
            let short = host.split(separator: ".").first.map(String.init) ?? host
            if lowered == host || lowered == short || lowered.hasPrefix("\(short).") { return nil }
        }
        return text.count > 80 ? String(text.prefix(79)) + "…" : text
    }

    public static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}
