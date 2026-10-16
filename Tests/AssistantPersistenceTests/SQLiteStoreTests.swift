import AssistantCore
import AssistantPersistence
import Foundation
import Testing

/// The SQLite store against a real file. A new store over the same file is a restart.
@Suite(.serialized) struct SQLiteStoreTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).sqlite")

    final class Clock: WallClock {
        var now = Date(timeIntervalSince1970: 1_791_000_000)
    }

    /// A store, used by `body`, then closed so the next one can open the file.
    func withStore<T>(_ body: (SQLiteStore) throws -> T) throws -> T {
        let store = try SQLiteStore(url: url)
        return try body(store)
    }

    @Test func everythingSurvivesARestart() throws {
        let clock = Clock()
        try withStore { store in
            let assistant = try Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
            try assistant.declareProject(name: "Course", matchers: [.sheetID("1AbC_dEf-123456789xyzABCDEFghijkl"), .repoPath("~/code/c")])
            try assistant.quickAdd("Read chapter 4")
            try assistant.exclude(.sender("@bank.example"))
            try assistant.addVIP("boss@work.example")
            try assistant.registerSheet("1AbC_dEf-123456789xyzABCDEFghijkl", name: "Plan")
            assistant.finishSetup()
        }
        try withStore { store in
            let assistant = try Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
            #expect(assistant.projects.map(\.matchers) == [[.sheetID("1AbC_dEf-123456789xyzABCDEFghijkl"), .repoPath("~/code/c")]])
            #expect(assistant.tasks.map(\.title) == ["Read chapter 4"])
            #expect(assistant.exclusions == [.sender("@bank.example")])
            #expect(assistant.vips == ["boss@work.example"])
            #expect(assistant.registeredSheets.map(\.name) == ["Plan"])
            #expect(!assistant.needsSetup)
            #expect(assistant.operationLog.count == 5)
        }
    }

    @Test func pruneDeletesOnlyWhatIsPastEachCutoff() throws {
        let clock = Clock()
        let start = clock.now
        try withStore { store in
            let assistant = try Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
            let project = try assistant.declareProject(name: "P", matchers: [])
            let old = try assistant.quickAdd("Old")
            try assistant.deleteTask(old.id)
            assistant.recordAPICall(APICall(at: start, purpose: .triage, model: "claude-haiku-5-5", inputTokens: 1,
                                            outputTokens: 1, contentKind: .emailExcerpt))
            try store.record(NowBlock(project: project.id, committedTask: nil, start: start, end: start + 60))
            clock.now = start + 40 * 86_400
            try assistant.quickAdd("Recent")
            assistant.pruneLogs()

            #expect(try store.load().tasks.map(\.title) == ["Recent"])
            #expect(try store.apiSpend(since: .distantPast) == 0)
            #expect(try store.history(since: .distantPast).count == 1)  // Kept 90 days.
            #expect(try store.load().log.count == 4)  // Kept 90 days, with the purged Task taken out.
            #expect(!String(describing: try store.load().log).contains("Old"))
        }
    }

    @Test func aSecondStoreOnTheSameFileIsRefused() throws {
        let first = try SQLiteStore(url: url)
        #expect(throws: (any Error).self) { try SQLiteStore(url: url) }
        _ = first
    }
}
