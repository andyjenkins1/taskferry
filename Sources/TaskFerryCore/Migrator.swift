import Foundation

public enum ReuseReason: String, Equatable, Sendable {
    case inbox            // the Todoist Inbox
    case migratedBefore   // recorded in the ledger by an earlier run
    case existingByName   // a project or section with the same name is already there
    case adopted          // an identical task is already there (e.g. the app quit before recording it)
}

public enum ItemAction: Equatable, Sendable {
    case create
    case reuse(id: String, why: ReuseReason)

    public var isCreate: Bool { self == .create }
}

/// What a run would do, worked out by comparing the plan with Todoist and the ledger.
public struct Reconciliation: Equatable, Sendable {
    public var inboxId: String
    public var projects: [String: ItemAction] = [:]
    public var sections: [String: ItemAction] = [:]
    public var tasks: [String: ItemAction] = [:]
    /// Alert keys already recorded in the ledger.
    public var alertsDone: Set<String> = []
    /// Alerts a run would create: not yet recorded and not already in the past.
    public var alertsToCreate = 0

    public func createCount(_ actions: [String: ItemAction]) -> Int { actions.values.filter(\.isCreate).count }
}

public struct MigrationProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var message: String

    public init(done: Int, total: Int, message: String) {
        self.done = done; self.total = total; self.message = message
    }
}

public struct RunSummary: Equatable, Sendable {
    public var projectsCreated = 0
    public var sectionsCreated = 0
    public var tasksCreated = 0
    public var tasksAdopted = 0
    public var tasksSkipped = 0
    public var remindersCreated = 0
    /// Alerts not created because their moment has already passed.
    public var alertsSkippedAsPast = 0
    public var warnings: [String] = []

    public init() {}
}

public struct VerifyIssue: Identifiable, Hashable, Sendable {
    public var task: String
    public var field: String
    public var expected: String
    public var actual: String
    public var id: String { "\(task)|\(field)|\(expected)|\(actual)" }

    public init(task: String, field: String, expected: String, actual: String) {
        self.task = task; self.field = field; self.expected = expected; self.actual = actual
    }
}

public struct VerifyReport: Equatable, Sendable {
    public var checked = 0
    public var matching = 0
    /// Plan keys of the tasks that matched in every field.
    public var matchingKeys: Set<String> = []
    public var issues: [VerifyIssue] = []

    public init() {}
}

public enum MigrationError: Error, LocalizedError, Equatable {
    case noInbox
    case differentAccount
    case missingParent(String)

    public var errorDescription: String? {
        switch self {
        case .noInbox:
            return "Todoist did not report an Inbox project for this account."
        case .differentAccount:
            return "The migration history on this Mac belongs to a different Todoist account. Use “Reset migration history” if you really want to migrate into this account."
        case .missingParent(let name):
            return "Internal error: the parent of “\(name)” was not created first."
        }
    }
}

public final class Migrator: @unchecked Sendable {
    private let api: TodoistAPI
    private let ledger: Ledger
    private let timeZone: TimeZone
    /// Pause between writes, to stay far below Todoist's rate limits.
    private let pace: Double
    /// Set when the first prioritised task shows the API counts priority the other way round.
    private var invertPriority = false
    private let now: @Sendable () -> Date

    public init(api: TodoistAPI, ledger: Ledger, timeZone: TimeZone = .current, pace: Double = 0.15,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.ledger = ledger
        self.timeZone = timeZone
        self.pace = pace
        self.now = now
    }

    // MARK: Reconcile

    public func reconcile(_ plan: MigrationPlan) async throws -> Reconciliation {
        let projects = try await api.listProjects().filter { $0.isArchived != true && $0.isDeleted != true }
        guard let inbox = projects.first(where: { $0.inboxProject == true }) else { throw MigrationError.noInbox }
        if let account = ledger.account, account != inbox.id { throw MigrationError.differentAccount }

        var rec = Reconciliation(inboxId: inbox.id)
        var resolved: [String: String] = [:]   // plan key -> existing Todoist id
        let liveProjectIds = Set(projects.map(\.id))

        for p in plan.projects {
            if p.isInbox {
                rec.projects[p.key] = .reuse(id: inbox.id, why: .inbox)
                resolved[p.key] = inbox.id
                continue
            }
            if let e = ledger[p.key], liveProjectIds.contains(e.todoistId) {
                rec.projects[p.key] = .reuse(id: e.todoistId, why: .migratedBefore)
                resolved[p.key] = e.todoistId
                continue
            }
            var parentId: String?
            if let pk = p.parentKey {
                guard let pid = resolved[pk] else { rec.projects[p.key] = .create; continue }
                parentId = pid
            }
            if let match = projects.first(where: { $0.name == p.name && $0.parentId == parentId && $0.inboxProject != true }) {
                rec.projects[p.key] = .reuse(id: match.id, why: .existingByName)
                resolved[p.key] = match.id
            } else {
                rec.projects[p.key] = .create
            }
        }

        var sectionCache: [String: [TDSection]] = [:]
        for s in plan.sections {
            guard let projectId = resolved[s.projectKey] else { rec.sections[s.key] = .create; continue }
            if sectionCache[projectId] == nil { sectionCache[projectId] = try await api.listSections(projectId: projectId) }
            let existing = sectionCache[projectId] ?? []
            if let e = ledger[s.key], existing.contains(where: { $0.id == e.todoistId }) {
                rec.sections[s.key] = .reuse(id: e.todoistId, why: .migratedBefore)
            } else if let match = existing.first(where: { $0.name == s.name }) {
                rec.sections[s.key] = .reuse(id: match.id, why: .existingByName)
            } else {
                rec.sections[s.key] = .create
            }
        }

        var taskCache: [String: [TDTask]] = [:]
        var claimed = ledger.knownIds
        for t in plan.tasks {
            if let e = ledger[t.key] {
                // Trust the ledger even if the task is no longer active: the user may have completed it.
                rec.tasks[t.key] = .reuse(id: e.todoistId, why: .migratedBefore)
                continue
            }
            guard let projectId = resolved[t.projectKey] else { rec.tasks[t.key] = .create; continue }
            if taskCache[projectId] == nil { taskCache[projectId] = try await api.listTasks(projectId: projectId) }
            let twin = (taskCache[projectId] ?? []).first {
                !claimed.contains($0.id)
                    && Self.same($0.content, t.payload.content)
                    && Self.same($0.description ?? "", t.payload.description)
            }
            if let twin {
                claimed.insert(twin.id)
                rec.tasks[t.key] = .reuse(id: twin.id, why: .adopted)
            } else {
                rec.tasks[t.key] = .create
            }
        }

        for t in plan.tasks {
            for a in t.alerts {
                if ledger[a.key] != nil { rec.alertsDone.insert(a.key) }
                else if !isPast(a.alert, t) { rec.alertsToCreate += 1 }
            }
        }
        return rec
    }

    // MARK: Run

    @discardableResult
    public func run(_ plan: MigrationPlan, progress: @escaping @Sendable (MigrationProgress) -> Void = { _ in }) async throws -> RunSummary {
        let rec = try await reconcile(plan)
        try ledger.setAccount(rec.inboxId)

        var summary = RunSummary()
        let total = rec.createCount(rec.projects) + rec.createCount(rec.sections)
            + rec.createCount(rec.tasks) + rec.alertsToCreate
        var done = 0
        func step(_ message: String, counts: Bool = true) {
            if counts { done += 1 }
            progress(MigrationProgress(done: min(done, total), total: total, message: message))
        }
        progress(MigrationProgress(done: 0, total: total, message: "Starting"))

        var ids: [String: String] = [:]

        for p in plan.projects {
            try Task.checkCancellation()
            switch rec.projects[p.key] ?? .create {
            case .reuse(let id, let why):
                ids[p.key] = id
                if why == .existingByName { try ledger.record(p.key, id: id, how: "existing") }
            case .create:
                var parentId: String?
                if let pk = p.parentKey {
                    guard let pid = ids[pk] else { throw MigrationError.missingParent(p.name) }
                    parentId = pid
                }
                let created = try await api.createProject(name: p.name, parentId: parentId, requestId: UUID().uuidString)
                try ledger.record(p.key, id: created.id, how: "created")
                ids[p.key] = created.id
                summary.projectsCreated += 1
                step("Created project “\(p.name)”")
                try await breathe()
            }
        }

        for s in plan.sections {
            try Task.checkCancellation()
            switch rec.sections[s.key] ?? .create {
            case .reuse(let id, let why):
                ids[s.key] = id
                if why == .existingByName { try ledger.record(s.key, id: id, how: "existing") }
            case .create:
                guard let projectId = ids[s.projectKey] else { throw MigrationError.missingParent(s.name) }
                let created = try await api.createSection(name: s.name, projectId: projectId, requestId: UUID().uuidString)
                try ledger.record(s.key, id: created.id, how: "created")
                ids[s.key] = created.id
                summary.sectionsCreated += 1
                step("Created section “\(s.name)”")
                try await breathe()
            }
        }

        for t in plan.tasks {
            try Task.checkCancellation()
            let title = Self.short(t.payload.content)
            var freshlyCreated = false
            switch rec.tasks[t.key] ?? .create {
            case .reuse(let id, let why):
                ids[t.key] = id
                if why == .adopted {
                    try ledger.record(t.key, id: id, how: "adopted")
                    summary.tasksAdopted += 1
                } else {
                    summary.tasksSkipped += 1
                }
            case .create:
                guard let projectId = ids[t.projectKey] else { throw MigrationError.missingParent(title) }
                var body = TDTaskCreate(content: t.payload.content)
                if !t.payload.description.isEmpty { body.description = t.payload.description }
                body.projectId = projectId
                if let sk = t.sectionKey { body.sectionId = ids[sk] }
                if let pk = t.parentKey {
                    guard let pid = ids[pk] else { throw MigrationError.missingParent(title) }
                    body.parentId = pid
                }
                // Normal priority is the default, so it is never sent. That keeps tasks safe
                // until the first prioritised task has shown which way round the API counts.
                let wanted = t.payload.priority
                if wanted > 1 { body.priority = invertPriority ? 5 - wanted : wanted }
                if let s = t.payload.dueString {
                    body.dueString = s
                    body.dueLang = "en"
                } else if let i = t.payload.dueInstant {
                    body.dueDatetime = Self.utcString(i)
                } else if let d = t.payload.dueDate {
                    body.dueDate = d
                }
                let created = try await api.createTask(body, requestId: UUID().uuidString)
                try ledger.record(t.key, id: created.id, how: "created")
                ids[t.key] = created.id
                summary.tasksCreated += 1
                freshlyCreated = true

                if wanted > 1, let got = created.priority, got != wanted {
                    let fixed = try await api.updateTask(id: created.id, TDTaskUpdate(priority: 5 - wanted))
                    if fixed.priority == wanted {
                        invertPriority = true
                    } else {
                        summary.warnings.append("“\(title)”: priority could not be set as expected (wanted \(wanted), Todoist shows \(fixed.priority ?? got)).")
                    }
                }
                // Todoist reads "@word" in a new task's title as a label and removes it from the title.
                // An update is taken literally, so put the title back and drop the label it invented.
                if !Self.same(created.content, t.payload.content) {
                    let repaired = try await api.updateTask(id: created.id, TDTaskUpdate(content: t.payload.content, labels: []))
                    if !Self.same(repaired.content, t.payload.content) {
                        summary.warnings.append("“\(title)”: Todoist changed the title to “\(Self.short(repaired.content))”.")
                    }
                }
                step("Created task “\(title)”")
                try await breathe()
            }

            // Alerts. Failures here are reported but do not stop the run.
            guard let taskId = ids[t.key] else { continue }
            let unrecorded = t.alerts.filter { ledger[$0.key] == nil }
            // An alert for a moment that has already passed can never fire, and Todoist discards
            // recent ones on its own, so they are not created.
            let pending = unrecorded.filter { !isPast($0.alert, t) }
            for _ in 0..<(unrecorded.count - pending.count) {
                summary.alertsSkippedAsPast += 1
                step("Skipped an alert whose time has already passed for “\(title)”", counts: false)
            }
            guard !pending.isEmpty else { continue }
            var existing: [TDReminder] = []
            do {
                existing = try await api.listReminders(taskId: taskId).filter { $0.isDeleted != true }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !freshlyCreated {
                    summary.warnings.append("“\(title)”: could not read existing reminders (\(error.localizedDescription)).")
                }
            }
            for a in pending {
                try Task.checkCancellation()
                if let match = existing.first(where: { self.matches($0, a.alert) }) {
                    try ledger.record(a.key, id: match.id, how: "existing")
                    step("Alert already present for “\(title)”")
                    continue
                }
                do {
                    let created = try await api.createReminder(reminderBody(taskId: taskId, a.alert), requestId: UUID().uuidString)
                    try ledger.record(a.key, id: created.id, how: "created")
                    summary.remindersCreated += 1
                    step("Added alert to “\(title)”")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    summary.warnings.append("“\(title)”: alert not created (\(error.localizedDescription)).")
                    step("Alert failed for “\(title)”")
                }
                try await breathe()
            }
        }

        progress(MigrationProgress(done: total, total: total, message: "Finished"))
        return summary
    }

    // MARK: Verify

    /// Reads everything back from Todoist and compares it field by field with the plan.
    public func verify(_ plan: MigrationPlan) async throws -> VerifyReport {
        var report = VerifyReport()
        let projects = try await api.listProjects()
        let inboxId = projects.first(where: { $0.inboxProject == true })?.id

        func todoistId(_ key: String?) -> String? {
            guard let key else { return nil }
            if key == "project:inbox" { return inboxId }
            return ledger[key]?.todoistId
        }

        var live: [String: TDTask] = [:]
        for p in plan.projects {
            guard let pid = todoistId(p.key) else { continue }
            for t in try await api.listTasks(projectId: pid) { live[t.id] = t }
        }
        var remindersByTask: [String: Int] = [:]
        if plan.alertCount > 0 {
            for r in try await api.listReminders(taskId: nil) where r.isDeleted != true {
                if let item = r.itemId { remindersByTask[item, default: 0] += 1 }
            }
        }

        for t in plan.tasks {
            report.checked += 1
            let title = Self.short(t.payload.content)
            var issues: [VerifyIssue] = []
            func issue(_ field: String, _ expected: String, _ actual: String) {
                issues.append(VerifyIssue(task: title, field: field, expected: expected, actual: actual))
            }
            guard let id = ledger[t.key]?.todoistId else {
                issue("Task", "migrated", "not migrated yet")
                report.issues.append(contentsOf: issues)
                continue
            }
            guard let got = live[id] else {
                issue("Task", "an active task in its project", "not found (completed, moved or deleted in Todoist since the migration?)")
                report.issues.append(contentsOf: issues)
                continue
            }
            if !Self.same(got.content, t.payload.content) { issue("Title", t.payload.content, got.content) }
            if !Self.same(got.description ?? "", t.payload.description) {
                issue("Description", Self.short(t.payload.description, 120), Self.short(got.description ?? "", 120))
            }
            if (got.priority ?? 1) != t.payload.priority {
                issue("Priority", "\(t.payload.priority)", "\(got.priority ?? 1)")
            }
            if got.projectId != todoistId(t.projectKey) { issue("Project", todoistId(t.projectKey) ?? "?", got.projectId ?? "none") }
            if got.sectionId != todoistId(t.sectionKey) { issue("Section", todoistId(t.sectionKey) ?? "none", got.sectionId ?? "none") }
            if got.parentId != todoistId(t.parentKey) { issue("Parent task", todoistId(t.parentKey) ?? "none", got.parentId ?? "none") }

            let actualDue = got.due?.date
            if t.payload.dueString != nil {
                if got.due?.isRecurring != true { issue("Repeat", t.payload.dueString ?? "", got.due?.string ?? "not repeating") }
            } else if let instant = t.payload.dueInstant {
                if let parsed = actualDue.flatMap({ Self.parseTodoistDate($0, timeZone) }), parsed.hasTime,
                   abs(parsed.date.timeIntervalSince(instant)) < 1 {
                    // ok
                } else {
                    issue("Due time", "\(Mapping.dayString(instant, timeZone)) \(Mapping.timeString(instant, timeZone))", actualDue ?? "none")
                }
            } else if let day = t.payload.dueDate {
                if actualDue != day { issue("Due date", day, actualDue ?? "none") }
            } else if let actualDue {
                issue("Due date", "none", actualDue)
            }

            let expectedAlerts = t.alerts.filter { !isPast($0.alert, t) }.count
            if expectedAlerts > 0, (remindersByTask[id] ?? 0) < expectedAlerts {
                issue("Alerts", "\(expectedAlerts)", "\(remindersByTask[id] ?? 0)")
            }

            if issues.isEmpty {
                report.matching += 1
                report.matchingKeys.insert(t.key)
            } else {
                report.issues.append(contentsOf: issues)
            }
        }
        return report
    }

    // MARK: Helpers

    private func isPast(_ alert: PlannedAlert, _ task: PlanTask) -> Bool {
        switch alert {
        case .absolute(let date):
            return date < now()
        case .relative(let minutes):
            // A repeating task has future occurrences even when its first date has passed.
            guard task.payload.dueString == nil, let due = task.payload.dueInstant else { return false }
            return due.addingTimeInterval(-Double(minutes) * 60) < now()
        }
    }

    private func breathe() async throws {
        guard pace > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(pace * 1_000_000_000))
    }

    private func reminderBody(taskId: String, _ alert: PlannedAlert) -> TDReminderCreate {
        switch alert {
        case .relative(let minutes):
            return TDReminderCreate(taskId: taskId, reminderType: "relative", minuteOffset: minutes)
        case .absolute(let date):
            return TDReminderCreate(taskId: taskId, reminderType: "absolute",
                                    due: TDReminderDue(date: Self.localString(date, timeZone), timezone: timeZone.identifier))
        }
    }

    private func matches(_ existing: TDReminder, _ alert: PlannedAlert) -> Bool {
        switch alert {
        case .relative(let minutes):
            return existing.type == "relative" && existing.minuteOffset == minutes
        case .absolute(let date):
            guard existing.type == "absolute", let s = existing.due?.date,
                  let parsed = Self.parseTodoistDate(s, timeZone) else { return false }
            return abs(parsed.date.timeIntervalSince(date)) < 60
        }
    }

    /// Todoist rewrites a bare URL into a titled Markdown link, "[Page title](https://…)",
    /// shortly after a task is created. Both sides are reduced to the bare URL before comparing.
    static func same(_ a: String, _ b: String) -> Bool {
        plainLinks(a).trimmingCharacters(in: .whitespacesAndNewlines)
            == plainLinks(b).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainLinks(_ s: String) -> String {
        s.replacingOccurrences(
            of: #"\[(?:\\.|[^\]\\])*\]\((https?://[^\s)]+)\)"#,
            with: "$1", options: .regularExpression)
    }

    static func short(_ s: String, _ limit: Int = 60) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit - 1)) + "…" : oneLine
    }

    /// "YYYY-MM-DDTHH:MM:SSZ" in UTC, the format Todoist documents for fixed due times.
    public static func utcString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }

    /// "YYYY-MM-DDTHH:MM:SS" in the given zone, the format Todoist documents for reminder dates.
    public static func localString(_ date: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }

    /// Parses the three date shapes Todoist returns. Floating times are read in `tz`.
    public static func parseTodoistDate(_ raw: String, _ tz: TimeZone) -> (date: Date, hasTime: Bool)? {
        var s = raw
        if !s.contains("T") {
            return Mapping.date(fromDay: s, tz).map { ($0, false) }
        }
        let isUTC = s.hasSuffix("Z")
        if isUTC { s.removeLast() }
        if let dot = s.firstIndex(of: ".") { s = String(s[..<dot]) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = isUTC ? TimeZone(identifier: "UTC") : tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s).map { ($0, true) }
    }
}
