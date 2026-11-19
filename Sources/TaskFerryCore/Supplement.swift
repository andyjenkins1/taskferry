import Foundation

/// Picks out one reminder by its title. Use `exact` for short titles, `contains` otherwise.
public struct Matcher: Codable, Equatable, Sendable {
    public var contains: String?
    public var exact: String?

    public init(contains: String? = nil, exact: String? = nil) {
        self.contains = contains
        self.exact = exact
    }

    public func matches(_ title: String) -> Bool {
        let t = Supplement.normalize(title)
        if let e = exact { return t == Supplement.normalize(e) }
        if let c = contains {
            let needle = Supplement.normalize(c)
            return !needle.isEmpty && t.contains(needle)
        }
        return false
    }

    public var label: String { exact ?? contains ?? "(empty)" }
}

/// Structure that Apple's Reminders API does not expose: list groups, sections and subtasks.
/// It is written by hand (by looking at the Reminders app) and kept in `mapping.json`.
public struct Supplement: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable {
        public var name: String
        public var lists: [String]
        public init(name: String, lists: [String]) { self.name = name; self.lists = lists }
    }

    public struct SectionMap: Codable, Equatable, Sendable {
        public var list: String
        public var name: String
        public var reminders: [Matcher]
        public init(list: String, name: String, reminders: [Matcher]) {
            self.list = list; self.name = name; self.reminders = reminders
        }
    }

    public struct SubtaskMap: Codable, Equatable, Sendable {
        public var list: String
        /// Title of the parent. If no open reminder has this title, a parent task is created.
        public var parentTitle: String
        public var parentNote: String?
        public var children: [Matcher]
        public init(list: String, parentTitle: String, parentNote: String? = nil, children: [Matcher]) {
            self.list = list; self.parentTitle = parentTitle; self.parentNote = parentNote; self.children = children
        }
    }

    /// The address behind a link preview ("x.com", "github.com" chip) on a reminder.
    public struct LinkMap: Codable, Equatable, Sendable {
        public var list: String
        public var reminder: Matcher
        public var url: String
        public init(list: String, reminder: Matcher, url: String) {
            self.list = list; self.reminder = reminder; self.url = url
        }
    }

    /// Reminders lists that go into the Todoist Inbox instead of a project of their own.
    public var inboxLists: [String]
    public var groups: [Group]
    public var sections: [SectionMap]
    public var subtasks: [SubtaskMap]
    public var links: [LinkMap]

    public init(inboxLists: [String] = [], groups: [Group] = [], sections: [SectionMap] = [],
                subtasks: [SubtaskMap] = [], links: [LinkMap] = []) {
        self.inboxLists = inboxLists
        self.groups = groups
        self.sections = sections
        self.subtasks = subtasks
        self.links = links
    }

    public static let empty = Supplement()

    enum CodingKeys: String, CodingKey { case inboxLists, groups, sections, subtasks, links }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inboxLists = try c.decodeIfPresent([String].self, forKey: .inboxLists) ?? []
        groups = try c.decodeIfPresent([Group].self, forKey: .groups) ?? []
        sections = try c.decodeIfPresent([SectionMap].self, forKey: .sections) ?? []
        subtasks = try c.decodeIfPresent([SubtaskMap].self, forKey: .subtasks) ?? []
        links = try c.decodeIfPresent([LinkMap].self, forKey: .links) ?? []
    }

    public static func load(from url: URL) throws -> Supplement {
        try JSONDecoder().decode(Supplement.self, from: Data(contentsOf: url))
    }

    public func groupName(forList title: String) -> String? {
        let t = Supplement.normalize(title)
        return groups.first { $0.lists.contains { Supplement.normalize($0) == t } }?.name
    }

    public func isInboxList(_ title: String) -> Bool {
        let t = Supplement.normalize(title)
        return inboxLists.contains { Supplement.normalize($0) == t }
    }

    /// Lower-cased, trimmed, with runs of whitespace collapsed.
    public static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
