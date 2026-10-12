import AssistantCore

/// Persistence fake: keeps everything in memory so tests can check it survives a new Assistant,
/// and can be told to fail commits.
public final class InMemoryStore: AssistantStore {
    public struct WriteFailed: Error {}

    private var snapshot = StoreSnapshot()

    public init() {}
    public var failWrites = false

    public func load() throws -> StoreSnapshot {
        snapshot
    }

    public func write(_ change: Change, log entry: LogEntry) throws {
        if failWrites { throw WriteFailed() }
        snapshot.apply(change)
        snapshot.log.append(entry)
    }
}
