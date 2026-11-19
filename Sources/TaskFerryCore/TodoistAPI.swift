import Foundation

// Shapes follow the Todoist API v1 OpenAPI spec (https://developer.todoist.com/api/v1/).
// JSON keys are snake_case; the client converts to and from camelCase.

public struct TDProject: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var parentId: String?
    public var inboxProject: Bool?
    public var isArchived: Bool?
    public var isDeleted: Bool?

    public init(id: String, name: String, parentId: String? = nil, inboxProject: Bool? = nil,
                isArchived: Bool? = nil, isDeleted: Bool? = nil) {
        self.id = id; self.name = name; self.parentId = parentId
        self.inboxProject = inboxProject; self.isArchived = isArchived; self.isDeleted = isDeleted
    }
}

public struct TDSection: Codable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var name: String

    public init(id: String, projectId: String, name: String) {
        self.id = id; self.projectId = projectId; self.name = name
    }
}

public struct TDDue: Codable, Equatable, Sendable {
    /// "YYYY-MM-DD", "YYYY-MM-DDTHH:MM:SS" (floating) or "YYYY-MM-DDTHH:MM:SSZ" (fixed), optionally with fractional seconds.
    public var date: String?
    public var timezone: String?
    public var string: String?
    public var isRecurring: Bool?

    public init(date: String? = nil, timezone: String? = nil, string: String? = nil, isRecurring: Bool? = nil) {
        self.date = date; self.timezone = timezone; self.string = string; self.isRecurring = isRecurring
    }
}

public struct TDTask: Codable, Equatable, Sendable {
    public var id: String
    public var projectId: String?
    public var sectionId: String?
    public var parentId: String?
    public var content: String
    public var description: String?
    /// 1 normal … 4 urgent.
    public var priority: Int?
    public var due: TDDue?
    public var labels: [String]?

    public init(id: String, projectId: String? = nil, sectionId: String? = nil, parentId: String? = nil,
                content: String, description: String? = nil, priority: Int? = nil, due: TDDue? = nil,
                labels: [String]? = nil) {
        self.id = id; self.projectId = projectId; self.sectionId = sectionId; self.parentId = parentId
        self.content = content; self.description = description; self.priority = priority; self.due = due
        self.labels = labels
    }
}

/// Only the fields that are set are sent.
public struct TDTaskUpdate: Codable, Equatable, Sendable {
    public var content: String?
    public var priority: Int?
    public var labels: [String]?

    public init(content: String? = nil, priority: Int? = nil, labels: [String]? = nil) {
        self.content = content; self.priority = priority; self.labels = labels
    }
}

public struct TDTaskCreate: Codable, Equatable, Sendable {
    public var content: String
    public var description: String?
    public var projectId: String?
    public var sectionId: String?
    public var parentId: String?
    public var priority: Int?
    public var dueString: String?
    public var dueDate: String?
    public var dueDatetime: String?
    public var dueLang: String?

    public init(content: String) { self.content = content }
}

public struct TDReminderDue: Codable, Equatable, Sendable {
    public var date: String?
    public var timezone: String?
    public init(date: String? = nil, timezone: String? = nil) { self.date = date; self.timezone = timezone }
}

public struct TDReminder: Codable, Equatable, Sendable {
    public var id: String
    /// The task the reminder belongs to.
    public var itemId: String?
    public var type: String?
    public var minuteOffset: Int?
    public var due: TDReminderDue?
    public var isDeleted: Bool?

    public init(id: String, itemId: String? = nil, type: String? = nil, minuteOffset: Int? = nil,
                due: TDReminderDue? = nil, isDeleted: Bool? = nil) {
        self.id = id; self.itemId = itemId; self.type = type
        self.minuteOffset = minuteOffset; self.due = due; self.isDeleted = isDeleted
    }
}

public struct TDReminderCreate: Codable, Equatable, Sendable {
    public var taskId: String
    /// "relative" or "absolute".
    public var reminderType: String
    public var minuteOffset: Int?
    public var due: TDReminderDue?

    public init(taskId: String, reminderType: String, minuteOffset: Int? = nil, due: TDReminderDue? = nil) {
        self.taskId = taskId; self.reminderType = reminderType; self.minuteOffset = minuteOffset; self.due = due
    }
}

public enum TodoistError: Error, LocalizedError, Equatable {
    case unauthorized
    case http(status: Int, message: String)
    case network(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Todoist rejected the API token. Check it in step 1."
        case .http(let status, let message): return "Todoist returned an error (\(status)): \(message)"
        case .network(let m): return "Could not reach Todoist: \(m)"
        case .badResponse(let m): return "Unexpected reply from Todoist: \(m)"
        }
    }
}

/// Everything the migration needs from Todoist. `requestId` is sent as X-Request-Id
/// and stays the same across retries of one logical operation.
public protocol TodoistAPI: Sendable {
    func listProjects() async throws -> [TDProject]
    func createProject(name: String, parentId: String?, requestId: String) async throws -> TDProject
    func listSections(projectId: String) async throws -> [TDSection]
    func createSection(name: String, projectId: String, requestId: String) async throws -> TDSection
    func listTasks(projectId: String) async throws -> [TDTask]
    func createTask(_ body: TDTaskCreate, requestId: String) async throws -> TDTask
    func updateTask(id: String, _ changes: TDTaskUpdate) async throws -> TDTask
    func listReminders(taskId: String?) async throws -> [TDReminder]
    func createReminder(_ body: TDReminderCreate, requestId: String) async throws -> TDReminder
}
