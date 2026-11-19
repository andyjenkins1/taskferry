import Foundation
@testable import TaskFerryCore

/// In-memory stand-in for Todoist with failure injection.
final class FakeTodoist: TodoistAPI, @unchecked Sendable {
    var projects: [TDProject] = [TDProject(id: "inbox", name: "Inbox", inboxProject: true)]
    var sections: [TDSection] = []
    var tasks: [TDTask] = []
    var reminders: [TDReminder] = []

    /// Number of successful create calls so far.
    var creates = 0
    /// When set, every create after this many successes fails like a dropped connection.
    var failAfterCreates: Int?
    /// Simulates an API where 1 means highest priority on input.
    var invertsPriority = false
    var failReminders = false
    /// Mimics Todoist turning a leading "@word" in a new task's title into a label.
    var parsesLabels = false
    var sentTasks: [TDTaskCreate] = []
    private var counter = 0

    private func newId(_ prefix: String) -> String { counter += 1; return "\(prefix)\(counter)" }

    private func gate() throws {
        if let n = failAfterCreates, creates >= n { throw TodoistError.network("simulated outage") }
        creates += 1
    }

    func listProjects() async throws -> [TDProject] { projects }

    func createProject(name: String, parentId: String?, requestId: String) async throws -> TDProject {
        try gate()
        let p = TDProject(id: newId("p"), name: name, parentId: parentId, inboxProject: false)
        projects.append(p)
        return p
    }

    func listSections(projectId: String) async throws -> [TDSection] { sections.filter { $0.projectId == projectId } }

    func createSection(name: String, projectId: String, requestId: String) async throws -> TDSection {
        try gate()
        let s = TDSection(id: newId("s"), projectId: projectId, name: name)
        sections.append(s)
        return s
    }

    func listTasks(projectId: String) async throws -> [TDTask] { tasks.filter { $0.projectId == projectId } }

    func createTask(_ body: TDTaskCreate, requestId: String) async throws -> TDTask {
        try gate()
        sentTasks.append(body)
        var due: TDDue?
        if let s = body.dueString { due = TDDue(date: "2026-01-01", string: s, isRecurring: true) }
        else if let dt = body.dueDatetime { due = TDDue(date: dt.replacingOccurrences(of: "Z", with: ".000000Z"), timezone: "Europe/London", isRecurring: false) }
        else if let d = body.dueDate { due = TDDue(date: d, isRecurring: false) }
        let stored = body.priority.map { invertsPriority ? 5 - $0 : $0 } ?? 1
        var content = body.content
        var labels: [String] = []
        if parsesLabels, content.hasPrefix("@"), let space = content.firstIndex(of: " ") {
            labels = [String(content[content.index(after: content.startIndex)..<space])]
            content = String(content[content.index(after: space)...])
        }
        let t = TDTask(id: newId("t"), projectId: body.projectId ?? "inbox", sectionId: body.sectionId,
                       parentId: body.parentId, content: content, description: body.description ?? "",
                       priority: stored, due: due, labels: labels)
        tasks.append(t)
        return t
    }

    func updateTask(id: String, _ changes: TDTaskUpdate) async throws -> TDTask {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw TodoistError.http(status: 404, message: "no task") }
        if let p = changes.priority { tasks[i].priority = invertsPriority ? 5 - p : p }
        if let c = changes.content { tasks[i].content = c }
        if let l = changes.labels { tasks[i].labels = l }
        return tasks[i]
    }

    func listReminders(taskId: String?) async throws -> [TDReminder] {
        reminders.filter { taskId == nil || $0.itemId == taskId }
    }

    func createReminder(_ body: TDReminderCreate, requestId: String) async throws -> TDReminder {
        if failReminders { throw TodoistError.http(status: 403, message: "reminders need a paid plan") }
        try gate()
        let r = TDReminder(id: newId("r"), itemId: body.taskId, type: body.reminderType,
                           minuteOffset: body.minuteOffset, due: body.due, isDeleted: false)
        reminders.append(r)
        return r
    }
}

enum Fixtures {
    static let utc = TimeZone(identifier: "UTC")!
    /// A fixed "now" before every fixture due date, so alerts count as upcoming.
    static let clock: @Sendable () -> Date = { date("2026-01-01T00:00:00Z") }

    static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)!
    }

    static let lists = [
        SourceList(id: "L-inbox", title: "Inbox"),
        SourceList(id: "L-home", title: "Home"),
        SourceList(id: "L-team", title: "Team"),
        SourceList(id: "L-loose", title: "Loose"),
    ]

    static let supplement = Supplement(
        inboxLists: ["Inbox"],
        groups: [
            .init(name: "Personal", lists: ["Home"]),
            .init(name: "Work General", lists: ["Team"]),
        ],
        sections: [
            .init(list: "Inbox", name: "Research", reminders: [Matcher(contains: "logger")]),
            .init(list: "Inbox", name: "Plain", reminders: [Matcher(exact: "X")]),
        ],
        subtasks: [
            .init(list: "Team", parentTitle: "Quarterly plan", children: [Matcher(contains: "one-pager"), Matcher(contains: "presentation")]),
        ])

    static let reminders: [SourceReminder] = [
        SourceReminder(id: "r1", listId: "L-inbox", title: "Review logger app", created: date("2026-01-01T10:00:00Z")),
        SourceReminder(id: "r2", listId: "L-inbox", title: "X", created: date("2026-01-02T10:00:00Z")),
        SourceReminder(id: "r3", listId: "L-home", title: "Sort holiday photos", notes: "soon",
                       due: DueSpec(day: "2026-10-14", instant: date("2026-10-14T08:00:00Z")), priority: 1,
                       alarms: [.absolute(date("2026-10-14T08:00:00Z"))], created: date("2026-01-03T10:00:00Z")),
        SourceReminder(id: "r4", listId: "L-home", title: "Sort bookmarks", due: DueSpec(day: "2026-10-15"), priority: 5,
                       created: date("2026-01-04T10:00:00Z")),
        SourceReminder(id: "r5", listId: "L-team", title: "Draft the one-pager", created: date("2026-01-05T10:00:00Z")),
        SourceReminder(id: "r6", listId: "L-team", title: "Create presentation", created: date("2026-01-06T10:00:00Z")),
        SourceReminder(id: "r7", listId: "L-team", title: "Speak with Sam", created: date("2026-01-07T10:00:00Z")),
        SourceReminder(id: "r8", listId: "L-loose", title: "Standalone", url: "https://example.com/a", created: date("2026-01-08T10:00:00Z")),
    ]

    static func plan() -> MigrationPlan {
        Planner.makePlan(lists: lists, reminders: reminders, supplement: supplement, timeZone: utc)
    }
}
