import Foundation

/// Durable record of which source item became which Todoist object.
/// It is saved after every single creation, so an interrupted run can resume without duplicates.
public final class Ledger: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var todoistId: String
        public var recordedAt: Date
        /// "created", "adopted" (found an identical task already there) or "existing".
        public var how: String
    }

    private struct File: Codable {
        var account: String?
        var entries: [String: Entry]
    }

    public let url: URL?
    /// Id of the Todoist Inbox the ledger belongs to; guards against using it with another account.
    public private(set) var account: String?
    public private(set) var entries: [String: Entry] = [:]

    /// In-memory ledger (tests) when `url` is nil.
    public init(url: URL?) throws {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(File.self, from: Data(contentsOf: url))
        account = file.account
        entries = file.entries
    }

    public subscript(key: String) -> Entry? { entries[key] }

    public var knownIds: Set<String> { Set(entries.values.map(\.todoistId)) }

    public func setAccount(_ id: String) throws {
        guard account != id else { return }
        account = id
        try save()
    }

    public func record(_ key: String, id: String, how: String) throws {
        entries[key] = Entry(todoistId: id, recordedAt: Date(), how: how)
        try save()
    }

    public func forget(_ key: String) throws {
        entries[key] = nil
        try save()
    }

    public func reset() throws {
        entries = [:]
        account = nil
        try save()
    }

    private func save() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(account: account, entries: entries)).write(to: url, options: .atomic)
    }
}
