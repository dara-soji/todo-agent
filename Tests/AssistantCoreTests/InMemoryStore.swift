import AssistantCore

/// Persistence fake: keeps everything in memory so tests can check it survives a new Assistant,
/// and can be told to fail commits.
final class InMemoryStore: AssistantStore {
    struct WriteFailed: Error {}

    private var snapshot = StoreSnapshot()
    var failWrites = false

    func load() throws -> StoreSnapshot {
        snapshot
    }

    func write(_ change: Change, log entry: LogEntry) throws {
        if failWrites { throw WriteFailed() }
        snapshot.apply(change)
        snapshot.log.append(entry)
    }
}
