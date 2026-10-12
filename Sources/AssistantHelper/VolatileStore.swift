import AssistantCore

/// Used only when the SQLite store can't be opened: everything works for this run but isn't kept.
final class VolatileStore: AssistantStore {
    private var snapshot = StoreSnapshot()

    func load() throws -> StoreSnapshot { snapshot }

    func write(_ change: Change, log entries: [LogEntry]) throws {
        snapshot.apply(change)
        snapshot.log += entries
    }
}
