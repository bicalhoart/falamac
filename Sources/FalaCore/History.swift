import Foundation

public struct Entry: Codable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let text: String
    public let seconds: Double

    public init(id: UUID = UUID(), date: Date = Date(), text: String, seconds: Double) {
        self.id = id; self.date = date; self.text = text; self.seconds = seconds
    }
}

public enum Retention {
    public static let maximumBytes = 10 * 1024 * 1024

    public static func prune(_ entries: [Entry], days: Int, now: Date = Date(), maxBytes: Int = maximumBytes) throws -> [Entry] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(min(days, 30)) * 86400)
        var kept = entries.filter { $0.date > cutoff && $0.date <= now }.sorted { $0.date > $1.date }
        let encoder = JSONEncoder()
        // A count bound also avoids expensive serialization of an unbounded history.
        kept = Array(kept.prefix(3000))
        while try !kept.isEmpty && encoder.encode(kept).count > maxBytes {
            kept.removeLast()
        }
        return kept
    }
}

public final class HistoryStore {
    public let directory: URL
    public private(set) var entries: [Entry] = []
    private var file: URL { directory.appendingPathComponent("history.json") }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: file.path) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Retention.maximumBytes else { throw StorageError.tooLarge }
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
        }
    }

    public func clean(days: Int, now: Date = Date()) throws {
        try persist(Retention.prune(entries, days: days, now: now))
    }

    public func add(_ entry: Entry, days: Int) throws {
        try persist(Retention.prune([entry] + entries, days: days))
    }

    public func removeAll() throws { try persist([]) }

    private func persist(_ next: [Entry]) throws {
        let data = try JSONEncoder().encode(next)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries = next
    }
}

public enum StorageError: LocalizedError {
    case tooLarge
    public var errorDescription: String? { "O arquivo de histórico excede 10 MB. Abra a pasta de dados para revisá-lo." }
}
