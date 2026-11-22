import Foundation

/// A JSON value with no fixed schema. Slate uses it to keep keys it doesn't know
/// about (so hand edits to `project.json` survive a save) and to deep-merge themes.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value: return Int(value)
        default: return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Deep merge: objects merge key by key, and any other value in `override`
    /// replaces the value in `self` (arrays are replaced, not concatenated).
    func merging(_ override: JSONValue) -> JSONValue {
        guard case .object(let base) = self, case .object(let top) = override else {
            return override
        }
        var result = base
        for (key, value) in top {
            if let existing = result[key] {
                result[key] = existing.merging(value)
            } else {
                result[key] = value
            }
        }
        return .object(result)
    }
}

/// The one JSON style Slate writes: pretty-printed, sorted keys, unescaped
/// slashes, trailing newline. A fixed style keeps diffs small and lets files
/// round-trip byte-identically.
public enum SlateJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    /// A short, human-readable description of a decoding failure, e.g.
    /// `editor.background: “#12” is not a hex colour`.
    public static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return joined.isEmpty ? "" : "\(joined): "
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(path(context))missing “\(key.stringValue)”"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context))\(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
