import XCTest
@testable import TaskFerryCore

final class MappingTests: XCTestCase {
    let utc = Fixtures.utc

    func testPriorityScale() {
        XCTAssertEqual(Mapping.todoistPriority(0), 1)
        XCTAssertEqual(Mapping.todoistPriority(1), 4)
        XCTAssertEqual(Mapping.todoistPriority(4), 4)
        XCTAssertEqual(Mapping.todoistPriority(5), 3)
        XCTAssertEqual(Mapping.todoistPriority(9), 2)
    }

    func testAllDayAndTimedDue() {
        let allDay = Mapping.map(SourceReminder(id: "a", listId: "l", title: "A", due: DueSpec(day: "2026-10-15")), timeZone: utc)
        XCTAssertEqual(allDay.payload.dueDate, "2026-10-15")
        XCTAssertNil(allDay.payload.dueInstant)

        let when = Fixtures.date("2026-10-14T08:00:00Z")
        let timed = Mapping.map(SourceReminder(id: "b", listId: "l", title: "B", due: DueSpec(day: "2026-10-14", instant: when)), timeZone: utc)
        XCTAssertNil(timed.payload.dueDate)
        XCTAssertEqual(timed.payload.dueInstant, when)
        XCTAssertEqual(Migrator.utcString(when), "2026-10-14T08:00:00Z")
    }

    func testAlertAtDueTimeBecomesRelativeZero() {
        let when = Fixtures.date("2026-10-14T08:00:00Z")
        let r = SourceReminder(id: "a", listId: "l", title: "A", due: DueSpec(day: "2026-10-14", instant: when),
                               alarms: [.absolute(when), .relative(seconds: -1800), .absolute(when.addingTimeInterval(-86400))])
        let m = Mapping.map(r, timeZone: utc)
        XCTAssertEqual(m.alerts, [.relative(minutes: 0), .relative(minutes: 30), .absolute(when.addingTimeInterval(-86400))])
    }

    func testDuplicateAlertsCollapse() {
        let when = Fixtures.date("2026-10-14T08:00:00Z")
        let r = SourceReminder(id: "a", listId: "l", title: "A", due: DueSpec(day: "2026-10-14", instant: when),
                               alarms: [.absolute(when), .relative(seconds: 0)])
        XCTAssertEqual(Mapping.map(r, timeZone: utc).alerts, [.relative(minutes: 0)])
    }

    func testUrlIsAddedOnlyWhenNotAlreadyVisible() {
        let hidden = Mapping.map(SourceReminder(id: "a", listId: "l", title: "Read", notes: "note", url: "https://example.com/x"), timeZone: utc)
        XCTAssertEqual(hidden.payload.description, "note\n\nhttps://example.com/x")
        let inTitle = Mapping.map(SourceReminder(id: "a", listId: "l", title: "Read https://example.com/x", url: "https://example.com/x"), timeZone: utc)
        XCTAssertEqual(inTitle.payload.description, "")
        let inNotes = Mapping.map(SourceReminder(id: "a", listId: "l", title: "Read", notes: "see https://example.com/x", url: "https://example.com/x"), timeZone: utc)
        XCTAssertEqual(inNotes.payload.description, "see https://example.com/x")
    }

    func testLongTitleIsShortenedAndKeptInDescription() {
        let long = String(repeating: "a", count: 640)
        let m = Mapping.map(SourceReminder(id: "a", listId: "l", title: long, notes: "n"), timeZone: utc)
        XCTAssertEqual(m.payload.content.count, 500)
        XCTAssertTrue(m.payload.description.hasPrefix(long))
        XCTAssertTrue(m.payload.description.hasSuffix("n"))
        XCTAssertFalse(m.notes.isEmpty)
    }

    func testMultilineAndEmptyTitles() {
        let multi = Mapping.map(SourceReminder(id: "a", listId: "l", title: "Line one\n8 likes"), timeZone: utc)
        XCTAssertEqual(multi.payload.content, "Line one 8 likes")
        let empty = Mapping.map(SourceReminder(id: "a", listId: "l", title: "  "), timeZone: utc)
        XCTAssertEqual(empty.payload.content, "(untitled)")
    }

    func testStartDateOnlyNotedWhenDifferentFromDue() {
        let due = DueSpec(day: "2026-10-15")
        let same = Mapping.map(SourceReminder(id: "a", listId: "l", title: "A", due: due, start: due), timeZone: utc)
        XCTAssertEqual(same.payload.description, "")
        let other = Mapping.map(SourceReminder(id: "a", listId: "l", title: "A", due: due, start: DueSpec(day: "2026-10-01")), timeZone: utc)
        XCTAssertEqual(other.payload.description, "Start: 2026-10-01")
    }

    func testRecurrenceText() {
        XCTAssertEqual(Mapping.recurrenceText(RecurrenceSpec(frequency: .daily)), "every day")
        XCTAssertEqual(Mapping.recurrenceText(RecurrenceSpec(frequency: .weekly, interval: 2)), "every 2 weeks")
        XCTAssertEqual(Mapping.recurrenceText(RecurrenceSpec(frequency: .weekly, weekdays: [4, 2])), "every Monday, Wednesday")
        let r = SourceReminder(id: "a", listId: "l", title: "A", due: DueSpec(day: "2026-10-15"),
                               recurrences: [RecurrenceSpec(frequency: .monthly)])
        XCTAssertEqual(Mapping.map(r, timeZone: utc).payload.dueString, "every month starting 2026-10-15")
    }

    func testTodoistDateParsing() {
        let fixed = Migrator.parseTodoistDate("2026-10-14T08:00:00.000000Z", utc)
        XCTAssertEqual(fixed?.date, Fixtures.date("2026-10-14T08:00:00Z"))
        XCTAssertEqual(fixed?.hasTime, true)
        let paris = TimeZone(identifier: "Europe/Paris")!
        let floating = Migrator.parseTodoistDate("2026-10-14T10:00:00", paris)
        XCTAssertEqual(floating?.date, Fixtures.date("2026-10-14T08:00:00Z"))
        XCTAssertEqual(Migrator.parseTodoistDate("2026-10-14", utc)?.hasTime, false)
    }
}

final class PlannerTests: XCTestCase {
    func testGroupsBecomeParentProjectsAndInboxIsReused() {
        let plan = Fixtures.plan()
        XCTAssertEqual(plan.projects.map(\.name), ["Personal", "Home", "Work General", "Team", "Inbox", "Loose"])
        let home = plan.projects.first { $0.name == "Home" }!
        XCTAssertEqual(home.parentKey, "project:group:Personal")
        XCTAssertTrue(plan.projects.first { $0.name == "Inbox" }!.isInbox)
        XCTAssertNil(plan.projects.first { $0.name == "Loose" }!.parentKey)
        // Parents come before children.
        for (i, p) in plan.projects.enumerated() {
            if let pk = p.parentKey { XCTAssertLessThan(plan.projects.firstIndex { $0.key == pk }!, i) }
        }
    }

    func testContainerProjectWrapsEverythingExceptInbox() {
        let plan = Planner.makePlan(lists: Fixtures.lists, reminders: Fixtures.reminders, supplement: Fixtures.supplement,
                                    options: PlanOptions(containerProject: "Apple Reminders"), timeZone: Fixtures.utc)
        XCTAssertEqual(plan.projects.first?.name, "Apple Reminders")
        XCTAssertEqual(plan.projects.first { $0.name == "Personal" }?.parentKey, "project:container")
        XCTAssertEqual(plan.projects.first { $0.name == "Loose" }?.parentKey, "project:container")
        XCTAssertNil(plan.projects.first { $0.isInbox }?.parentKey)
    }

    func testSectionsFromMatchers() {
        let plan = Fixtures.plan()
        XCTAssertEqual(plan.sections.map(\.name), ["Research", "Plain"])
        XCTAssertEqual(plan.tasks.first { $0.key == "task:r1" }?.sectionKey, "section:L-inbox:Research")
        XCTAssertEqual(plan.tasks.first { $0.key == "task:r2" }?.sectionKey, "section:L-inbox:Plain")
        XCTAssertTrue(plan.warnings.isEmpty, "\(plan.warnings)")
    }

    func testExactMatcherDoesNotMatchSubstrings() {
        XCTAssertTrue(Matcher(exact: "X").matches(" x "))
        XCTAssertFalse(Matcher(exact: "X").matches("Fix"))
        XCTAssertTrue(Matcher(contains: "logger  app").matches("Review Logger App now"))
        XCTAssertFalse(Matcher().matches("anything"))
    }

    func testMissingAndAmbiguousMatchersWarnInsteadOfGuessing() {
        var s = Fixtures.supplement
        s.sections = [
            .init(list: "Inbox", name: "Gone", reminders: [Matcher(contains: "does not exist")]),
            .init(list: "Inbox", name: "Both", reminders: [Matcher(contains: "e")]),   // hits r1 only? "X" has no e
        ]
        var reminders = Fixtures.reminders
        reminders.append(SourceReminder(id: "r9", listId: "L-inbox", title: "Another one"))
        let plan = Planner.makePlan(lists: Fixtures.lists, reminders: reminders, supplement: s, timeZone: Fixtures.utc)
        XCTAssertTrue(plan.sections.isEmpty)
        XCTAssertTrue(plan.tasks.filter { $0.projectKey == "project:inbox" }.allSatisfy { $0.sectionKey == nil })
        XCTAssertTrue(plan.warnings.contains { $0.message.contains("No open reminder matches") })
        XCTAssertTrue(plan.warnings.contains { $0.message.contains("matches 2 reminders") })
    }

    func testOrphanSubtasksGetARecreatedParentPlacedFirst() {
        let plan = Fixtures.plan()
        let parent = plan.tasks.first { $0.isSynthetic }!
        XCTAssertEqual(parent.payload.content, "Quarterly plan")
        XCTAssertEqual(parent.projectKey, "project:list:L-team")
        XCTAssertEqual(plan.tasks.first { $0.key == "task:r5" }?.parentKey, parent.key)
        XCTAssertEqual(plan.tasks.first { $0.key == "task:r6" }?.parentKey, parent.key)
        XCTAssertNil(plan.tasks.first { $0.key == "task:r7" }?.parentKey)
        for (i, t) in plan.tasks.enumerated() {
            if let pk = t.parentKey { XCTAssertLessThan(plan.tasks.firstIndex { $0.key == pk }!, i) }
        }
    }

    func testOpenParentIsUsedInsteadOfRecreatingIt() {
        var reminders = Fixtures.reminders
        reminders.append(SourceReminder(id: "r10", listId: "L-team", title: "quarterly plan"))
        let plan = Planner.makePlan(lists: Fixtures.lists, reminders: reminders, supplement: Fixtures.supplement, timeZone: Fixtures.utc)
        XCTAssertFalse(plan.tasks.contains { $0.isSynthetic })
        XCTAssertEqual(plan.tasks.first { $0.key == "task:r5" }?.parentKey, "task:r10")
    }

    func testLinkPreviewAddressIsAddedToTheDescription() {
        var s = Fixtures.supplement
        s.links = [
            .init(list: "Loose", reminder: Matcher(contains: "standalone"), url: "https://example.com/a"),      // already there
            .init(list: "Home", reminder: Matcher(contains: "holiday"), url: "https://x.com/a/status/1"),
            .init(list: "Home", reminder: Matcher(contains: "bookmarks"), url: "https://example.org/b"),
            .init(list: "Home", reminder: Matcher(contains: "nothing like this"), url: "https://example.org/c"),
        ]
        let plan = Planner.makePlan(lists: Fixtures.lists, reminders: Fixtures.reminders, supplement: s, timeZone: Fixtures.utc)
        XCTAssertEqual(plan.tasks.first { $0.key == "task:r8" }?.payload.description, "https://example.com/a")
        XCTAssertEqual(plan.tasks.first { $0.key == "task:r3" }?.payload.description, "soon\n\nhttps://x.com/a/status/1")
        XCTAssertEqual(plan.tasks.first { $0.key == "task:r4" }?.payload.description, "https://example.org/b")
        XCTAssertEqual(plan.warnings.filter { $0.message.contains("link preview") }.count, 1)
    }

    func testOnlySelectedListsArePlanned() {
        let plan = Planner.makePlan(lists: [Fixtures.lists[1]], reminders: Fixtures.reminders, supplement: Fixtures.supplement, timeZone: Fixtures.utc)
        XCTAssertEqual(plan.projects.map(\.name), ["Personal", "Home"])
        XCTAssertEqual(plan.tasks.map(\.key), ["task:r3", "task:r4"])
    }

    func testEveryReminderBecomesExactlyOneTask() {
        let plan = Fixtures.plan()
        let real = plan.tasks.filter { !$0.isSynthetic }.map(\.key).sorted()
        XCTAssertEqual(real, Fixtures.reminders.map { "task:\($0.id)" }.sorted())
    }

    func testSupplementDecodingToleratesMissingKeys() throws {
        let s = try JSONDecoder().decode(Supplement.self, from: Data(#"{"groups":[{"name":"G","lists":["A"]}]}"#.utf8))
        XCTAssertEqual(s.groupName(forList: " a "), "G")
        XCTAssertTrue(s.sections.isEmpty)
    }
}
