import Foundation

/// How a timeline writes world times.
public enum TimeUnits: String, Sendable, CaseIterable, Identifiable {
    /// Real dates: `2031-03-14T22:10`, `2031-03-14`, `2031-03` or `2031`.
    case datetime
    /// Relative days: `Day 3`, `Day 3 14:00`, `-2`.
    case days
    /// Named eras: `Second Age 312`.
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .datetime: "Dates"
        case .days: "Days"
        case .custom: "Custom Calendar"
        }
    }
}

/// Reads world times into numbers that sort, and shows them nicely.
public struct TimeScale: Sendable, Equatable {
    public var units: TimeUnits
    /// For `.custom`: era names, oldest first.
    public var eras: [String]

    public init(units: TimeUnits, eras: [String] = []) {
        self.units = units
        self.eras = eras
    }

    /// A sort key (seconds for dates and days), or nil if the text can't be read.
    public func key(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        switch units {
        case .datetime: return Self.date(text)?.key
        case .days: return Self.day(text)?.key
        case .custom: return customKey(text)
        }
    }

    /// The time as shown on the timeline: `14 Mar 2031, 22:10`, `Day 3, 14:00`.
    public func label(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch units {
        case .datetime:
            guard let date = Self.date(trimmed) else { return trimmed }
            var parts: [String] = []
            if let day = date.day { parts.append(String(day)) }
            if let month = date.month { parts.append(Self.monthNames[month - 1]) }
            parts.append(date.year < 0 ? "\(-date.year) BC" : String(date.year))
            var result = parts.joined(separator: " ")
            if let time = date.time { result += ", " + Self.clock(time) }
            return result
        case .days:
            guard let day = Self.day(trimmed) else { return trimmed }
            let number = day.day.rounded() == day.day ? String(Int(day.day)) : String(day.day)
            return "Day \(number)" + (day.time.map { ", " + Self.clock($0) } ?? "")
        case .custom:
            return trimmed
        }
    }

    /// What to type, for a placeholder.
    public var example: String {
        switch units {
        case .datetime: "2031-03-14T22:10"
        case .days: "Day 3 14:00"
        case .custom: (eras.first ?? "Age") + " 312"
        }
    }

    // MARK: Dates

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static let datePattern = try! NSRegularExpression(
        pattern: #"^(-?\d{1,6})(?:-(\d{1,2})(?:-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2}))?)?)?)?$"#)

    struct DateParts {
        var year: Int
        var month: Int?
        var day: Int?
        /// Seconds since midnight.
        var time: Int?

        /// Seconds from 1970-01-01, proleptic Gregorian.
        var key: Double {
            let days = TimeScale.daysFromCivil(year: year, month: month ?? 1, day: day ?? 1)
            return Double(days) * 86_400 + Double(time ?? 0)
        }
    }

    static func date(_ text: String) -> DateParts? {
        let ns = text as NSString
        guard let match = datePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ index: Int) -> Int? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
        }
        guard let year = group(1) else { return nil }
        var parts = DateParts(year: year, month: group(2), day: group(3))
        if let month = parts.month, !(1...12).contains(month) { return nil }
        if let day = parts.day, !(1...31).contains(day) { return nil }
        if let hour = group(4), let minute = group(5) {
            guard hour < 24, minute < 60 else { return nil }
            parts.time = hour * 3600 + minute * 60 + (group(6) ?? 0)
        }
        return parts
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm; works for any year).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    // MARK: Days

    private static let dayPattern = try! NSRegularExpression(
        pattern: #"^(?:day\s*)?(-?\d+(?:\.\d+)?)(?:\s*,?\s*(\d{1,2}):(\d{2}))?$"#, options: .caseInsensitive)

    static func day(_ text: String) -> (day: Double, time: Int?, key: Double)? {
        let ns = text as NSString
        guard let match = dayPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let day = Double(ns.substring(with: match.range(at: 1))) else { return nil }
        var time: Int?
        if match.range(at: 2).location != NSNotFound,
           let hour = Int(ns.substring(with: match.range(at: 2))), let minute = Int(ns.substring(with: match.range(at: 3))) {
            guard hour < 24, minute < 60 else { return nil }
            time = hour * 3600 + minute * 60
        }
        return (day, time, day * 86_400 + Double(time ?? 0))
    }

    // MARK: Custom calendar

    private static let customPattern = try! NSRegularExpression(pattern: #"^(.*?)\s*(-?\d+(?:\.\d+)?)$"#)

    /// `<era> <number>`: eras sort in list order, numbers within them.
    private func customKey(_ text: String) -> Double? {
        let ns = text as NSString
        guard let match = Self.customPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let number = Double(ns.substring(with: match.range(at: 2))) else { return nil }
        let era = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        if era.isEmpty { return eras.isEmpty ? number : nil }
        guard let index = eras.firstIndex(where: { $0.compare(era, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            return nil
        }
        return Double(index) * 1e12 + number
    }
}
