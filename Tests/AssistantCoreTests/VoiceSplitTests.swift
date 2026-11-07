import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

/// A scripted Haiku for voice quick-add: records what reached it and answers with chosen titles.
@MainActor
final class FakeSplitter: TranscriptSplitter {
    var seen: [SplitRequest] = []
    var titles: (String) -> [String] = { [$0] }
    var fails = false
    var refuses = false
    /// Never answers, as a call that hangs would.
    var hangs = false

    struct Refused: BilledFailure {
        let call: APICall
    }

    static let call = APICall(
        at: Date(timeIntervalSince1970: 0), purpose: .voiceSplit, model: "claude-haiku-5-5",
        inputTokens: 200, outputTokens: 20, contentKind: .transcript)

    func split(_ request: SplitRequest) async throws -> SplitAnswer {
        seen.append(request)
        if fails { throw URLError(.notConnectedToInternet) }
        if refuses { throw Refused(call: Self.call) }
        if hangs { try await _Concurrency.Task.sleep(for: .seconds(60)) }
        return SplitAnswer(titles: titles(request.transcript), call: Self.call)
    }
}

@MainActor
@Suite struct VoiceSplitTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let splitter = FakeSplitter()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func runner(_ assistant: Assistant, timeout: Duration = VoiceSplitRunner.timeout) -> VoiceSplitRunner {
        VoiceSplitRunner(assistant: assistant, splitter: splitter, timeout: timeout)
    }

    // MARK: Splitting

    @Test func oneRecordingBecomesSeveralTasksInNowsProject() async throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        splitter.titles = { _ in ["Email Sam about the deck", "Book the dentist"] }

        let tasks = try await runner(assistant).add("um I need to email Sam about the deck and uh book the dentist")

        #expect(tasks.map(\.title) == ["Email Sam about the deck", "Book the dentist"])
        #expect(tasks.allSatisfy { $0.project == todo.id && $0.source == .byHand && $0.status == .open })
        #expect(Set(assistant.tasks.map(\.id)) == Set(tasks.map(\.id)))
    }

    @Test func onlyTheTranscriptIsSent() async throws {
        let assistant = makeAssistant()
        _ = try assistant.declareProject(name: "Acme deck", matchers: [])
        _ = try await runner(assistant).add("  Email Sam  ")
        #expect(splitter.seen == [SplitRequest(transcript: "Email Sam")])
    }

    @Test func theBatchIsOneOperationThatKeepsTheTranscript() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in ["Email Sam", "Book the dentist"] }

        _ = try await runner(assistant).add("I need to email Sam and book the dentist")

        #expect(assistant.operationLog.count == 1)
        let entry = try #require(assistant.operationLog.last)
        #expect(entry.kind == .addTask)
        #expect(entry.startedBy == .dara)
        #expect(entry.summary == "Added 2 Tasks by voice “I need to email Sam and book the dentist”: “Email Sam”, “Book the dentist”")
    }

    @Test func oneUndoRemovesTheWholeBatch() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in ["Email Sam", "Book the dentist", "Water the plants"] }
        let tasks = try await runner(assistant).add("email Sam, book the dentist, water the plants")

        try assistant.undo(try #require(assistant.operationLog.last).id)

        #expect(assistant.tasks.isEmpty)
        #expect(Set(assistant.deletedTasks.map(\.id)) == Set(tasks.map(\.id)))
    }

    @Test func titlesAreTrimmedAndBlankOnesDropped() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in ["  Email Sam ", " ", ""] }
        let tasks = try await runner(assistant).add("um email Sam")
        #expect(tasks.map(\.title) == ["Email Sam"])
        #expect(assistant.operationLog.last?.summary == "Added 1 Task by voice “um email Sam”: “Email Sam”")
    }

    @Test func theCallIsMetered() async throws {
        let assistant = makeAssistant()
        _ = try await runner(assistant).add("Email Sam")
        #expect(try store.load().audit == [FakeSplitter.call])
    }

    // MARK: Fallback: one verbatim Task, as in #40

    func expectVerbatim(_ tasks: [AssistantCore.Task], _ assistant: Assistant, transcript: String) throws {
        #expect(tasks.map(\.title) == [transcript])
        #expect(assistant.tasks.map(\.title) == [transcript])
        #expect(assistant.operationLog.last?.summary == "Added by voice “\(transcript)”")
    }

    @Test func offlineOrAnyErrorAddsTheVerbatimTranscript() async throws {
        let assistant = makeAssistant()
        splitter.fails = true
        let tasks = try await runner(assistant).add("um email Sam")
        try expectVerbatim(tasks, assistant, transcript: "um email Sam")
        #expect(try store.load().audit.isEmpty)
    }

    @Test func aRefusalIsStillMeteredAndFallsBack() async throws {
        let assistant = makeAssistant()
        splitter.refuses = true
        let tasks = try await runner(assistant).add("um email Sam")
        try expectVerbatim(tasks, assistant, transcript: "um email Sam")
        #expect(try store.load().audit == [FakeSplitter.call])
    }

    @Test func anEmptyListFallsBack() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in [" ", ""] }
        let tasks = try await runner(assistant).add("um email Sam")
        try expectVerbatim(tasks, assistant, transcript: "um email Sam")
    }

    @Test func tooManyTitlesIsMalformedAndFallsBack() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in (1...(VoiceSplit.taskLimit + 1)).map { "Task \($0)" } }
        let tasks = try await runner(assistant).add("a long ramble")
        try expectVerbatim(tasks, assistant, transcript: "a long ramble")
    }

    @Test func aSlowAnswerTimesOutAndFallsBack() async throws {
        let assistant = makeAssistant()
        splitter.hangs = true
        let tasks = try await runner(assistant, timeout: .milliseconds(50)).add("um email Sam")
        try expectVerbatim(tasks, assistant, transcript: "um email Sam")
    }

    @Test func silenceAddsNothingAndSendsNothing() async {
        let assistant = makeAssistant()
        await #expect(throws: Assistant.Failure.emptyTitle) { try await runner(assistant).add(" \n ") }
        #expect(splitter.seen.isEmpty)
        #expect(assistant.operationLog.isEmpty)
    }

    // MARK: The fallback rule

    @Test func theRuleKeepsCleanTitlesInOrder() {
        #expect(VoiceSplit.tasks(from: [" B ", "A"]) == [SpokenTask(title: "B"), SpokenTask(title: "A")])
        #expect(VoiceSplit.tasks(from: []) == nil)
        #expect(VoiceSplit.tasks(from: ["\n"]) == nil)
    }
}
