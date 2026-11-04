import Foundation

/// A JSON value that preserves object key order and number spelling, so editing
/// the user's Claude Code settings produces a minimal diff and never reformats
/// values we did not touch.
public indirect enum JSONValue: Equatable, Sendable {
    case object(JSONObject)
    case array([JSONValue])
    case string(String)
    /// The literal text of the number as written in the source.
    case number(String)
    case bool(Bool)
    case null

    public var objectValue: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    /// Equality that ignores object key order.
    public func semanticallyEquals(_ other: JSONValue) -> Bool {
        switch (self, other) {
        case (.object(let a), .object(let b)):
            guard a.members.count == b.members.count else { return false }
            for member in a.members {
                guard let match = b[member.key], member.value.semanticallyEquals(match) else { return false }
            }
            return true
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.semanticallyEquals($1) }
        case (.number(let a), .number(let b)):
            return a == b || Double(a) == Double(b)
        default:
            return self == other
        }
    }
}

public struct JSONObject: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue
    }

    public var members: [Member]

    public init(_ members: [Member] = []) {
        self.members = members
    }

    public init(_ pairs: KeyValuePairs<String, JSONValue>) {
        self.members = pairs.map { Member(key: $0.key, value: $0.value) }
    }

    public var keys: [String] { members.map(\.key) }

    /// Reads the last occurrence of a key (matching JavaScript's JSON.parse).
    /// Writing replaces it in place, or appends a new key at the end.
    public subscript(key: String) -> JSONValue? {
        get { members.last(where: { $0.key == key })?.value }
        set {
            if let newValue {
                if let index = members.lastIndex(where: { $0.key == key }) {
                    members[index].value = newValue
                } else {
                    members.append(Member(key: key, value: newValue))
                }
            } else {
                members.removeAll { $0.key == key }
            }
        }
    }
}

public enum JSONParseError: Error, Equatable, CustomStringConvertible {
    case unexpectedEnd
    case unexpectedCharacter(Character, offset: Int)
    case invalidNumber(offset: Int)
    case invalidEscape(offset: Int)
    case tooDeep
    case trailingContent(offset: Int)

    public var description: String {
        switch self {
        case .unexpectedEnd: return "unexpected end of file"
        case .unexpectedCharacter(let c, let offset): return "unexpected character '\(c)' at byte \(offset)"
        case .invalidNumber(let offset): return "invalid number at byte \(offset)"
        case .invalidEscape(let offset): return "invalid escape sequence at byte \(offset)"
        case .tooDeep: return "nesting is too deep"
        case .trailingContent(let offset): return "unexpected content after the JSON value at byte \(offset)"
        }
    }
}

public enum OrderedJSON {
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        // Tolerate a UTF-8 byte-order mark.
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw JSONParseError.trailingContent(offset: parser.index) }
        return value
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    /// Pretty-prints with two-space indentation, the style Claude Code itself writes.
    public static func serialize(_ value: JSONValue, indent: String = "  ") -> String {
        var output = ""
        write(value, into: &output, level: 0, indent: indent)
        return output
    }

    private static func write(_ value: JSONValue, into output: inout String, level: Int, indent: String) {
        switch value {
        case .null: output += "null"
        case .bool(let bool): output += bool ? "true" : "false"
        case .number(let literal): output += literal
        case .string(let string): output += quote(string)
        case .array(let array):
            if array.isEmpty { output += "[]"; return }
            output += "[\n"
            for (index, element) in array.enumerated() {
                output += String(repeating: indent, count: level + 1)
                write(element, into: &output, level: level + 1, indent: indent)
                output += index == array.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: indent, count: level) + "]"
        case .object(let object):
            if object.members.isEmpty { output += "{}"; return }
            output += "{\n"
            for (index, member) in object.members.enumerated() {
                output += String(repeating: indent, count: level + 1)
                output += quote(member.key) + ": "
                write(member.value, into: &output, level: level + 1, indent: indent)
                output += index == object.members.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: indent, count: level) + "}"
        }
    }

    static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    private struct Parser {
        var bytes: [UInt8]
        var index = 0
        static let maxDepth = 256

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func peek() throws -> UInt8 {
            guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
            return bytes[index]
        }

        func unexpected() -> JSONParseError {
            guard index < bytes.count else { return .unexpectedEnd }
            return .unexpectedCharacter(Character(UnicodeScalar(bytes[index])), offset: index)
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
                guard bytes[index] == byte else { throw unexpected() }
                index += 1
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth < Parser.maxDepth else { throw JSONParseError.tooDeep }
            switch try peek() {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw unexpected()
            }
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            index += 1
            var object = JSONObject()
            skipWhitespace()
            if try peek() == UInt8(ascii: "}") { index += 1; return .object(object) }
            while true {
                skipWhitespace()
                guard try peek() == UInt8(ascii: "\"") else { throw unexpected() }
                let key = try parseString()
                skipWhitespace()
                guard try peek() == UInt8(ascii: ":") else { throw unexpected() }
                index += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                object.members.append(.init(key: key, value: value))
                skipWhitespace()
                let next = try peek()
                index += 1
                if next == UInt8(ascii: ",") { continue }
                if next == UInt8(ascii: "}") { return .object(object) }
                index -= 1
                throw unexpected()
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            index += 1
            var array: [JSONValue] = []
            skipWhitespace()
            if try peek() == UInt8(ascii: "]") { index += 1; return .array(array) }
            while true {
                skipWhitespace()
                array.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                let next = try peek()
                index += 1
                if next == UInt8(ascii: ",") { continue }
                if next == UInt8(ascii: "]") { return .array(array) }
                index -= 1
                throw unexpected()
            }
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw JSONParseError.invalidNumber(offset: start) }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[index]) {
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            } else {
                throw JSONParseError.invalidNumber(offset: start)
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                let digitsStart = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                guard index > digitsStart else { throw JSONParseError.invalidNumber(offset: start) }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                let digitsStart = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                guard index > digitsStart else { throw JSONParseError.invalidNumber(offset: start) }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw JSONParseError.unexpectedEnd }
            guard let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw JSONParseError.invalidEscape(offset: index)
            }
            index += 4
            return value
        }

        mutating func parseString() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var runStart = index
            func flushRun(_ end: Int) {
                if end > runStart {
                    scalars.append(contentsOf: String(decoding: bytes[runStart..<end], as: UTF8.self).unicodeScalars)
                }
            }
            while true {
                guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    flushRun(index)
                    index += 1
                    return String(scalars)
                }
                if byte < 0x20 { throw unexpected() }
                if byte != UInt8(ascii: "\\") { index += 1; continue }
                flushRun(index)
                let escapeOffset = index
                index += 1
                guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try parseHex4()
                    if (0xD800...0xDBFF).contains(code) {
                        // Surrogate pair.
                        guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                            throw JSONParseError.invalidEscape(offset: escapeOffset)
                        }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw JSONParseError.invalidEscape(offset: escapeOffset) }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = UnicodeScalar(code) else { throw JSONParseError.invalidEscape(offset: escapeOffset) }
                    scalars.append(scalar)
                default:
                    throw JSONParseError.invalidEscape(offset: escapeOffset)
                }
                runStart = index
            }
        }
    }
}
