import XCTest
@testable import TaskFerryCore

final class MigratorTests: XCTestCase {
    func make(_ api: FakeTodoist, _ ledger: Ledger? = nil) throws -> (Migrator, Ledger) {
        let l = try ledger ?? Ledger(url: nil)
        return (Migrator(api: api, ledger: l, timeZone: Fixtures.utc, pace: 0, now: Fixtures.clock), l)
    }

    func testTitleThatTodoistParsesAsALabelIsPutBack() async throws {
        let lists = [SourceList(id: "L", title: "Mentions")]
        let reminders = [SourceReminder(id: "a", listId: "L", title: "@Sam great to meet you")]
        let plan = Planner.makePlan(lists: lists, reminders: reminders, supplement: .empty, timeZone: Fixtures.utc)
        let api = FakeTodoist()
        api.parsesLabels = true
        let (m, _) = try make(api)
        let summary = try await m.run(plan)
        XCTAssertEqual(api.tasks[0].content, "@Sam great to meet you")
        XCTAssertEqual(api.tasks[0].labels, [])
        XCTAssertTrue(summary.warnings.isEmpty)
        let report = try await m.verify(plan)
        XCTAssertEqual(report.matching, 1, "\(report.issues)")
    }

    func testAlertsWhoseTimeHasPassedAreSkippedAndNotExpected() async throws {
        let api = FakeTodoist()
        let late: @Sendable () -> Date = { Fixtures.date("2026-11-19T00:00:00Z") }   // after every fixture due date
        let m = Migrator(api: api, ledger: try Ledger(url: nil), timeZone: Fixtures.utc, pace: 0, now: late)
        let plan = Fixtures.plan()
        let summary = try await m.run(plan)
        XCTAssertEqual(summary.remindersCreated, 0)
        XCTAssertEqual(summary.alertsSkippedAsPast, 1)
        XCTAssertTrue(api.reminders.isEmpty)
        let report = try await m.verify(plan)
        XCTAssertEqual(report.matching, 9, "\(report.issues)")
    }

    func testFullRunCreatesEverythingInTheRightPlace() async throws {
        let api = FakeTodoist()
        let (m, _) = try make(api)
        let plan = Fixtures.plan()
        let summary = try await m.run(plan)

        XCTAssertEqual(summary.projectsCreated, 5)          // Inbox is reused
        XCTAssertEqual(summary.sectionsCreated, 2)
        XCTAssertEqual(summary.tasksCreated, 9)             // 8 reminders + recreated parent
        XCTAssertEqual(summary.remindersCreated, 1)
        XCTAssertTrue(summary.warnings.isEmpty, "\(summary.warnings)")

        let personal = api.projects.first { $0.name == "Personal" }!
        XCTAssertEqual(api.projects.first { $0.name == "Home" }?.parentId, personal.id)
        let research = api.sections.first { $0.name == "Research" }!
        XCTAssertEqual(research.projectId, "inbox")
        XCTAssertEqual(api.tasks.first { $0.content == "Review logger app" }?.sectionId, research.id)

        let parent = api.tasks.first { $0.content == "Quarterly plan" }!
        XCTAssertEqual(api.tasks.first { $0.content == "Draft the one-pager" }?.parentId, parent.id)

        let timed = api.tasks.first { $0.content == "Sort holiday photos" }!
        XCTAssertEqual(timed.priority, 4)
        XCTAssertEqual(timed.description, "soon")
        XCTAssertEqual(api.sentTasks.first { $0.content == "Sort holiday photos" }?.dueDatetime, "2026-10-14T08:00:00Z")
        XCTAssertEqual(api.sentTasks.first { $0.content == "Sort bookmarks" }?.dueDate, "2026-10-15")
        XCTAssertEqual(api.reminders.first?.itemId, timed.id)
        XCTAssertEqual(api.reminders.first?.minuteOffset, 0)
        XCTAssertEqual(api.tasks.first { $0.content == "Standalone" }?.description, "https://example.com/a")
        // Normal priority is never sent.
        XCTAssertNil(api.sentTasks.first { $0.content == "Standalone" }?.priority)
    }

    func testSecondRunCreatesNothing() async throws {
        let api = FakeTodoist()
        let (m, _) = try make(api)
        let plan = Fixtures.plan()
        try await m.run(plan)
        let before = api.creates
        let again = try await m.run(plan)
        XCTAssertEqual(api.creates, before)
        XCTAssertEqual(again.tasksCreated, 0)
        XCTAssertEqual(again.tasksSkipped, 9)
        XCTAssertEqual(api.tasks.count, 9)
    }

    func testResumeAfterEveryPossibleFailurePointNeverDuplicates() async throws {
        let plan = Fixtures.plan()
        let clean = FakeTodoist()
        try await make(clean).0.run(plan)
        let totalCreates = clean.creates

        for failAt in 0..<totalCreates {
            let api = FakeTodoist()
            let (m, ledger) = try make(api)
            api.failAfterCreates = failAt
            do {
                try await m.run(plan)
                XCTFail("run should have failed at \(failAt)")
            } catch {}
            api.failAfterCreates = nil
            try await Migrator(api: api, ledger: ledger, timeZone: Fixtures.utc, pace: 0, now: Fixtures.clock).run(plan)
            XCTAssertEqual(api.projects.count, clean.projects.count, "projects, failure at \(failAt)")
            XCTAssertEqual(api.sections.count, clean.sections.count, "sections, failure at \(failAt)")
            XCTAssertEqual(api.tasks.map(\.content).sorted(), clean.tasks.map(\.content).sorted(), "tasks, failure at \(failAt)")
            XCTAssertEqual(api.reminders.count, clean.reminders.count, "reminders, failure at \(failAt)")
        }
    }

    func testLostLedgerAdoptsWhatIsAlreadyThere() async throws {
        let api = FakeTodoist()
        let plan = Fixtures.plan()
        try await make(api).0.run(plan)
        let before = api.creates

        let (fresh, ledger) = try make(api)          // brand new, empty ledger
        let rec = try await fresh.reconcile(plan)
        XCTAssertEqual(rec.createCount(rec.projects), 0)
        XCTAssertEqual(rec.createCount(rec.sections), 0)
        XCTAssertEqual(rec.createCount(rec.tasks), 0)
        let summary = try await fresh.run(plan)
        XCTAssertEqual(api.creates, before)
        XCTAssertEqual(summary.tasksAdopted, 9)
        XCTAssertEqual(api.reminders.count, 1)
        XCTAssertNotNil(ledger["task:r3"])
    }

    func testIdenticalRemindersStayTwoTasks() async throws {
        let lists = [SourceList(id: "L", title: "Twins")]
        let reminders = [
            SourceReminder(id: "a", listId: "L", title: "Same"),
            SourceReminder(id: "b", listId: "L", title: "Same"),
        ]
        let plan = Planner.makePlan(lists: lists, reminders: reminders, supplement: .empty, timeZone: Fixtures.utc)
        let api = FakeTodoist()
        try await make(api).0.run(plan)
        XCTAssertEqual(api.tasks.count, 2)
        // With the ledger gone, each existing task is adopted by one reminder only.
        let (fresh, ledger) = try make(api)
        try await fresh.run(plan)
        XCTAssertEqual(api.tasks.count, 2)
        XCTAssertNotEqual(ledger["task:a"]?.todoistId, ledger["task:b"]?.todoistId)
    }

    func testExistingProjectWithSameNameIsReused() async throws {
        let api = FakeTodoist()
        api.projects.append(TDProject(id: "mine", name: "Personal", inboxProject: false))
        let (m, _) = try make(api)
        try await m.run(Fixtures.plan())
        XCTAssertEqual(api.projects.filter { $0.name == "Personal" }.count, 1)
        XCTAssertEqual(api.projects.first { $0.name == "Home" }?.parentId, "mine")
    }

    func testTaskCompletedInTodoistIsNotRecreated() async throws {
        let api = FakeTodoist()
        let (m, _) = try make(api)
        let plan = Fixtures.plan()
        try await m.run(plan)
        api.tasks.removeAll { $0.content == "Standalone" }     // completed tasks leave the active list
        try await m.run(plan)
        XCTAssertFalse(api.tasks.contains { $0.content == "Standalone" })
    }

    func testPriorityIsCorrectedWhenTheApiCountsTheOtherWay() async throws {
        let api = FakeTodoist()
        api.invertsPriority = true
        let (m, _) = try make(api)
        let summary = try await m.run(Fixtures.plan())
        XCTAssertEqual(api.tasks.first { $0.content == "Sort holiday photos" }?.priority, 4)
        XCTAssertEqual(api.tasks.first { $0.content == "Sort bookmarks" }?.priority, 3)
        XCTAssertEqual(api.tasks.first { $0.content == "Standalone" }?.priority, 1)
        XCTAssertTrue(summary.warnings.isEmpty)
    }

    func testReminderFailureIsReportedButDoesNotStopTheRun() async throws {
        let api = FakeTodoist()
        api.failReminders = true
        let (m, _) = try make(api)
        let summary = try await m.run(Fixtures.plan())
        XCTAssertEqual(summary.tasksCreated, 9)
        XCTAssertEqual(summary.remindersCreated, 0)
        XCTAssertEqual(summary.warnings.count, 1)
        // The alert is retried on the next run.
        api.failReminders = false
        let again = try await m.run(Fixtures.plan())
        XCTAssertEqual(again.remindersCreated, 1)
        XCTAssertEqual(again.tasksCreated, 0)
    }

    func testExistingAlertIsNotDuplicated() async throws {
        let api = FakeTodoist()
        let (m, ledger) = try make(api)
        let plan = Fixtures.plan()
        try await m.run(plan)
        try ledger.forget("reminder:r3:0")
        try await m.run(plan)
        XCTAssertEqual(api.reminders.count, 1)
    }

    func testVerifyPassesAfterACleanRunAndCatchesChanges() async throws {
        let api = FakeTodoist()
        let (m, _) = try make(api)
        let plan = Fixtures.plan()
        try await m.run(plan)
        let clean = try await m.verify(plan)
        XCTAssertEqual(clean.checked, 9)
        XCTAssertEqual(clean.matching, 9, "\(clean.issues)")

        let i = api.tasks.firstIndex { $0.content == "Sort bookmarks" }!
        api.tasks[i].due = TDDue(date: "2026-10-16")
        api.tasks[i].priority = 1
        let j = api.tasks.firstIndex { $0.content == "Sort holiday photos" }!
        api.tasks[j].due = TDDue(date: "2026-10-14T09:00:00.000000Z")
        api.reminders.removeAll()
        api.tasks.removeAll { $0.content == "Standalone" }

        let report = try await m.verify(plan)
        XCTAssertEqual(report.matching, 6)
        let fields = Set(report.issues.map(\.field))
        XCTAssertEqual(fields, ["Due date", "Priority", "Due time", "Alerts", "Task"])
    }

    func testTodoistLinkRewritingIsNotADifference() async throws {
        XCTAssertEqual(Migrator.plainLinks("[Apple Docs | Running Linux](https://developer.apple.com/x-y)"), "https://developer.apple.com/x-y")
        XCTAssertEqual(
            Migrator.plainLinks(#"Review SW - [GitHub - org/repo: logger \[main maintainer=@me\]](https://github.com/org/repo)"#),
            "Review SW - https://github.com/org/repo")
        XCTAssertEqual(Migrator.plainLinks("no links [here] (really)"), "no links [here] (really)")

        let lists = [SourceList(id: "L", title: "Links")]
        let reminders = [
            SourceReminder(id: "a", listId: "L", title: "https://example.com/page"),
            SourceReminder(id: "b", listId: "L", title: "Read", notes: "see https://example.com/other"),
        ]
        let plan = Planner.makePlan(lists: lists, reminders: reminders, supplement: .empty, timeZone: Fixtures.utc)
        let api = FakeTodoist()
        let (m, _) = try make(api)
        try await m.run(plan)
        // What Todoist does a moment later:
        api.tasks[0].content = "[Example Page](https://example.com/page)"
        api.tasks[1].description = "see [Other](https://example.com/other)"

        let report = try await m.verify(plan)
        XCTAssertEqual(report.matching, 2, "\(report.issues)")
        // And with the ledger gone, the rewritten tasks are still recognised rather than duplicated.
        let (fresh, _) = try make(api)
        try await fresh.run(plan)
        XCTAssertEqual(api.tasks.count, 2)
    }

    func testVerifyBeforeMigratingReportsEverythingAsMissing() async throws {
        let (m, _) = try make(FakeTodoist())
        let report = try await m.verify(Fixtures.plan())
        XCTAssertEqual(report.matching, 0)
        XCTAssertEqual(report.issues.count, 9)
    }

    func testLedgerFromAnotherAccountIsRefused() async throws {
        let api = FakeTodoist()
        let (m, ledger) = try make(api)
        try await m.run(Fixtures.plan())
        let other = FakeTodoist()
        other.projects = [TDProject(id: "other-inbox", name: "Inbox", inboxProject: true)]
        let m2 = Migrator(api: other, ledger: ledger, timeZone: Fixtures.utc, pace: 0, now: Fixtures.clock)
        do {
            try await m2.run(Fixtures.plan())
            XCTFail("expected refusal")
        } catch let e as MigrationError {
            XCTAssertEqual(e, .differentAccount)
        }
        XCTAssertEqual(other.creates, 0)
    }

    func testLedgerSurvivesOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakeTodoist()
        try await Migrator(api: api, ledger: Ledger(url: url), timeZone: Fixtures.utc, pace: 0, now: Fixtures.clock).run(Fixtures.plan())
        let before = api.creates
        let reloaded = try Ledger(url: url)
        XCTAssertEqual(reloaded.account, "inbox")
        try await Migrator(api: api, ledger: reloaded, timeZone: Fixtures.utc, pace: 0, now: Fixtures.clock).run(Fixtures.plan())
        XCTAssertEqual(api.creates, before)
    }

    func testProgressReachesTotal() async throws {
        let api = FakeTodoist()
        let (m, _) = try make(api)
        let box = ProgressBox()
        try await m.run(Fixtures.plan()) { box.set($0) }
        XCTAssertEqual(box.last?.done, box.last?.total)
        XCTAssertEqual(box.last?.total, 5 + 2 + 9 + 1)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MigrationProgress?
    var last: MigrationProgress? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ p: MigrationProgress) { lock.lock(); value = p; lock.unlock() }
}
