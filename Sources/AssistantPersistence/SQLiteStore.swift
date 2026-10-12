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

    static let schemaVersion = 5

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
        try run("PRAGMA journal_mode = WAL;")
        try run("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    deinit {
        sqlite3_close(db)  // Also frees the handle sqlite3_open returns on failure; nil is a no-op.
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }
    }

    /// Brings any earlier schema up to `schemaVersion`, in one transaction.
    private func migrate() throws {
        try run("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        let stored = try rows("SELECT value FROM meta WHERE key = 'schema_version';", columns: 1).first.flatMap { Int($0[0]) } ?? 0
        guard stored < Self.schemaVersion else { return }

        try run("BEGIN IMMEDIATE;")
        do {
            if stored < 2 {
                try run("""
                    CREATE TABLE projects (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        short_name TEXT NOT NULL,
                        status TEXT NOT NULL CHECK (status IN ('active', 'archived'))
                    );
                    \(Self.matchersTable("matchers"))
                    """)
            } else if stored < 3 {
                // v3 allows calendar keywords; SQLite can't change a CHECK, so rebuild the table.
                try run("""
                    \(Self.matchersTable("matchers_v3"))
                    INSERT INTO matchers_v3 SELECT project_id, position, kind, pattern FROM matchers;
                    DROP TABLE matchers;
                    ALTER TABLE matchers_v3 RENAME TO matchers;
                    """)
            }
            if stored < 4 {
                // Tasks and log entries are stored whole, as JSON, keyed for lookup.
                try run("""
                    CREATE TABLE tasks (id TEXT PRIMARY KEY, json TEXT NOT NULL);
                    CREATE TABLE operation_log (id TEXT PRIMARY KEY, at REAL NOT NULL, json TEXT NOT NULL);
                    CREATE INDEX operation_log_at ON operation_log (at);
                    """)
            }
            if stored < 5 {
                // Small settings stored whole as JSON, e.g. Dara's tier rules.
                try run("CREATE TABLE settings (key TEXT PRIMARY KEY, json TEXT NOT NULL);")
            }
            try execute("""
                INSERT INTO meta (key, value) VALUES ('schema_version', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """, String(Self.schemaVersion))
            try run("COMMIT;")
        } catch {
            try? run("ROLLBACK;")
            throw error
        }
    }

    private static func matchersTable(_ name: String) -> String {
        """
        CREATE TABLE \(name) (
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('repoPath', 'urlPrefix', 'calendarKeyword')),
            pattern TEXT NOT NULL,
            PRIMARY KEY (project_id, position)
        );
        """
    }

    /// One statement with `?` placeholders bound to `values`.
    private func execute(_ sql: String, _ values: String...) throws {
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
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            result.append((0..<columns).map { String(cString: sqlite3_column_text(statement, $0)) })
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw lastError() }
        return result
    }

    private func lastError() -> Failure {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }

    // SQLITE_TRANSIENT: SQLite copies the bound text before the Swift string goes away.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Fixed SQL with no parameters, possibly several statements.
    private func run(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw Failure.sqlite(message)
        }
    }
}

extension SQLiteStore: AssistantStore {
    /// Everything stored. A row that can't be read is logged and skipped rather than taking the whole
    /// store down; the rest stays usable and persisted.
    public func load() throws -> StoreSnapshot {
        StoreSnapshot(
            projects: try loadProjects(),
            tasks: readable(Task.self, try rows("SELECT id, json FROM tasks;", columns: 2)),
            log: readable(LogEntry.self, try rows("SELECT id, json FROM operation_log ORDER BY at, rowid;", columns: 2)),
            guardrailRules: try loadGuardrailRules())
    }

    /// Dara's tier rules. Unlike other rows, unreadable rules fail the whole load: quietly falling
    /// back to the defaults would loosen what Dara made stricter (ADR 0002).
    private func loadGuardrailRules() throws -> [GuardrailRule] {
        guard let row = try rows("SELECT key, json FROM settings;", columns: 2).first(where: { $0[0] == Self.guardrailKey })
        else { return [] }
        do {
            return try JSONDecoder().decode([GuardrailRule].self, from: Data(row[1].utf8))
        } catch {
            throw Failure.sqlite("unreadable Guardrail rules: \(error)")
        }
    }

    private static let guardrailKey = "guardrail_rules"

    public func write(_ change: Change, log entries: [LogEntry]) throws {
        try run("BEGIN IMMEDIATE;")
        do {
            for project in change.projects { try upsert(project) }
            if let rules = change.guardrailRules {
                try execute("""
                    INSERT INTO settings (key, json) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET json = excluded.json;
                    """, Self.guardrailKey, try encode(rules))
            }
            for task in change.tasks {
                try execute("""
                    INSERT INTO tasks (id, json) VALUES (?, ?)
                    ON CONFLICT(id) DO UPDATE SET json = excluded.json;
                    """, task.id.rawValue.uuidString, try encode(task))
            }
            for entry in entries {
                try execute("INSERT INTO operation_log (id, at, json) VALUES (?, ?, ?);",
                            entry.id.rawValue.uuidString, String(entry.at.timeIntervalSinceReferenceDate), try encode(entry))
            }
            try run("COMMIT;")
        } catch {
            try? run("ROLLBACK;")
            throw error
        }
    }

    private func loadProjects() throws -> [Project] {
        let matchers = try rows("SELECT project_id, kind, pattern FROM matchers ORDER BY project_id, position;", columns: 3)
        let byProject = Dictionary(grouping: matchers, by: { $0[0] })
        return try rows("SELECT id, name, short_name, status FROM projects;", columns: 4).map { row in
            guard let uuid = UUID(uuidString: row[0]), let status = Project.Status(rawValue: row[3]) else {
                throw Failure.sqlite("unreadable Project row \(row[0])")
            }
            let matchers = try (byProject[row[0]] ?? []).map { m in
                guard let kind = Matcher.Kind(rawValue: m[1]) else { throw Failure.sqlite("unknown Matcher kind \(m[1])") }
                return Matcher(kind: kind, pattern: m[2])
            }
            return Project(id: Project.ID(uuid), name: row[1], shortName: row[2], status: status, matchers: matchers)
        }
    }

    /// Inside the caller's transaction.
    private func upsert(_ project: Project) throws {
        let id = project.id.rawValue.uuidString
        try execute("""
            INSERT INTO projects (id, name, short_name, status) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, short_name = excluded.short_name, status = excluded.status;
            """, id, project.name, project.shortName, project.status.rawValue)
        try execute("DELETE FROM matchers WHERE project_id = ?;", id)
        for (position, matcher) in project.matchers.enumerated() {
            try execute("INSERT INTO matchers (project_id, position, kind, pattern) VALUES (?, ?, ?, ?);",
                        id, String(position), matcher.kind.rawValue, matcher.pattern)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    /// Decodes each (id, json) row, skipping and logging any that can't be read.
    private func readable<T: Decodable>(_ type: T.Type, _ rows: [[String]]) -> [T] {
        rows.compactMap { row in
            do {
                return try JSONDecoder().decode(type, from: Data(row[1].utf8))
            } catch {
                NSLog("TodoAgent: skipped unreadable \(T.self) \(row[0]): \(error)")
                return nil
            }
        }
    }
}
