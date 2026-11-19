import Foundation

/// What gets sent to Todoist for one task.
public struct TaskPayload: Codable, Equatable, Sendable {
    public var content: String
    public var description: String
    /// Todoist object scale: 1 normal … 4 urgent (shown as p1 in the apps).
    public var priority: Int
    /// All-day due date, "YYYY-MM-DD".
    public var dueDate: String?
    /// Due date with a time.
    public var dueInstant: Date?
    /// Recurring rule in Todoist's natural language. When set it is sent instead of the two above.
    public var dueString: String?

    public init(content: String, description: String = "", priority: Int = 1,
                dueDate: String? = nil, dueInstant: Date? = nil, dueString: String? = nil) {
        self.content = content
        self.description = description
        self.priority = priority
        self.dueDate = dueDate
        self.dueInstant = dueInstant
        self.dueString = dueString
    }
}

public enum PlannedAlert: Codable, Hashable, Sendable {
    /// Minutes before the task's due time.
    case relative(minutes: Int)
    case absolute(Date)
}

public struct MappedReminder: Equatable, Sendable {
    public var payload: TaskPayload
    public var alerts: [PlannedAlert]
    /// Things the user should know about how this reminder was converted.
    public var notes: [String]
}

public enum Mapping {
    public static let maxContentLength = 500
    public static let maxDescriptionLength = 16383

    public static func todoistPriority(_ eventKitPriority: Int) -> Int {
        switch eventKitPriority {
        case 1...4: return 4
        case 5: return 3
        case 6...9: return 2
        default: return 1
        }
    }

    public static func map(_ r: SourceReminder, timeZone: TimeZone = .current) -> MappedReminder {
        var notes: [String] = []
        var parts: [String] = []

        // Title. Todoist task content is a single line of at most 500 characters.
        let rawTitle = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = rawTitle
        if content.contains(where: \.isNewline) {
            content = content.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            notes.append("Line breaks in the title were replaced with spaces.")
        }
        if content.isEmpty {
            content = "(untitled)"
            notes.append("The reminder had no title; “(untitled)” is used.")
        }
        if content.count > maxContentLength {
            parts.append(rawTitle)
            content = String(content.prefix(maxContentLength - 1)) + "…"
            notes.append("Title is longer than \(maxContentLength) characters; it is shortened and the full title is kept in the description.")
        }
        if content.hasPrefix("* ") {
            notes.append("Title starts with “* ”, which Todoist shows as a task that cannot be completed.")
        }

        if let n = r.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            parts.append(n)
        }
        if let u = r.url?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty,
           !rawTitle.contains(u), !(r.notes ?? "").contains(u) {
            parts.append(u)
        }
        if let s = r.start, s != r.due {
            // A start at midnight on an all-day reminder is a date, not a time.
            var shown = s
            if let i = s.instant, r.due?.instant == nil, timeString(i, timeZone) == "00:00" {
                shown = DueSpec(day: dayString(i, timeZone))
            }
            parts.append("Start: " + describe(shown, timeZone))
        }

        var payload = TaskPayload(content: content, priority: todoistPriority(r.priority))
        if let d = r.due {
            if let i = d.instant { payload.dueInstant = i } else { payload.dueDate = d.day }
        }

        if let rule = r.recurrences.first {
            var text = recurrenceText(rule)
            if let d = r.due {
                text += " starting \(d.day)"
                if let i = d.instant { text += " at \(timeString(i, timeZone))" }
            }
            payload.dueString = text
            notes.append("Repeats: converted to the Todoist rule “\(text)”. Check it after migrating.")
            if rule.isComplex || rule.hasEnd || r.recurrences.count > 1 {
                notes.append("The repeat rule has details Todoist text cannot carry (end date, specific month days or several rules).")
                parts.append("Note: the original repeat rule in Apple Reminders had extra details. Review this task's schedule.")
            }
        }

        // Alerts.
        var alerts: [PlannedAlert] = []
        func add(_ a: PlannedAlert) { if !alerts.contains(a) { alerts.append(a) } }
        for alarm in r.alarms {
            switch alarm {
            case .absolute(let date):
                if let i = r.due?.instant, abs(date.timeIntervalSince(i)) < 60 {
                    add(.relative(minutes: 0))
                } else {
                    add(.absolute(date))
                }
            case .relative(let seconds):
                if let i = r.due?.instant {
                    if seconds <= 0 {
                        add(.relative(minutes: Int((-seconds / 60).rounded())))
                    } else {
                        add(.absolute(i.addingTimeInterval(seconds)))
                    }
                } else if let d = r.due, let dayStart = date(fromDay: d.day, timeZone) {
                    add(.absolute(dayStart.addingTimeInterval(seconds)))
                } else {
                    notes.append("An alert relative to the due date was skipped because there is no due date.")
                }
            case .location(let name):
                let label = name.isEmpty ? "a location" : name
                parts.append("Location alert: \(label)")
                notes.append("Location alert (\(label)) is noted in the description; Todoist location reminders are not created.")
            }
        }

        var description = parts.joined(separator: "\n\n")
        if description.count > maxDescriptionLength {
            description = String(description.prefix(maxDescriptionLength - 1)) + "…"
            notes.append("Notes are longer than Todoist allows and were shortened.")
        }
        payload.description = description
        return MappedReminder(payload: payload, alerts: alerts, notes: notes)
    }

    public static func recurrenceText(_ rule: RecurrenceSpec) -> String {
        let n = max(1, rule.interval)
        if rule.frequency == .weekly, n == 1, !rule.weekdays.isEmpty {
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            let days = rule.weekdays.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }
            return "every " + days.joined(separator: ", ")
        }
        let unit: String
        switch rule.frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        }
        return n == 1 ? "every \(unit)" : "every \(n) \(unit)s"
    }

    // MARK: Date helpers

    static func calendar(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    public static func dayString(_ date: Date, _ tz: TimeZone) -> String {
        let c = calendar(tz).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func timeString(_ date: Date, _ tz: TimeZone) -> String {
        let c = calendar(tz).dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    public static func date(fromDay day: String, _ tz: TimeZone) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar(tz).date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    public static func describe(_ d: DueSpec, _ tz: TimeZone) -> String {
        if let i = d.instant { return "\(dayString(i, tz)) \(timeString(i, tz))" }
        return d.day
    }
}
