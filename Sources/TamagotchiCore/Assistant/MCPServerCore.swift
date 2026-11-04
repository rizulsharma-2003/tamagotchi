import Foundation

/// A tool Mochi's helper Claude session can call.
public struct MCPToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: AnyJSON

    public init(name: String, description: String, inputSchema: AnyJSON) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// An object schema from `[name: (type, description)]`; `required` lists the mandatory ones.
    public init(name: String, description: String, properties: [String: (type: String, description: String)] = [:],
                required: [String] = [], enumValues: [String: [String]] = [:]) {
        var props: [String: AnyJSON] = [:]
        for (key, value) in properties {
            var property: [String: AnyJSON] = ["type": .string(value.type), "description": .string(value.description)]
            if let values = enumValues[key] { property["enum"] = .array(values.map { .string($0) }) }
            props[key] = .object(property)
        }
        self.init(name: name, description: description, inputSchema: [
            "type": "object",
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ])
    }
}

/// The part of the Model Context Protocol Mochi's tool server speaks: the handshake, the tool
/// list and tool calls, as newline-delimited JSON-RPC 2.0. Transport and tool execution live
/// in the app; this is pure so it can be tested.
public struct MCPServerCore: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Send this line back now.
        case reply(Data)
        /// Run the tool, then send `MCPServerCore.toolResult(id:text:isError:)`.
        case call(id: AnyJSON, name: String, arguments: AnyJSON)
        /// Notifications and responses need no answer.
        case ignore
    }

    public static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    public static let fallbackVersion = "2025-06-18"

    public var name: String
    public var version: String
    public var instructions: String?
    public var tools: [MCPToolSpec]

    public init(name: String, version: String, instructions: String? = nil, tools: [MCPToolSpec]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    public func handle(_ line: Data) -> Outcome {
        guard let message = AnyJSON.parse(line), case .object(let fields) = message else {
            return .reply(Self.error(id: .null, code: -32700, message: "Parse error"))
        }
        let id = fields["id"]
        guard let method = fields["method"]?.stringValue else { return .ignore }
        guard let id, id != .null else { return .ignore }
        let params = fields["params"] ?? .object([:])

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            var result: [String: AnyJSON] = [
                "protocolVersion": .string(Self.supportedVersions.contains(requested) ? requested : Self.fallbackVersion),
                "capabilities": ["tools": .object([:])],
                "serverInfo": ["name": .string(name), "version": .string(version)],
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return .reply(Self.response(id: id, result: .object(result)))
        case "ping":
            return .reply(Self.response(id: id, result: .object([:])))
        case "tools/list":
            let list: [AnyJSON] = tools.map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema]
            }
            return .reply(Self.response(id: id, result: ["tools": .array(list)]))
        case "tools/call":
            guard let tool = params["name"]?.stringValue, tools.contains(where: { $0.name == tool }) else {
                return .reply(Self.toolResult(id: id, text: "Unknown tool.", isError: true))
            }
            return .call(id: id, name: tool, arguments: params["arguments"] ?? .object([:]))
        default:
            return .reply(Self.error(id: id, code: -32601, message: "Method not found"))
        }
    }

    public static func toolResult(id: AnyJSON, text: String, isError: Bool = false) -> Data {
        response(id: id, result: ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)])
    }

    static func response(id: AnyJSON, result: AnyJSON) -> Data {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: AnyJSON, code: Int, message: String) -> Data {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    private static func line(_ value: AnyJSON) -> Data {
        var data = Data(value.jsonText.utf8)
        data.append(0x0A)
        return data
    }
}
