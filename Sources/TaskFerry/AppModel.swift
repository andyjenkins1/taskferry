import EventKit
import Foundation
import TaskFerryCore
import SwiftUI

struct ListGroup: Identifiable {
    let id: String
    /// nil for lists that are not in a group.
    let name: String?
    let lists: [SourceList]
}

struct PreviewRow: Identifiable {
    enum Kind { case project, section, task }
    let id: String
    let kind: Kind
    let indent: Int
    let title: String
    let detail: String
    let badge: String
    let isNew: Bool
}

@MainActor
final class AppModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case connect, choose, preview, migrate
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .connect: return "Connect"
            case .choose: return "Choose lists"
            case .preview: return "Preview"
            case .migrate: return "Migrate"
            }
        }
    }
    enum Access { case unknown, granted, denied }
    enum TokenState: Equatable { case empty, checking, ok, failed(String) }

    @Published var step: Step = .connect
    @Published var access: Access = .unknown
    @Published var lists: [SourceList] = []
    @Published var reminders: [SourceReminder] = []
    @Published var selected: Set<String> = []
    @Published var token = ""
    @Published var tokenState: TokenState = .empty
    @Published var containerProject = ""
    @Published var plan: MigrationPlan?
    @Published var reconciliation: Reconciliation?
    @Published var busy: String?
    @Published var errorMessage: String?
    @Published var progress: MigrationProgress?
    @Published var log: [String] = []
    @Published var summary: RunSummary?
    @Published var report: VerifyReport?
    @Published var isRunning = false
    @Published var completedInReminders: Int?

    let supplement: Supplement
    /// Set when a mapping file exists but could not be read.
    let mappingProblem: String?
    let hasMapping: Bool
    private let reader = RemindersReader()
    private var runTask: Task<Void, Never>?
    private var didSelectDefaults = false

    init() {
        if let url = Paths.existingMapping {
            do {
                supplement = try Supplement.load(from: url)
                mappingProblem = nil
                hasMapping = true
            } catch {
                supplement = .empty
                mappingProblem = "The mapping file could not be read, so groups, sections, subtasks and link previews are not applied: \(error.localizedDescription)"
                hasMapping = false
            }
        } else {
            supplement = .empty
            mappingProblem = nil
            hasMapping = false
        }
        token = Keychain.read() ?? ""
        refreshAccess()
        if access == .granted { Task { await loadReminders() } }
        if !token.isEmpty { Task { await checkToken() } }
        if CommandLine.arguments.contains("--layout-check") { loadLayoutSample() }
    }

    /// Fills the Migrate screen with made-up values so its layout can be checked without touching Todoist.
    private func loadLayoutSample() {
        step = .migrate
        progress = MigrationProgress(done: 141, total: 141, message: "Finished")
        var s = RunSummary()
        s.projectsCreated = 20; s.sectionsCreated = 5; s.tasksCreated = 99; s.remindersCreated = 15
        s.warnings = ["“Sample task”: alert not created (sample warning)."]
        summary = s
        var r = VerifyReport()
        r.checked = 99; r.matching = 98
        r.issues = [VerifyIssue(task: "Sample task", field: "Due date", expected: "2026-10-30", actual: "2026-10-31")]
        report = r
        log = ["Created project “Personal”", "Created project “Home”", "Created task “Sample task”", "Checking Todoist against the plan…", "Done."]
    }

    // MARK: Reminders

    func refreshAccess() {
        switch reader.status {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    func requestAccess() async {
        _ = await reader.requestAccess()
        refreshAccess()
        if access == .granted { await loadReminders() }
    }

    func loadReminders() async {
        lists = reader.lists()
        reminders = await reader.openReminders()
        let ids = Set(lists.map(\.id))
        if !didSelectDefaults {
            selected = ids
            didSelectDefaults = true
        } else {
            selected.formIntersection(ids)
        }
    }

    /// Shows the folder that holds (or should hold) mapping.json in Finder.
    func revealMappingFolder() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let url = Paths.existingMapping {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(Paths.support)
        }
    }

    func openCount(_ list: SourceList) -> Int { reminders.filter { $0.listId == list.id }.count }

    var listGroups: [ListGroup] {
        var placed = Set<String>()
        var out: [ListGroup] = []
        for g in supplement.groups {
            var members: [SourceList] = []
            for title in g.lists {
                let t = Supplement.normalize(title)
                for l in lists where Supplement.normalize(l.title) == t && !placed.contains(l.id) {
                    members.append(l)
                    placed.insert(l.id)
                }
            }
            if !members.isEmpty { out.append(ListGroup(id: "group:\(g.name)", name: g.name, lists: members)) }
        }
        let rest = lists.filter { !placed.contains($0.id) }
        if !rest.isEmpty { out.insert(ListGroup(id: "ungrouped", name: nil, lists: rest), at: 0) }
        return out
    }

    var selectedLists: [SourceList] { listGroups.flatMap(\.lists).filter { selected.contains($0.id) } }
    var selectedReminderCount: Int { reminders.filter { selected.contains($0.listId) }.count }

    func setGroup(_ group: ListGroup, selected on: Bool) {
        for l in group.lists { if on { selected.insert(l.id) } else { selected.remove(l.id) } }
    }

    func isGroupSelected(_ group: ListGroup) -> Bool { group.lists.allSatisfy { selected.contains($0.id) } }

    // MARK: Todoist

    private var cleanToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    func checkToken() async {
        guard !cleanToken.isEmpty else { tokenState = .empty; return }
        tokenState = .checking
        do {
            _ = try await TodoistClient(token: cleanToken).listProjects()
            Keychain.save(cleanToken)
            tokenState = .ok
        } catch {
            tokenState = .failed(describe(error))
        }
    }

    func forgetToken() {
        Keychain.delete()
        token = ""
        tokenState = .empty
        reconciliation = nil
    }

    private func makeMigrator() throws -> Migrator {
        Migrator(api: TodoistClient(token: cleanToken), ledger: try Ledger(url: Paths.ledger))
    }

    // MARK: Preview

    func buildPreview() async {
        guard !isRunning else { return }
        busy = "Reading reminders…"
        defer { busy = nil }
        await loadReminders()
        let chosen = selectedLists
        let ids = Set(chosen.map(\.id))
        let name = containerProject.trimmingCharacters(in: .whitespaces)
        let p = Planner.makePlan(
            lists: chosen,
            reminders: reminders.filter { ids.contains($0.listId) },
            supplement: supplement,
            options: PlanOptions(containerProject: name.isEmpty ? nil : name))
        plan = p
        reconciliation = nil
        guard tokenState == .ok else { return }
        busy = "Comparing with Todoist…"
        do {
            reconciliation = try await makeMigrator().reconcile(p)
        } catch {
            errorMessage = describe(error)
        }
    }

    var createCounts: (projects: Int, sections: Int, tasks: Int, alerts: Int)? {
        guard plan != nil, let rec = reconciliation else { return nil }
        return (rec.createCount(rec.projects), rec.createCount(rec.sections), rec.createCount(rec.tasks),
                rec.alertsToCreate)
    }

    var previewRows: [PreviewRow] {
        guard let plan else { return [] }
        let rec = reconciliation
        var rows: [PreviewRow] = []
        func badge(_ action: ItemAction?) -> (String, Bool) {
            guard let action else { return ("", false) }
            switch action {
            case .create: return ("new", true)
            case .reuse(_, .inbox): return ("Todoist Inbox", false)
            case .reuse(_, .migratedBefore): return ("already migrated", false)
            case .reuse(_, .existingByName): return ("exists in Todoist", false)
            case .reuse(_, .adopted): return ("already in Todoist", false)
            }
        }
        func taskRows(_ tasks: [PlanTask], indent: Int) {
            for t in tasks where t.parentKey == nil {
                let (b, n) = badge(rec?.tasks[t.key])
                rows.append(PreviewRow(id: t.key, kind: .task, indent: indent, title: t.payload.content, detail: detail(t), badge: b, isNew: n))
                for c in plan.tasks where c.parentKey == t.key {
                    let (cb, cn) = badge(rec?.tasks[c.key])
                    rows.append(PreviewRow(id: c.key, kind: .task, indent: indent + 1, title: c.payload.content, detail: detail(c), badge: cb, isNew: cn))
                }
            }
        }
        for p in plan.projects {
            let depth = depthOf(p, in: plan)
            let (b, n) = badge(rec?.projects[p.key])
            let mine = plan.tasks.filter { $0.projectKey == p.key }
            rows.append(PreviewRow(id: p.key, kind: .project, indent: depth, title: p.name,
                                   detail: mine.isEmpty ? "" : "\(mine.count) task\(mine.count == 1 ? "" : "s")", badge: b, isNew: n))
            taskRows(mine.filter { $0.sectionKey == nil }, indent: depth + 1)
            for s in plan.sections where s.projectKey == p.key {
                let (sb, sn) = badge(rec?.sections[s.key])
                rows.append(PreviewRow(id: s.key, kind: .section, indent: depth + 1, title: s.name, detail: "section", badge: sb, isNew: sn))
                taskRows(mine.filter { $0.sectionKey == s.key }, indent: depth + 2)
            }
        }
        return rows
    }

    private func depthOf(_ p: PlanProject, in plan: MigrationPlan) -> Int {
        var depth = 0
        var key = p.parentKey
        while let k = key, depth < 6 {
            depth += 1
            key = plan.projects.first { $0.key == k }?.parentKey
        }
        return depth
    }

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func detail(_ t: PlanTask) -> String {
        var parts: [String] = []
        if t.isSynthetic { parts.append("recreated parent") }
        if let s = t.payload.dueString { parts.append(s) }
        else if let i = t.payload.dueInstant { parts.append(Self.dateTime.string(from: i)) }
        else if let d = t.payload.dueDate {
            parts.append(Mapping.date(fromDay: d, .current).map { Self.dateOnly.string(from: $0) } ?? d)
        }
        if t.payload.priority > 1 { parts.append("p\(5 - t.payload.priority)") }
        if !t.alerts.isEmpty { parts.append("\(t.alerts.count) alert\(t.alerts.count == 1 ? "" : "s")") }
        if !t.payload.description.isEmpty { parts.append("notes") }
        return parts.joined(separator: " · ")
    }

    // MARK: Run

    func start() {
        guard let plan, !isRunning, tokenState == .ok else { return }
        isRunning = true
        log = []
        summary = nil
        report = nil
        progress = nil
        runTask = Task {
            defer { isRunning = false }
            do {
                let migrator = try makeMigrator()
                let result = try await migrator.run(plan) { p in
                    Task { @MainActor in
                        self.progress = p
                        self.append(p.message)
                    }
                }
                summary = result
                append("Checking Todoist against the plan…")
                report = try await migrator.verify(plan)
                reconciliation = try? await migrator.reconcile(plan)
                append("Done.")
            } catch is CancellationError {
                append("Stopped. Start again to continue where it left off.")
            } catch {
                errorMessage = describe(error)
                append("Stopped: \(describe(error))")
                append("Start again to continue where it left off; nothing will be duplicated.")
            }
        }
    }

    func stop() { runTask?.cancel() }

    func verifyNow() async {
        guard let plan, !isRunning else { return }
        busy = "Checking Todoist…"
        defer { busy = nil }
        do { report = try await makeMigrator().verify(plan) } catch { errorMessage = describe(error) }
    }

    /// Open reminders that were migrated and matched Todoist in every field in the last check.
    var completableIds: [String] {
        guard let plan, let report else { return [] }
        let open = Set(reminders.map(\.id))
        return plan.tasks.compactMap { t in
            guard !t.isSynthetic, t.key.hasPrefix("task:"), report.matchingKeys.contains(t.key) else { return nil }
            let id = String(t.key.dropFirst("task:".count))
            return open.contains(id) ? id : nil
        }
    }

    func completeMigratedInReminders() async {
        let ids = completableIds
        guard !ids.isEmpty, !isRunning else { return }
        busy = "Updating Reminders…"
        defer { busy = nil }
        do {
            let n = try reader.complete(ids: ids)
            completedInReminders = n
            append("Marked \(n) reminder\(n == 1 ? "" : "s") as completed in Apple Reminders.")
            await loadReminders()
        } catch {
            errorMessage = describe(error)
        }
    }

    func resetHistory() async {
        do {
            try Ledger(url: Paths.ledger).reset()
            report = nil
            summary = nil
            await buildPreview()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func append(_ line: String) {
        if log.last != line { log.append(line) }
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Navigation

    func canEnter(_ target: Step) -> Bool {
        if isRunning { return target == .migrate }
        switch target {
        case .connect: return true
        case .choose: return access == .granted
        case .preview: return access == .granted && !selected.isEmpty
        case .migrate: return access == .granted && !selected.isEmpty && plan != nil && tokenState == .ok
        }
    }

    var nextBlocker: String? {
        switch step {
        case .connect: return access == .granted ? nil : "Allow access to Reminders to continue."
        case .choose: return selected.isEmpty ? "Choose at least one list." : nil
        case .preview:
            if tokenState != .ok { return "Connect Todoist in step 1 to migrate." }
            return plan == nil ? "Waiting for the preview." : nil
        case .migrate: return nil
        }
    }
}
