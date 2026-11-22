import Foundation

/// `script/title-page.md`: Fountain title page keys.
///
/// ```
/// Title: The Brass Key
/// Credit: written by
/// Author: Tomas Martinez
/// Draft date: November 22, 2026
/// Contact:
///     123 Street
///     City
/// ```
/// Indented lines continue the key above. Keys are case-insensitive.
public struct TitlePage: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var key: String
        public var values: [String]

        public init(key: String, values: [String]) {
            self.key = key
            self.values = values
        }
    }

    public var fields: [Field]

    public init(fields: [Field] = []) {
        self.fields = fields
    }

    public var isEmpty: Bool { fields.allSatisfy { $0.values.allSatisfy(\.isEmpty) } }

    public func values(_ key: String) -> [String] {
        fields.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.flatMap(\.values)
    }

    public var title: String? { values("Title").first }

    public static func parse(_ text: String) -> TitlePage {
        var fields: [Field] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indented = line.first == " " || line.first == "\t"
            if !indented, let colon = line.firstIndex(of: ":"),
               line[..<colon].allSatisfy({ $0.isLetter || $0 == " " }), !line[..<colon].isEmpty {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields.append(Field(key: key, values: value.isEmpty ? [] : [value]))
            } else if !fields.isEmpty {
                fields[fields.count - 1].values.append(trimmed)
            }
        }
        return TitlePage(fields: fields)
    }

    /// Writes the fields back in Fountain form.
    public var text: String {
        fields.map { field in
            if field.values.count == 1 { return "\(field.key): \(field.values[0])" }
            return "\(field.key):" + field.values.map { "\n    \($0)" }.joined()
        }.joined(separator: "\n") + "\n"
    }
}
