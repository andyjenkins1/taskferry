import Foundation
import TaskFerryCore
import Security

enum Paths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskFerry", isDirectory: true)
    }

    /// Record of what has been migrated. Deleting it makes the app forget, not undo.
    static var ledger: URL { support.appendingPathComponent("ledger.json") }

    /// Optional mapping file describing what the Reminders API cannot read:
    /// list groups, sections, subtasks and link previews. See Examples/mapping.example.json.
    static var mapping: URL { support.appendingPathComponent("mapping.json") }

    static var existingMapping: URL? {
        FileManager.default.fileExists(atPath: mapping.path) ? mapping : nil
    }
}

/// The Todoist API token lives in the login keychain, never in a file.
enum Keychain {
    private static let service = "io.github.andyjenkins1.taskferry"
    private static let account = "todoist-api-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// `--dry-run <file>`: reads Reminders, builds the plan for every list and writes a summary.
/// Nothing is sent to Todoist.
enum DryRun {
    static func run(outputPath: String) async {
        var lines: [String] = []
        func finish() {
            try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        let reader = RemindersReader()
        guard await reader.requestAccess() else {
            lines.append("No access to Reminders (status \(reader.status.rawValue)).")
            return finish()
        }
        let lists = reader.lists()
        let reminders = await reader.openReminders()
        var supplement = Supplement.empty
        if let url = Paths.existingMapping {
            do { supplement = try Supplement.load(from: url); lines.append("mapping file: loaded") }
            catch { lines.append("mapping file could not be read: \(error)") }
        } else {
            lines.append("mapping file: none")
        }

        // Order lists the way the app does: ungrouped first, then group by group.
        let grouped = supplement.groups.flatMap { g in
            g.lists.flatMap { t in lists.filter { Supplement.normalize($0.title) == Supplement.normalize(t) } }
        }
        let ordered = lists.filter { l in !grouped.contains(l) } + grouped
        let plan = Planner.makePlan(lists: ordered, reminders: reminders, supplement: supplement)

        lines.append("lists: \(lists.count), open reminders: \(reminders.count)")
        lines.append("plan: \(plan.projects.count) projects, \(plan.sections.count) sections, \(plan.tasks.count) tasks, \(plan.alertCount) alerts")
        lines.append("")
        lines.append("PROJECTS")
        for p in plan.projects {
            let depth = p.parentKey == nil ? 0 : 1
            let count = plan.tasks.filter { $0.projectKey == p.key }.count
            lines.append(String(repeating: "  ", count: depth) + "- \(p.name)\(p.isInbox ? " [Todoist Inbox]" : "") (\(count) tasks)")
        }
        lines.append("")
        lines.append("SECTIONS")
        for s in plan.sections {
            lines.append("- \(s.name): \(plan.tasks.filter { $0.sectionKey == s.key }.count) tasks")
        }
        lines.append("")
        lines.append("SUBTASKS")
        for parent in plan.tasks where plan.tasks.contains(where: { $0.parentKey == parent.key }) {
            let n = plan.tasks.filter { $0.parentKey == parent.key }.count
            lines.append("- \(parent.payload.content)\(parent.isSynthetic ? " [recreated parent]" : ""): \(n) subtasks")
        }
        lines.append("")
        lines.append("FIELDS")
        let real = plan.tasks.filter { !$0.isSynthetic }
        lines.append("- all-day due: \(real.filter { $0.payload.dueDate != nil }.count)")
        lines.append("- timed due: \(real.filter { $0.payload.dueInstant != nil }.count)")
        lines.append("- repeating: \(real.filter { $0.payload.dueString != nil }.count)")
        lines.append("- priority set: \(real.filter { $0.payload.priority > 1 }.count)")
        lines.append("- with description: \(real.filter { !$0.payload.description.isEmpty }.count)")
        lines.append("- with alerts: \(real.filter { !$0.alerts.isEmpty }.count)")
        let urlCount = reminders.filter { !($0.url ?? "").isEmpty }.count
        let urlCarried = reminders.filter { r in
            guard let u = r.url, !u.isEmpty else { return false }
            guard let t = plan.tasks.first(where: { $0.key == "task:\(r.id)" }) else { return false }
            return t.payload.content.contains(u) || t.payload.description.contains(u)
        }.count
        lines.append("- URL field set: \(urlCount), carried into title or description: \(urlCarried)")
        lines.append("- start date differs from due: \(real.filter { $0.payload.description.contains("Start: ") }.count)")
        for r in reminders where r.start != nil && r.start != r.due {
            let s = r.start.map { Mapping.describe($0, .current) } ?? "-"
            let d = r.due.map { Mapping.describe($0, .current) } ?? "none"
            lines.append("    start \(s) | due \(d)")
        }
        lines.append("")
        lines.append("WARNINGS (\(plan.warnings.count))")
        for w in plan.warnings {
            lines.append("- [\(w.list)] \(String(w.subject.prefix(60))): \(w.message)")
        }
        finish()
    }
}
