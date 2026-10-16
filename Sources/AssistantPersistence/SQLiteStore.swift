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

    static let schemaVersion = 10

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
            if stored < 6 {
                // Project-level time blocks only: no titles or URLs.
                try run("""
                    CREATE TABLE now_history (
                        project_id TEXT NOT NULL, task_id TEXT, start REAL NOT NULL, end REAL NOT NULL
                    );
                    CREATE INDEX now_history_start ON now_history (start);
                    """)
            }
            if stored < 7 {
                // Metadata only: what was sent, by what, and its cost; never the content.
                try run("""
                    CREATE TABLE api_audit (
                        at REAL NOT NULL, purpose TEXT NOT NULL, model TEXT NOT NULL,
                        input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                        content_kind TEXT NOT NULL, cost_usd REAL NOT NULL
                    );
                    CREATE INDEX api_audit_at ON api_audit (at);
                    """)
            }
            if stored < 8 {
                // One Suggestion per email thread, ever, stored whole. Never an email body.
                try run("CREATE TABLE suggestions (thread_id TEXT PRIMARY KEY, json TEXT NOT NULL);")
            }
            if stored < 9 {
                // Digest lines: sender, subject and reason, never a body. Deleted once past their day.
                try run("CREATE TABLE digest (thread_id TEXT PRIMARY KEY, json TEXT NOT NULL);")
            }
            if stored >= 3 && stored < 10 {
                // v10 allows Sheet id Matchers: rebuild the table for its CHECK, as v3 did.
                try run("""
                    \(Self.matchersTable("matchers_v10"))
                    INSERT INTO matchers_v10 SELECT project_id, position, kind, pattern FROM matchers;
                    DROP TABLE matchers;
                    ALTER TABLE matchers_v10 RENAME TO matchers;
                    """)
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
            kind TEXT NOT NULL CHECK (kind IN ('repoPath', 'urlPrefix', 'calendarKeyword', 'sheetID')),
            pattern TEXT NOT NULL,
            PRIMARY KEY (project_id, position)
        );
        """
    }

    /// One statement with `?` placeholders bound to `values`; nil binds NULL.
    private func execute(_ sql: String, _ values: String?...) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            if let value {
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
            } else {
                sqlite3_bind_null(statement, Int32(index + 1))
            }
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
            settings: Settings(
                guardrailRules: try loadGuardrailRules(), neutrals: try loadNeutrals(), exclusions: try loadExclusions(),
                vips: try loadVIPs(), noiseSenders: try loadNoiseSenders(), sheets: try loadSheets()),
            suggestions: readable(Suggestion.self, try rows("SELECT thread_id, json FROM suggestions;", columns: 2)),
            mailCursor: try readSetting(Self.mailCursorKey),
            digest: readable(DigestLine.self, try rows("SELECT thread_id, json FROM digest;", columns: 2)),
            recipients: try readSetting(Self.recipientsKey)
                .flatMap { readable([String: Date].self, [[Self.recipientsKey, $0]]).first } ?? [:],
            notesCursor: try readSetting(Self.notesCursorKey).flatMap(Double.init).map(Date.init(timeIntervalSinceReferenceDate:)),
            sightings: try readJSON([Sighting].self, Self.sightingsKey) ?? [],
            dismissedProposals: try readJSON([Matcher].self, Self.dismissedProposalsKey) ?? [],
            projectsLastSeen: Dictionary(
                (try readJSON([String: Date].self, Self.projectsLastSeenKey) ?? [:])
                    .compactMap { key, date in UUID(uuidString: key).map { (Project.ID($0), date) } },
                uniquingKeysWith: max))
        // Now history isn't loaded at launch: nothing reads it until the history viewer (ticket 19).
    }

    /// Now history from `since` on, oldest first.
    public func history(since: Date) throws -> [NowBlock] {
        try rows("""
            SELECT project_id, COALESCE(task_id, ''), start, end FROM now_history
            WHERE start >= \(since.timeIntervalSinceReferenceDate) ORDER BY start;
            """, columns: 4)
            .compactMap { row in
                guard let project = UUID(uuidString: row[0]), let start = Double(row[2]), let end = Double(row[3])
                else { return nil }
                return NowBlock(
                    project: Project.ID(project), committedTask: UUID(uuidString: row[1]).map(Task.ID.init),
                    start: Date(timeIntervalSinceReferenceDate: start), end: Date(timeIntervalSinceReferenceDate: end))
            }
    }

    public func audit(_ call: APICall) throws {
        try execute("""
            INSERT INTO api_audit (at, purpose, model, input_tokens, output_tokens, content_kind, cost_usd)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, String(call.at.timeIntervalSinceReferenceDate), call.purpose.rawValue, call.model,
            String(call.inputTokens), String(call.outputTokens), call.contentKind.rawValue, String(call.costUSD))
    }

    public func apiSpend(since: Date) throws -> Double {
        try rows("SELECT COALESCE(SUM(cost_usd), 0) FROM api_audit WHERE at >= \(since.timeIntervalSinceReferenceDate);",
                 columns: 1).first.flatMap { Double($0[0]) } ?? 0
    }

    public func record(_ block: NowBlock) throws {
        try execute("INSERT INTO now_history (project_id, task_id, start, end) VALUES (?, ?, ?, ?);",
                    block.project.rawValue.uuidString, block.committedTask?.rawValue.uuidString,
                    String(block.start.timeIntervalSinceReferenceDate), String(block.end.timeIntervalSinceReferenceDate))
    }

    /// Gmail's history id, stored as the plain string.
    private static let mailCursorKey = "mail_cursor"
    /// The latest note modification read, as seconds since the reference date.
    private static let notesCursorKey = "notes_cursor"
    /// Unmatched windows' Matchers (a repo path, a site's first path, a sheet id) and the days seen: no titles.
    private static let sightingsKey = "sightings"
    private static let dismissedProposalsKey = "dismissed_proposals"
    private static let projectsLastSeenKey = "projects_last_seen"
    private static let vipsKey = "vips"
    private static let noiseSendersKey = "noise_senders"
    private static let sheetsKey = "sheets"
    /// When Dara last emailed each address: who, never what.
    private static let recipientsKey = "recent_recipients"
    private static let neutralsKey = "neutrals"
    private static let exclusionsKey = "exclusions"

    /// The exclude list. Unreadable, it fails the whole load: dropping it would start reading what
    /// Dara chose to keep private.
    private func loadExclusions() throws -> [Exclusion] {
        guard let json = try readSetting(Self.exclusionsKey) else { return [] }
        do {
            return try JSONDecoder().decode([Exclusion].self, from: Data(json.utf8))
        } catch {
            throw Failure.sqlite("unreadable exclude list: \(error)")
        }
    }

    /// Dara's Neutral apps and sites. Unreadable, they are logged and skipped: losing one only means
    /// that app or site counts as no Project again, which is the stricter reading.
    private func loadNeutrals() throws -> [NeutralKey] {
        guard let json = try readSetting(Self.neutralsKey) else { return [] }
        return readable([NeutralKey].self, [[Self.neutralsKey, json]]).first ?? []
    }

    /// Unreadable, VIPs are logged and skipped: their mail then meets the bulk rules, the stricter reading.
    private func loadVIPs() throws -> [String] {
        guard let json = try readSetting(Self.vipsKey) else { return [] }
        return readable([String].self, [[Self.vipsKey, json]]).first ?? []
    }

    /// Unreadable, "never from" senders are logged and skipped: their mail is triaged again.
    private func loadNoiseSenders() throws -> [String] {
        guard let json = try readSetting(Self.noiseSendersKey) else { return [] }
        return readable([String].self, [[Self.noiseSendersKey, json]]).first ?? []
    }

    /// Registered sheets. Unreadable, they are logged and skipped: no sheet is read until Dara
    /// registers it again, the stricter reading.
    private func loadSheets() throws -> [RegisteredSheet] {
        guard let json = try readSetting(Self.sheetsKey) else { return [] }
        return readable([RegisteredSheet].self, [[Self.sheetsKey, json]]).first ?? []
    }

    /// A JSON setting, or nil if absent. Unreadable, it is logged and skipped: these are bookkeeping
    /// that only make the assistant offer a little more or a little later.
    private func readJSON<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        guard let json = try readSetting(key) else { return nil }
        return readable(type, [[key, json]]).first
    }

    private func readSetting(_ key: String) throws -> String? {
        try rows("SELECT key, json FROM settings;", columns: 2).first { $0[0] == key }?[1]
    }

    /// Dara's tier rules. Unlike other rows, unreadable rules fail the whole load: quietly falling
    /// back to the defaults would loosen what Dara made stricter (ADR 0002).
    private func loadGuardrailRules() throws -> [GuardrailRule] {
        guard let json = try readSetting(Self.guardrailKey) else { return [] }
        do {
            return try JSONDecoder().decode([GuardrailRule].self, from: Data(json.utf8))
        } catch {
            throw Failure.sqlite("unreadable Guardrail rules: \(error)")
        }
    }

    private static let guardrailKey = "guardrail_rules"

    public func write(_ change: Change, log entries: [LogEntry]) throws {
        try run("BEGIN IMMEDIATE;")
        do {
            for project in change.projects { try upsert(project) }
            if let settings = change.settings {
                try writeSetting(Self.guardrailKey, try encode(settings.guardrailRules))
                try writeSetting(Self.neutralsKey, try encode(settings.neutrals))
                try writeSetting(Self.exclusionsKey, try encode(settings.exclusions))
                try writeSetting(Self.vipsKey, try encode(settings.vips))
                try writeSetting(Self.noiseSendersKey, try encode(settings.noiseSenders))
                try writeSetting(Self.sheetsKey, try encode(settings.sheets))
            }
            for task in change.tasks {
                try execute("""
                    INSERT INTO tasks (id, json) VALUES (?, ?)
                    ON CONFLICT(id) DO UPDATE SET json = excluded.json;
                    """, task.id.rawValue.uuidString, try encode(task))
            }
            for suggestion in change.suggestions {
                try execute("""
                    INSERT INTO suggestions (thread_id, json) VALUES (?, ?)
                    ON CONFLICT(thread_id) DO UPDATE SET json = excluded.json;
                    """, suggestion.threadID, try encode(suggestion))
            }
            if let cursor = change.mailCursor { try writeSetting(Self.mailCursorKey, cursor) }
            if let cursor = change.notesCursor { try writeSetting(Self.notesCursorKey, String(cursor.timeIntervalSinceReferenceDate)) }
            if change.rereadNotes { try execute("DELETE FROM settings WHERE key = ?;", Self.notesCursorKey) }
            if let sightings = change.sightings { try writeSetting(Self.sightingsKey, try encode(sightings)) }
            if let dismissed = change.dismissedProposals { try writeSetting(Self.dismissedProposalsKey, try encode(dismissed)) }
            if let lastSeen = change.projectsLastSeen {
                // Keyed by the plain id, like the other dictionaries kept here.
                try writeSetting(Self.projectsLastSeenKey, try encode(Dictionary(
                    lastSeen.map { ($0.key.rawValue.uuidString, $0.value) }, uniquingKeysWith: max)))
            }
            if let recipients = change.recipients { try writeSetting(Self.recipientsKey, try encode(recipients)) }
            for line in change.digest {
                try execute("""
                    INSERT INTO digest (thread_id, json) VALUES (?, ?)
                    ON CONFLICT(thread_id) DO UPDATE SET json = excluded.json;
                    """, line.threadID, try encode(line))
            }
            for thread in change.droppedDigest { try execute("DELETE FROM digest WHERE thread_id = ?;", thread) }
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
    private func writeSetting(_ key: String, _ json: String) throws {
        try execute("""
            INSERT INTO settings (key, json) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET json = excluded.json;
            """, key, json)
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
