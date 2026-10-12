import Foundation
import SQLite3

/// The helper's SQLite store in Application Support. The helper is its only writer (ADR 0001):
/// an exclusive lock on a sidecar file stops a second helper from opening it.
public final class SQLiteStore {
    public enum Failure: Error, CustomStringConvertible {
        case alreadyOpenElsewhere(URL)
        case sqlite(String)

        public var description: String {
            switch self {
            case let .alreadyOpenElsewhere(url): "Another helper already owns \(url.path)"
            case let .sqlite(message): "SQLite: \(message)"
            }
        }
    }

    static let schemaVersion = 1

    public let url: URL
    private var db: OpaquePointer?
    private let lockDescriptor: Int32

    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("TodoAgent", isDirectory: true)
            .appendingPathComponent("assistant.sqlite")
    }

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        lockDescriptor = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        // Once every stored property is set, a throw still runs deinit, which releases the lock and the handle.
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure.alreadyOpenElsewhere(url)
        }

        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw Failure.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        try execute("PRAGMA journal_mode = WAL;")
        try execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        try execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '\(Self.schemaVersion)');")
    }

    deinit {
        sqlite3_close(db)  // Also frees the handle sqlite3_open returns on failure; nil is a no-op.
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw Failure.sqlite(message)
        }
    }
}
