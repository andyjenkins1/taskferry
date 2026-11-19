import Foundation

// The plan is the complete, ordered description of what will exist in Todoist.
// Every item has a stable `key` derived from its source, which is what the ledger records.

public struct PlanProject: Identifiable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var parentKey: String?
    /// The Todoist Inbox. Never created, only looked up.
    public var isInbox: Bool
    public var id: String { key }
}

public struct PlanSection: Identifiable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var projectKey: String
    public var id: String { key }
}

public struct PlanAlert: Identifiable, Equatable, Sendable {
    public var key: String
    public var alert: PlannedAlert
    public var id: String { key }
}

public struct PlanTask: Identifiable, Equatable, Sendable {
    public var key: String
    public var payload: TaskPayload
    public var projectKey: String
    public var sectionKey: String?
    public var parentKey: String?
    public var alerts: [PlanAlert]
    /// A parent task this tool creates because the original parent is completed in Reminders.
    public var isSynthetic: Bool
    public var sourceListTitle: String
    public var id: String { key }
}

public struct PlanWarning: Identifiable, Hashable, Sendable {
    public var list: String
    public var subject: String
    public var message: String
    public var id: String { "\(list)|\(subject)|\(message)" }

    public init(list: String, subject: String, message: String) {
        self.list = list
        self.subject = subject
        self.message = message
    }
}

public struct MigrationPlan: Equatable, Sendable {
    /// Parents always come before their children.
    public var projects: [PlanProject] = []
    public var sections: [PlanSection] = []
    /// Parents always come before their subtasks.
    public var tasks: [PlanTask] = []
    public var warnings: [PlanWarning] = []

    public var alertCount: Int { tasks.reduce(0) { $0 + $1.alerts.count } }
}

public struct PlanOptions: Equatable, Sendable {
    /// When set, everything is created under one top-level project with this name.
    public var containerProject: String?
    public init(containerProject: String? = nil) { self.containerProject = containerProject }
}

public enum Planner {
    public static func makePlan(
        lists: [SourceList],
        reminders: [SourceReminder],
        supplement: Supplement,
        options: PlanOptions = PlanOptions(),
        timeZone: TimeZone = .current
    ) -> MigrationPlan {
        var plan = MigrationPlan()
        func warn(_ list: String, _ subject: String, _ message: String) {
            let w = PlanWarning(list: list, subject: subject, message: message)
            if !plan.warnings.contains(w) { plan.warnings.append(w) }
        }

        // Titles are how the supplement refers to lists, so duplicates are ambiguous.
        var titleCounts: [String: Int] = [:]
        for l in lists { titleCounts[Supplement.normalize(l.title), default: 0] += 1 }
        for l in lists where titleCounts[Supplement.normalize(l.title)]! > 1 {
            warn(l.title, "List", "More than one selected list has this name; groups, sections and subtasks from the mapping file apply to all of them.")
        }

        // MARK: Projects
        var topParent: String?
        if let name = options.containerProject?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            plan.projects.append(PlanProject(key: "project:container", name: name, parentKey: nil, isInbox: false))
            topParent = "project:container"
        }

        var projectKeyForList: [String: String] = [:]
        var placed = Set<String>()
        for group in supplement.groups {
            let wanted = group.lists.map(Supplement.normalize)
            let members = wanted.flatMap { w in lists.filter { Supplement.normalize($0.title) == w && !placed.contains($0.id) } }
            guard !members.isEmpty else { continue }
            let groupKey = "project:group:\(group.name)"
            plan.projects.append(PlanProject(key: groupKey, name: group.name, parentKey: topParent, isInbox: false))
            for l in members {
                let key = "project:list:\(l.id)"
                plan.projects.append(PlanProject(key: key, name: l.title, parentKey: groupKey, isInbox: false))
                projectKeyForList[l.id] = key
                placed.insert(l.id)
            }
        }
        for l in lists where !placed.contains(l.id) {
            if supplement.isInboxList(l.title) {
                if !plan.projects.contains(where: { $0.isInbox }) {
                    plan.projects.append(PlanProject(key: "project:inbox", name: "Inbox", parentKey: nil, isInbox: true))
                }
                projectKeyForList[l.id] = "project:inbox"
            } else {
                let key = "project:list:\(l.id)"
                plan.projects.append(PlanProject(key: key, name: l.title, parentKey: topParent, isInbox: false))
                projectKeyForList[l.id] = key
            }
            placed.insert(l.id)
        }

        // MARK: Tasks, sections and subtasks, list by list
        for list in lists {
            guard let projectKey = projectKeyForList[list.id] else { continue }
            let items = reminders.filter { $0.listId == list.id }.sorted { a, b in
                switch (a.created, b.created) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
            let normTitle = Supplement.normalize(list.title)

            // Sections.
            var sectionOf: [String: String] = [:]
            let sectionMaps = supplement.sections.filter { Supplement.normalize($0.list) == normTitle }
            for map in sectionMaps {
                let sectionKey = "section:\(list.id):\(map.name)"
                var used = false
                for m in map.reminders {
                    let hits = items.filter { m.matches($0.title) }
                    if hits.isEmpty {
                        warn(list.title, map.name, "No open reminder matches “\(m.label)”, so nothing was put in this section for it.")
                    } else if hits.count > 1 {
                        warn(list.title, map.name, "“\(m.label)” matches \(hits.count) reminders; none of them was put in this section.")
                    } else if let existing = sectionOf[hits[0].id], existing != sectionKey {
                        warn(list.title, hits[0].title, "Matched by two sections; the first one is kept.")
                    } else {
                        sectionOf[hits[0].id] = sectionKey
                        used = true
                    }
                }
                if used { plan.sections.append(PlanSection(key: sectionKey, name: map.name, projectKey: projectKey)) }
            }
            if !sectionMaps.isEmpty {
                for r in items where sectionOf[r.id] == nil {
                    warn(list.title, r.title, "Not assigned to a section in the mapping file; it goes into the project without a section.")
                }
            }

            // Subtasks.
            var parentOf: [String: String] = [:]
            var synthetic: [PlanTask] = []
            for map in supplement.subtasks where Supplement.normalize(map.list) == normTitle {
                var children: [SourceReminder] = []
                for m in map.children {
                    let hits = items.filter { m.matches($0.title) }
                    if hits.isEmpty {
                        warn(list.title, map.parentTitle, "No open reminder matches the subtask “\(m.label)”.")
                    } else if hits.count > 1 {
                        warn(list.title, map.parentTitle, "Subtask “\(m.label)” matches \(hits.count) reminders; it was left as a normal task.")
                    } else {
                        children.append(hits[0])
                    }
                }
                guard !children.isEmpty else { continue }
                let childIds = Set(children.map(\.id))
                let parentNorm = Supplement.normalize(map.parentTitle)
                let parentKey: String
                if let real = items.first(where: { Supplement.normalize($0.title) == parentNorm && !childIds.contains($0.id) }) {
                    parentKey = "task:\(real.id)"
                    // Todoist keeps subtasks in the parent's section.
                    for c in children { sectionOf[c.id] = sectionOf[real.id] }
                } else {
                    parentKey = "task:synthetic:\(list.id):\(map.parentTitle)"
                    let note = map.parentNote ?? "Created by the migration: the original parent reminder was completed in Apple Reminders."
                    synthetic.append(PlanTask(
                        key: parentKey,
                        payload: TaskPayload(content: map.parentTitle, description: note),
                        projectKey: projectKey, sectionKey: nil, parentKey: nil, alerts: [],
                        isSynthetic: true, sourceListTitle: list.title))
                    for c in children { sectionOf[c.id] = nil }
                }
                for c in children { parentOf[c.id] = parentKey }
            }

            // Link previews.
            var linkOf: [String: [String]] = [:]
            for map in supplement.links where Supplement.normalize(map.list) == normTitle {
                let hits = items.filter { map.reminder.matches($0.title) }
                if hits.count == 1 {
                    linkOf[hits[0].id, default: []].append(map.url)
                } else {
                    warn(list.title, map.reminder.label, hits.isEmpty
                         ? "No open reminder matches this link preview entry, so its link was not added."
                         : "This link preview entry matches \(hits.count) reminders, so its link was not added.")
                }
            }

            var tasks: [PlanTask] = synthetic
            for r in items {
                var mapped = Mapping.map(r, timeZone: timeZone)
                for url in linkOf[r.id] ?? []
                where !mapped.payload.content.contains(url) && !mapped.payload.description.contains(url) {
                    mapped.payload.description += (mapped.payload.description.isEmpty ? "" : "\n\n") + url
                }
                for n in mapped.notes { warn(list.title, r.title, n) }
                let alerts = mapped.alerts.enumerated().map { PlanAlert(key: "reminder:\(r.id):\($0.offset)", alert: $0.element) }
                tasks.append(PlanTask(
                    key: "task:\(r.id)", payload: mapped.payload, projectKey: projectKey,
                    sectionKey: sectionOf[r.id], parentKey: parentOf[r.id], alerts: alerts,
                    isSynthetic: false, sourceListTitle: list.title))
            }
            // Parents first, otherwise keep the order.
            plan.tasks.append(contentsOf: tasks.filter { $0.parentKey == nil })
            plan.tasks.append(contentsOf: tasks.filter { $0.parentKey != nil })
        }
        return plan
    }
}
