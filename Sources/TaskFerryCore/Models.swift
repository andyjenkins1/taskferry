import Foundation

/// A Reminders list, as read from EventKit.
public struct SourceList: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A due or start date. `instant` is set only when the reminder has a time of day.
public struct DueSpec: Codable, Equatable, Sendable {
    /// Calendar day, "YYYY-MM-DD".
    public var day: String
    public var instant: Date?

    public init(day: String, instant: Date? = nil) {
        self.day = day
        self.instant = instant
    }
}

public enum AlarmSpec: Codable, Equatable, Sendable {
    case absolute(Date)
    /// Offset from the due date in seconds; negative means before.
    case relative(seconds: Double)
    case location(String)
}

public struct RecurrenceSpec: Codable, Equatable, Sendable {
    public enum Frequency: String, Codable, Sendable { case daily, weekly, monthly, yearly }

    public var frequency: Frequency
    public var interval: Int
    /// 1 = Sunday … 7 = Saturday. Empty when the rule is not tied to weekdays.
    public var weekdays: [Int]
    /// The rule has parts (month days, set positions…) that the Todoist text cannot carry.
    public var isComplex: Bool
    public var hasEnd: Bool

    public init(frequency: Frequency, interval: Int = 1, weekdays: [Int] = [], isComplex: Bool = false, hasEnd: Bool = false) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.isComplex = isComplex
        self.hasEnd = hasEnd
    }
}

/// One open reminder with every field EventKit exposes.
public struct SourceReminder: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var listId: String
    public var title: String
    public var notes: String?
    public var url: String?
    public var due: DueSpec?
    public var start: DueSpec?
    /// EventKit scale: 0 none, 1–4 high, 5 medium, 6–9 low.
    public var priority: Int
    public var alarms: [AlarmSpec]
    public var recurrences: [RecurrenceSpec]
    public var created: Date?

    public init(
        id: String, listId: String, title: String, notes: String? = nil, url: String? = nil,
        due: DueSpec? = nil, start: DueSpec? = nil, priority: Int = 0,
        alarms: [AlarmSpec] = [], recurrences: [RecurrenceSpec] = [], created: Date? = nil
    ) {
        self.id = id
        self.listId = listId
        self.title = title
        self.notes = notes
        self.url = url
        self.due = due
        self.start = start
        self.priority = priority
        self.alarms = alarms
        self.recurrences = recurrences
        self.created = created
    }
}
