import Foundation

/// JSON that keeps object key order and number spelling, so a canvas file
/// written back looks the way it was read (`JSONValue` sorts keys).
public indirect enum OrderedJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// The number as written, e.g. `-120` or `12.5`.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object(JSONObject)

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var double: Double? {
        if case .number(let raw) = self { return Double(raw) }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var object: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var array: [OrderedJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// A number written the way JSON Canvas apps do: whole numbers without a decimal point.
    public static func number(_ value: Double) -> OrderedJSON {
        if value.rounded() == value, abs(value) < 1e15 { return .number(String(Int(value))) }
        return .number(String(value))
    }

    // MARK: - Reading

    public struct ParseError: Error, Equatable, LocalizedError {
        public let message: String
        public let offset: Int
        public var errorDescription: String? { "Not valid JSON (\(message) at character \(offset))." }
    }

    public static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        parser.skipSpace()
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.scalars.count else { throw parser.error("unexpected text after the end") }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        func error(_ message: String) -> ParseError { ParseError(message: message, offset: index) }

        mutating func skipSpace() {
            while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                guard index < scalars.count, scalars[index] == scalar else { throw error("expected \(literal)") }
                index += 1
            }
        }

        mutating func value() throws -> OrderedJSON {
            guard index < scalars.count else { throw error("unexpected end") }
            switch scalars[index] {
            case "{": return try object()
            case "[": return try array()
            case "\"": return .string(try string())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default: return try number()
            }
        }

        mutating func object() throws -> OrderedJSON {
            index += 1
            var object = JSONObject()
            skipSpace()
            if index < scalars.count, scalars[index] == "}" { index += 1; return .object(object) }
            while true {
                skipSpace()
                guard index < scalars.count, scalars[index] == "\"" else { throw error("expected a key") }
                let key = try string()
                skipSpace()
                try expect(":")
                skipSpace()
                object.pairs.append(.init(key: key, value: try value()))
                skipSpace()
                guard index < scalars.count else { throw error("unexpected end") }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; return .object(object) }
                throw error("expected , or }")
            }
        }

        mutating func array() throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipSpace()
            if index < scalars.count, scalars[index] == "]" { index += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try value())
                skipSpace()
                guard index < scalars.count else { throw error("unexpected end") }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "]" { index += 1; return .array(items) }
                throw error("expected , or ]")
            }
        }

        mutating func string() throws -> String {
            index += 1
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"":
                    return String(result)
                case "\\":
                    guard index < scalars.count else { throw error("unfinished escape") }
                    let escaped = scalars[index]
                    index += 1
                    switch escaped {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "u":
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                            index += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        result.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: result.append(escaped)
                    }
                default:
                    result.append(scalar)
                }
            }
            throw error("unfinished string")
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= scalars.count, let code = UInt32(String(String.UnicodeScalarView(scalars[index..<index + 4])), radix: 16) else {
                throw error("bad \\u escape")
            }
            index += 4
            return code
        }

        mutating func number() throws -> OrderedJSON {
            let start = index
            while index < scalars.count, "-+.eE0123456789".unicodeScalars.contains(scalars[index]) { index += 1 }
            let raw = String(String.UnicodeScalarView(scalars[start..<index]))
            guard !raw.isEmpty, Double(raw) != nil else { throw error("expected a value") }
            return .number(raw)
        }
    }

    // MARK: - Writing

    /// Compact JSON on one line (`{"a":1,"b":[2,3]}`), as JSON Canvas apps write each node.
    public var compact: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let raw): raw
        case .string(let value): OrderedJSON.quote(value)
        case .array(let items): "[" + items.map(\.compact).joined(separator: ",") + "]"
        case .object(let object): "{" + object.pairs.map { OrderedJSON.quote($0.key) + ":" + $0.value.compact }.joined(separator: ",") + "}"
        }
    }

    /// Indented JSON for hand-read files (timelines, maps): one key per line,
    /// with short lists of plain values (`["s014"]`, `[0.25, 0.4]`) kept on one line.
    public func pretty(indent: String = "  ", level: Int = 0) -> String {
        let inner = String(repeating: indent, count: level + 1)
        let outer = String(repeating: indent, count: level)
        switch self {
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            if items.allSatisfy(\.isInline) {
                return "[" + items.map(\.spaced).joined(separator: ", ") + "]"
            }
            return "[\n" + items.map { inner + $0.pretty(indent: indent, level: level + 1) }.joined(separator: ",\n") + "\n" + outer + "]"
        case .object(let object):
            guard !object.pairs.isEmpty else { return "{}" }
            // A short record of plain values fits on one line: {"id": "mara", "name": "Mara"}.
            if level > 0, object.pairs.allSatisfy(\.value.isInline) {
                let line = "{" + object.pairs.map { OrderedJSON.quote($0.key) + ": " + $0.value.spaced }.joined(separator: ", ") + "}"
                if outer.count + line.count <= 100 { return line }
            }
            return "{\n" + object.pairs.map {
                inner + OrderedJSON.quote($0.key) + ": " + $0.value.pretty(indent: indent, level: level + 1)
            }.joined(separator: ",\n") + "\n" + outer + "}"
        default:
            return compact
        }
    }

    /// Plain values, and lists of plain values, stay on one line.
    private var isInline: Bool {
        switch self {
        case .object: false
        case .array(let items): items.allSatisfy { if case .array = $0 { false } else { $0.isInline } }
        default: true
        }
    }

    /// Like `compact`, with a space after each comma.
    private var spaced: String {
        if case .array(let items) = self { return "[" + items.map(\.spaced).joined(separator: ", ") + "]" }
        return compact
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
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

/// A JSON object with its keys in file order.
public struct JSONObject: Sendable, Equatable {
    public struct Pair: Sendable, Equatable {
        public var key: String
        public var value: OrderedJSON
    }

    public var pairs: [Pair] = []

    public init(_ pairs: [(String, OrderedJSON)] = []) {
        self.pairs = pairs.map { Pair(key: $0.0, value: $0.1) }
    }

    /// Setting nil removes the key; setting a new key appends it.
    public subscript(key: String) -> OrderedJSON? {
        get { pairs.first { $0.key == key }?.value }
        set {
            if let index = pairs.firstIndex(where: { $0.key == key }) {
                if let newValue { pairs[index].value = newValue } else { pairs.remove(at: index) }
            } else if let newValue {
                pairs.append(Pair(key: key, value: newValue))
            }
        }
    }
}
