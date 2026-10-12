import AssistantCore

/// Persistence fake: keeps everything in memory so tests can check it survives a new Assistant,
/// and can be told to fail commits.
final class InMemoryStore: AssistantStore {
    struct CommitFailed: Error {}

    private var snapshot = StoreSnapshot()
    var failCommits = false

    func load() throws -> StoreSnapshot {
        snapshot
    }

    func commit(_ change: Change, log entry: LogEntry) throws {
        if failCommits { throw CommitFailed() }
        snapshot.apply(change)
        snapshot.log.append(entry)
    }
}
