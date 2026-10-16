import AssistantCore
import Foundation

/// Persistence fake: keeps everything in memory so tests can check it survives a new Assistant,
/// and can be told to fail commits.
public final class InMemoryStore: AssistantStore {
    public struct WriteFailed: Error {}

    private var snapshot = StoreSnapshot()

    public init(_ snapshot: StoreSnapshot = StoreSnapshot()) {
        self.snapshot = snapshot
    }
    public var failWrites = false

    public func load() throws -> StoreSnapshot {
        snapshot
    }

    public func audit(_ call: APICall) throws {
        if failWrites { throw WriteFailed() }
        snapshot.audit.append(call)
    }

    public func apiSpend(since: Date) throws -> Double {
        snapshot.audit.filter { $0.at >= since }.reduce(0) { $0 + $1.costUSD }
    }

    public func record(_ block: NowBlock) throws {
        if failWrites { throw WriteFailed() }
        snapshot.history.append(block)
    }

    public func prune(_ cutoffs: Retention.Cutoffs, purging tasks: [Task.ID]) throws {
        if failWrites { throw WriteFailed() }
        snapshot.prune(cutoffs, purging: tasks)
    }

    public func write(_ change: Change, log entries: [LogEntry]) throws {
        if failWrites { throw WriteFailed() }
        snapshot.apply(change)
        snapshot.log += entries
    }
}
