import Foundation

/// HTTP client for the Todoist API v1. Retries rate limits, server errors and network failures.
public final class TodoistClient: TodoistAPI, @unchecked Sendable {
    private let token: String
    private let session: URLSession
    private let base = URL(string: "https://api.todoist.com/api/v1/")!
    private let maxAttempts = 6

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: TodoistAPI

    public func listProjects() async throws -> [TDProject] {
        try await getAll("projects", query: [:])
    }

    public func createProject(name: String, parentId: String?, requestId: String) async throws -> TDProject {
        struct Body: Encodable { var name: String; var parentId: String? }
        return try await post("projects", body: Body(name: name, parentId: parentId), requestId: requestId)
    }

    public func listSections(projectId: String) async throws -> [TDSection] {
        try await getAll("sections", query: ["project_id": projectId])
    }

    public func createSection(name: String, projectId: String, requestId: String) async throws -> TDSection {
        struct Body: Encodable { var name: String; var projectId: String }
        return try await post("sections", body: Body(name: name, projectId: projectId), requestId: requestId)
    }

    public func listTasks(projectId: String) async throws -> [TDTask] {
        try await getAll("tasks", query: ["project_id": projectId])
    }

    public func createTask(_ body: TDTaskCreate, requestId: String) async throws -> TDTask {
        try await post("tasks", body: body, requestId: requestId)
    }

    public func updateTask(id: String, _ changes: TDTaskUpdate) async throws -> TDTask {
        try await post("tasks/\(id)", body: changes, requestId: UUID().uuidString)
    }

    public func listReminders(taskId: String?) async throws -> [TDReminder] {
        try await getAll("reminders", query: taskId.map { ["task_id": $0] } ?? [:])
    }

    public func createReminder(_ body: TDReminderCreate, requestId: String) async throws -> TDReminder {
        try await post("reminders", body: body, requestId: requestId)
    }

    // MARK: Plumbing

    private struct Page<T: Decodable>: Decodable {
        var results: [T]
        var nextCursor: String?
    }

    private func getAll<T: Decodable>(_ path: String, query: [String: String]) async throws -> [T] {
        var all: [T] = []
        var cursor: String?
        repeat {
            var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            items.append(URLQueryItem(name: "limit", value: "200"))
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            comps.queryItems = items
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "GET"
            let data = try await send(req)
            let page: Page<T>
            do { page = try decoder.decode(Page<T>.self, from: data) }
            catch { throw TodoistError.badResponse("could not read the list of \(path): \(error)") }
            all.append(contentsOf: page.results)
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B, requestId: String) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        req.httpBody = try encoder.encode(body)
        let data = try await send(req)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw TodoistError.badResponse("could not read the reply to \(path): \(error)") }
    }

    private func send(_ original: URLRequest) async throws -> Data {
        var req = original
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var lastError: TodoistError = .network("no attempt was made")
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw TodoistError.badResponse("not an HTTP response")
                }
                switch http.statusCode {
                case 200..<300:
                    return data
                case 401, 403:
                    if http.statusCode == 401 { throw TodoistError.unauthorized }
                    throw TodoistError.http(status: 403, message: Self.message(from: data))
                case 429:
                    lastError = .http(status: 429, message: "rate limited")
                    let header = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    try await pause(min(header ?? Double(10 * attempt), 120))
                case 500..<600:
                    lastError = .http(status: http.statusCode, message: Self.message(from: data))
                    try await pause(pow(2, Double(attempt - 1)))
                default:
                    throw TodoistError.http(status: http.statusCode, message: Self.message(from: data))
                }
            } catch let e as TodoistError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = .network(error.localizedDescription)
                try await pause(pow(2, Double(attempt - 1)))
            }
        }
        throw lastError
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
    }

    private static func message(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = obj["error"] as? String {
            if let extra = obj["error_extra"] as? [String: Any], !extra.isEmpty {
                return "\(error) \(extra)"
            }
            return error
        }
        let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
        return text.isEmpty ? "no details" : text
    }
}
