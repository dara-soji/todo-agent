import AssistantCore
import Foundation

/// Used only when the SQLite store can't be opened: everything works for this run but isn't kept.
final class VolatileStore: AssistantStore {
    private var snapshot = StoreSnapshot()

    func load() throws -> StoreSnapshot { snapshot }

    func audit(_ call: APICall) throws {
        snapshot.audit.append(call)
    }

    func apiSpend(since: Date) throws -> Double {
        snapshot.audit.filter { $0.at >= since }.reduce(0) { $0 + $1.costUSD }
    }

    func record(_ block: NowBlock) throws {
        snapshot.history.append(block)
    }

    func prune(_ cutoffs: Retention.Cutoffs, purging tasks: [AssistantCore.Task.ID]) throws {
        snapshot.prune(cutoffs, purging: tasks)
    }

    func write(_ change: Change, log entries: [LogEntry]) throws {
        snapshot.apply(change)
        snapshot.log += entries
    }
}
