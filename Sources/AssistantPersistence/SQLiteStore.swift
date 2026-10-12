import AssistantCore
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

    static let schemaVersion = 2

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
        try execute("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    /// Each schema version only adds; running it again is harmless.
    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                short_name TEXT NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('active', 'archived'))
            );
            CREATE TABLE IF NOT EXISTS matchers (
                project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('repoPath', 'urlPrefix')),
                pattern TEXT NOT NULL,
                PRIMARY KEY (project_id, position)
            );
            INSERT INTO meta (key, value) VALUES ('schema_version', '\(Self.schemaVersion)')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)
    }

    deinit {
        sqlite3_close(db)  // Also frees the handle sqlite3_open returns on failure; nil is a no-op.
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }
    }

    private func execute(_ sql: String, _ values: String...) throws {
        guard !values.isEmpty else { return try executeScript(sql) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func rows(_ sql: String, columns: Int32) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<columns).map { String(cString: sqlite3_column_text(statement, $0)) })
        }
        return result
    }

    private func lastError() -> Failure {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }

    // SQLITE_TRANSIENT: SQLite copies the bound text before the Swift string goes away.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func executeScript(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw Failure.sqlite(message)
        }
    }
}

extension SQLiteStore: ProjectStore {
    public func loadProjects() -> [Project] {
        do {
            let matchers = try rows("SELECT project_id, kind, pattern FROM matchers ORDER BY project_id, position;", columns: 3)
            let byProject = Dictionary(grouping: matchers, by: { $0[0] })
            return try rows("SELECT id, name, short_name, status FROM projects;", columns: 4).compactMap { row in
                guard let uuid = UUID(uuidString: row[0]), let status = Project.Status(rawValue: row[3]) else { return nil }
                let matchers: [Matcher] = (byProject[row[0]] ?? []).compactMap { m in
                    switch m[1] {
                    case "repoPath": .repoPath(m[2])
                    case "urlPrefix": .urlPrefix(m[2])
                    default: nil
                    }
                }
                return Project(id: Project.ID(uuid), name: row[1], shortName: row[2], status: status, matchers: matchers)
            }
        } catch {
            NSLog("TodoAgent: couldn't load Projects: \(error)")
            return []
        }
    }

    public func save(_ project: Project) {
        let id = project.id.rawValue.uuidString
        do {
            try execute("BEGIN IMMEDIATE;")
            try execute("""
                INSERT INTO projects (id, name, short_name, status) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, short_name = excluded.short_name, status = excluded.status;
                """, id, project.name, project.shortName, project.status.rawValue)
            try execute("DELETE FROM matchers WHERE project_id = ?;", id)
            for (position, matcher) in project.matchers.enumerated() {
                let kind = switch matcher { case .repoPath: "repoPath"; case .urlPrefix: "urlPrefix" }
                try execute("INSERT INTO matchers (project_id, position, kind, pattern) VALUES (?, ?, ?, ?);",
                            id, String(position), kind, matcher.pattern)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            NSLog("TodoAgent: couldn't save Project \(project.name): \(error)")
        }
    }
}
