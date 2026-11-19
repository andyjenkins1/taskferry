import EventKit
import Foundation
import TaskFerryCore

/// Reads lists and open reminders through EventKit.
/// Its only write is `complete(ids:)`, which the user has to ask for.
final class RemindersReader: @unchecked Sendable {
    private let store = EKEventStore()

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    func lists() -> [SourceList] {
        store.calendars(for: .reminder)
            .map { SourceList(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func openReminders() async -> [SourceReminder] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: (found ?? []).map(Self.convert))
            }
        }
    }

    /// Marks the given reminders as completed and returns how many were changed.
    func complete(ids: [String]) throws -> Int {
        var changed = 0
        for id in ids {
            guard let r = store.calendarItem(withIdentifier: id) as? EKReminder, !r.isCompleted else { continue }
            r.isCompleted = true
            try store.save(r, commit: false)
            changed += 1
        }
        if changed > 0 { try store.commit() }
        return changed
    }

    private static func convert(_ r: EKReminder) -> SourceReminder {
        SourceReminder(
            id: r.calendarItemIdentifier,
            listId: r.calendar.calendarIdentifier,
            title: r.title ?? "",
            notes: r.notes,
            url: r.url?.absoluteString,
            due: spec(r.dueDateComponents),
            start: spec(r.startDateComponents),
            priority: r.priority,
            alarms: (r.alarms ?? []).map(alarm),
            recurrences: (r.recurrenceRules ?? []).map(rule),
            created: r.creationDate)
    }

    private static func spec(_ c: DateComponents?) -> DueSpec? {
        guard let c, let y = c.year, let m = c.month, let d = c.day else { return nil }
        if let hour = c.hour {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = c.timeZone ?? .current
            let parts = DateComponents(year: y, month: m, day: d, hour: hour, minute: c.minute ?? 0, second: c.second ?? 0)
            if let instant = cal.date(from: parts) {
                return DueSpec(day: Mapping.dayString(instant, .current), instant: instant)
            }
        }
        return DueSpec(day: String(format: "%04d-%02d-%02d", y, m, d))
    }

    private static func alarm(_ a: EKAlarm) -> AlarmSpec {
        if let location = a.structuredLocation { return .location(location.title ?? "") }
        if let date = a.absoluteDate { return .absolute(date) }
        return .relative(seconds: a.relativeOffset)
    }

    private static func rule(_ r: EKRecurrenceRule) -> RecurrenceSpec {
        let frequency: RecurrenceSpec.Frequency
        switch r.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: frequency = .daily
        }
        let days = r.daysOfTheWeek ?? []
        let weekdays = days.map { $0.dayOfTheWeek.rawValue }
        let complex = !(r.daysOfTheMonth ?? []).isEmpty
            || !(r.monthsOfTheYear ?? []).isEmpty
            || !(r.setPositions ?? []).isEmpty
            || !(r.weeksOfTheYear ?? []).isEmpty
            || !(r.daysOfTheYear ?? []).isEmpty
            || days.contains { $0.weekNumber != 0 }
            || (frequency != .weekly && !weekdays.isEmpty)
            || (frequency == .weekly && r.interval > 1 && !weekdays.isEmpty)
        return RecurrenceSpec(
            frequency: frequency, interval: r.interval,
            weekdays: frequency == .weekly ? weekdays : [],
            isComplex: complex, hasEnd: r.recurrenceEnd != nil)
    }
}
