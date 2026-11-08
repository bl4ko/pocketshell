import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct ToolCall: Equatable, Sendable, Codable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var argumentObject: [String: Any] {
        guard let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    enum CodingKeys: String, CodingKey { case id, type, function }
    enum FunctionKeys: String, CodingKey { case name, arguments }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let function = try container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        name = try function.decode(String.self, forKey: .name)
        arguments = try function.decodeIfPresent(String.self, forKey: .arguments) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode("function", forKey: .type)
        var function = container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        try function.encode(name, forKey: .name)
        try function.encode(arguments, forKey: .arguments)
    }
}

public struct ChatMessage: Equatable, Sendable, Codable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String?
    public var toolCalls: [ToolCall]
    public var toolCallID: String?

    public init(role: Role, content: String?, toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }
    public static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> ChatMessage {
        ChatMessage(role: .assistant, content: text.isEmpty && !toolCalls.isEmpty ? nil : text, toolCalls: toolCalls)
    }
    public static func tool(_ id: String, _ result: String) -> ChatMessage {
        ChatMessage(role: .tool, content: result, toolCallID: id)
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let content {
            try container.encode(content, forKey: .content)
        } else {
            try container.encodeNil(forKey: .content)
        }
        if !toolCalls.isEmpty { try container.encode(toolCalls, forKey: .toolCalls) }
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

public struct ToolDefinition: Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    var wire: JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name), "description": .string(description), "parameters": parameters,
            ]),
        ])
    }
}

public struct ChatRequest: Encodable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolDefinition]

    public init(model: String, messages: [ChatMessage], tools: [ToolDefinition]) {
        self.model = model
        self.messages = messages
        self.tools = tools
    }

    enum CodingKeys: String, CodingKey { case model, messages, tools, stream }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(true, forKey: .stream)
        if !tools.isEmpty { try container.encode(tools.map(\.wire), forKey: .tools) }
    }
}
