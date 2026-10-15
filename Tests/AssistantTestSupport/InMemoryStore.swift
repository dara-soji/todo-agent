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

    public func record(_ block: NowBlock) throws {
        if failWrites { throw WriteFailed() }
        snapshot.history.append(block)
    }

    public func write(_ change: Change, log entries: [LogEntry]) throws {
        if failWrites { throw WriteFailed() }
        snapshot.apply(change)
        snapshot.log += entries
    }
}
