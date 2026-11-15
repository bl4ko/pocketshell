import Foundation

public struct RecallExchange: Equatable, Sendable {
    public var session: String
    public var turn: Int?
    public var time: String
    public var user = ""
    public var generated = ""
    public var heard = ""
    public var sealed = false

    public var notHeard: String {
        guard sealed else { return "" }
        let rest = Self.remainder(of: generated, after: heard)
        return rest.contains { $0.isLetter || $0.isNumber } ? rest : ""
    }

    public var cut: Bool { !notHeard.isEmpty }

    public var reply: String {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        return heard.isEmpty && !sealed ? generated.trimmingCharacters(in: .whitespacesAndNewlines) : heard
    }

    static func remainder(of generated: String, after heard: String) -> String {
        var position = generated.startIndex
        for character in heard where !character.isWhitespace {
            guard let match = generated[position...].firstIndex(of: character) else { break }
            position = generated.index(after: match)
        }
        return generated[position...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ConversationRecall {
    public static let name = "recall_conversation"
    public static let window: TimeInterval = 3600

    public static let definition = ToolDefinition(
        name: name,
        description: "Read what you and the user said earlier in this voice conversation, also parts trimmed from "
            + "your memory: list recent exchanges, read one in full, or find exchanges by words.",
        parameters: .object([
            "type": "object",
            "properties": .object([
                "action": .object(["type": "string", "enum": .array(["list", "read", "query"])]),
                "back": .object([
                    "type": "integer", "description": "For read: 1 is the latest earlier exchange, 2 the one before.",
                ]),
                "index": .object(["type": "integer", "description": "For read: the index from list."]),
                "words": .object(["type": "string", "description": "For query: words to find."]),
                "count": .object(["type": "integer", "description": "For list: how many, default 8."]),
            ]),
            "required": .array(["action"]),
        ]))

    public static func files(store: ConversationLogStore, host: String, now: Date, current: URL) -> [URL] {
        let today = store.newSession(date: now).day
        let manager = FileManager.default
        let earlier = store.logs.filter { url in
            guard url.lastPathComponent != current.lastPathComponent, store.host(of: url) == host else { return false }
            if url.deletingLastPathComponent().lastPathComponent == today { return true }
            let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return modified.map { now.timeIntervalSince($0) < window } ?? false
        }
        return earlier + [current]
    }

    public static func exchanges(_ files: [URL]) -> [RecallExchange] {
        var result: [RecallExchange] = []
        var turns: [String: Int] = [:]
        var replies: [String: Int] = [:]
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    let type = event["type"] as? String, let session = event["session"] as? String
                else { continue }
                let time = event["time"] as? String ?? ""
                func exchange(turn: Int) -> Int {
                    if let index = turns["\(session)#\(turn)"] { return index }
                    result.append(RecallExchange(session: session, turn: turn, time: time))
                    turns["\(session)#\(turn)"] = result.count - 1
                    return result.count - 1
                }
                switch type {
                case "turn":
                    guard let turn = event["turn"] as? Int else { continue }
                    result[exchange(turn: turn)].user = event["text"] as? String ?? ""
                case "request":
                    if let turn = event["turn"] as? Int { _ = exchange(turn: turn) }
                case "reply":
                    guard let turn = event["turn"] as? Int, let reply = event["reply"] as? Int else { continue }
                    let index = exchange(turn: turn)
                    replies["\(session)#\(reply)"] = index
                    result[index].generated = joined(result[index].generated, event["generated"] as? String)
                case "heard":
                    guard let reply = event["reply"] as? Int, let index = replies["\(session)#\(reply)"] else {
                        continue
                    }
                    result[index].heard = joined(result[index].heard, event["text"] as? String)
                    if event["cut"] as? Bool == true { result[index].sealed = true }
                case "spoken":
                    guard ["announcement", "prompt", "reply"].contains(event["kind"] as? String) else { continue }
                    let text = event["text"] as? String ?? ""
                    result.append(RecallExchange(session: session, time: time, generated: text, heard: text))
                default:
                    continue
                }
            }
        }
        return result.filter { !$0.user.isEmpty || !$0.generated.isEmpty || !$0.heard.isEmpty }
    }

    public static func answer(
        _ arguments: [String: Any], exchanges all: [RecallExchange], excluding current: (session: String, turn: Int)?
    ) -> String {
        let exchanges = all.filter { $0.session != current?.session || $0.turn != current?.turn }
        guard !exchanges.isEmpty else { return AgentToolbox.json(["status": "ok", "exchanges": [], "total": 0]) }
        func number(_ key: String) -> Int? {
            (arguments[key] as? Int) ?? (arguments[key] as? Double).map(Int.init)
                ?? (arguments[key] as? String).flatMap(Int.init)
        }
        func entry(_ position: Int) -> [String: Any] {
            let item = exchanges[position]
            var object: [String: Any] = [
                "index": position + 1, "back": exchanges.count - position, "time": item.time,
                "user": short(item.user, 120), "reply": short(item.reply, 200),
            ]
            if item.cut {
                object["cut"] = true
                object["not_heard"] = short(item.notHeard, 200)
            }
            if item.turn == nil { object["announcement"] = true }
            return object
        }
        switch arguments["action"] as? String ?? "list" {
        case "list":
            let count = min(max(number("count") ?? 8, 1), 20)
            let positions = Array(exchanges.indices.suffix(count))
            return AgentToolbox.json(["status": "ok", "total": exchanges.count, "exchanges": positions.map(entry)])
        case "read":
            let position = number("index").map { $0 - 1 } ?? number("back").map { exchanges.count - $0 }
            guard let position, exchanges.indices.contains(position) else {
                return AgentToolbox.error("No such exchange. There are \(exchanges.count).")
            }
            let item = exchanges[position]
            var object: [String: Any] = [
                "status": "ok", "index": position + 1, "back": exchanges.count - position, "time": item.time,
            ]
            var truncated = false
            for (key, text) in [("user", item.user), ("reply", item.reply), ("not_heard", item.notHeard)]
            where !text.isEmpty {
                let clipped = LogScrubber.clip(text, limit: 3000)
                truncated = truncated || clipped != text
                object[key] = clipped
            }
            object["cut"] = item.cut
            if truncated { object["truncated"] = true }
            return AgentToolbox.json(object)
        case "query":
            let words = (arguments["words"] as? String ?? "").lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            guard !words.isEmpty else { return AgentToolbox.error("Give words to find.") }
            let found = exchanges.indices.reversed().filter { position in
                let item = exchanges[position]
                let text = (item.user + " " + item.generated + " " + item.heard).lowercased()
                return words.allSatisfy(text.contains)
            }
            return AgentToolbox.json([
                "status": "ok", "total": exchanges.count, "exchanges": found.prefix(8).map(entry),
            ])
        default:
            return AgentToolbox.error("Unknown action. Use list, read, or query.")
        }
    }

    private static func joined(_ text: String, _ more: String?) -> String {
        guard let more, !more.isEmpty else { return text }
        return text.isEmpty ? more : text + " " + more
    }

    private static func short(_ text: String, _ limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
