import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

/// A scripted Haiku for voice quick-add: records what reached it and answers with chosen titles.
@MainActor
final class FakeSplitter: TranscriptSplitter {
    var seen: [SplitRequest] = []
    var titles: (String) -> [String] = { [$0] }
    /// The Project label answered, if any.
    var project: String?
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
        return SplitAnswer(titles: titles(request.transcript), project: project, call: Self.call)
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

    func onTodoAgent(_ assistant: Assistant) throws -> Project {
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        return todo
    }

    // MARK: Splitting

    @Test func oneRecordingBecomesSeveralTasksInTheCapturedProject() async throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        splitter.titles = { _ in ["Email Sam about the deck", "Book the dentist"] }

        let tasks = try await runner(assistant).add("um I need to email Sam about the deck and uh book the dentist", otherwise: todo.id).tasks

        #expect(tasks.map(\.title) == ["Email Sam about the deck", "Book the dentist"])
        #expect(tasks.allSatisfy { $0.project == todo.id && $0.source == .byHand && $0.status == .open })
        #expect(Set(assistant.tasks.map(\.id)) == Set(tasks.map(\.id)))
    }

    @Test func onlyTheTranscriptAndActiveProjectNamesAreSent() async throws {
        let assistant = makeAssistant()
        _ = try assistant.declareProject(name: "Acme deck", matchers: [.repoPath("~/code/acme")])
        _ = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])
        _ = try assistant.declareProject(name: "Acme deck", matchers: [])
        let old = try assistant.declareProject(name: "Old client", matchers: [])
        try assistant.archiveProject(old.id)
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent — secret.swift"))

        _ = try await runner(assistant).add("  Email Sam  ", otherwise: nil)

        // Each name once, archived ones left out; no window, matcher or Task.
        #expect(splitter.seen == [SplitRequest(transcript: "Email Sam", projects: ["Acme deck", "todo-agent"])])
    }

    @Test func theBatchIsOneOperationThatKeepsTheTranscript() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in ["Email Sam", "Book the dentist"] }

        _ = try await runner(assistant).add("I need to email Sam and book the dentist", otherwise: nil)

        #expect(assistant.operationLog.count == 1)
        let entry = try #require(assistant.operationLog.last)
        #expect(entry.kind == .addTask)
        #expect(entry.startedBy == .dara)
        #expect(entry.summary == "Added 2 Tasks by voice “I need to email Sam and book the dentist”: “Email Sam”, “Book the dentist”")
    }

    @Test func oneUndoRemovesTheWholeBatch() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in ["Email Sam", "Book the dentist", "Water the plants"] }
        let tasks = try await runner(assistant).add("email Sam, book the dentist, water the plants", otherwise: nil).tasks

        try assistant.undo(try #require(assistant.operationLog.last).id)

        #expect(assistant.tasks.isEmpty)
        #expect(Set(assistant.deletedTasks.map(\.id)) == Set(tasks.map(\.id)))
    }

    @Test func titlesAreTrimmedAndBlankOnesDropped() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in ["  Email Sam ", " ", ""] }
        let tasks = try await runner(assistant).add("um email Sam", otherwise: nil).tasks
        #expect(tasks.map(\.title) == ["Email Sam"])
        #expect(assistant.operationLog.last?.summary == "Added 1 Task by voice “um email Sam”: “Email Sam”")
    }

    @Test func theCallIsMetered() async throws {
        let assistant = makeAssistant()
        _ = try await runner(assistant).add("Email Sam", otherwise: nil)
        #expect(try store.load().audit == [FakeSplitter.call])
    }

    // MARK: Naming a Project out loud

    @Test func aNamedProjectGetsTheTasks() async throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        let acme = try assistant.declareProject(name: "Acme deck", matchers: [])
        splitter.titles = { _ in ["Email Sam", "Fix the chart"] }
        splitter.project = "Acme deck"

        let tasks = try await runner(assistant).add("for the Acme deck, email Sam and fix the chart", otherwise: todo.id).tasks

        #expect(tasks.map(\.title) == ["Email Sam", "Fix the chart"])
        #expect(tasks.allSatisfy { $0.project == acme.id })
        #expect(assistant.operationLog.filter { $0.kind == .addTask }.count == 1)
    }

    @Test func theNamedProjectIsMatchedIgnoringCaseAndSpace() async throws {
        let assistant = makeAssistant()
        let acme = try assistant.declareProject(name: "Acme deck", matchers: [])
        splitter.project = " acme DECK "
        let tasks = try await runner(assistant).add("for the Acme deck, email Sam", otherwise: nil).tasks
        #expect(tasks.map(\.project) == [acme.id])
    }

    @Test func aNameThatMatchesNoProjectGoesToTheCapturedProject() async throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        let old = try assistant.declareProject(name: "Old client", matchers: [])
        try assistant.archiveProject(old.id)

        for label in ["Globex", "Old client", ""] {
            splitter.project = label
            let tasks = try await runner(assistant).add("for \(label), email Sam", otherwise: todo.id).tasks
            #expect(tasks.map(\.project) == [todo.id], "\(label)")
        }
    }

    @Test func noProjectNamedGoesToTheCapturedProject() async throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        _ = try assistant.declareProject(name: "Acme deck", matchers: [])
        splitter.project = nil
        let tasks = try await runner(assistant).add("email Sam", otherwise: todo.id).tasks
        #expect(tasks.map(\.project) == [todo.id])
    }

    @Test func noProjectNamedAndNoneCapturedIsNoProject() async throws {
        let assistant = makeAssistant()
        _ = try onTodoAgent(assistant)
        let tasks = try await runner(assistant).add("email Sam", otherwise: nil).tasks
        #expect(tasks.map(\.project) == [nil])
    }

    /// The palette's Project when recording started wins over where Now has moved since.
    @Test func theCapturedProjectWinsOverNowAtRelease() async throws {
        let assistant = makeAssistant()
        let acme = try assistant.declareProject(name: "Acme deck", matchers: [.repoPath("~/code/acme")])
        let todo = try onTodoAgent(assistant)
        let captured = assistant.now.confidentProject
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/acme"))
        #expect(assistant.now.confidentProject == acme.id)

        let tasks = try await runner(assistant).add("email Sam", otherwise: captured).tasks

        #expect(tasks.map(\.project) == [todo.id])
    }

    @Test func anAmbiguousNameGoesToTheCapturedProject() async throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        _ = try assistant.declareProject(name: "Acme", matchers: [])
        _ = try assistant.declareProject(name: "acme", matchers: [])
        splitter.project = "Acme"
        let tasks = try await runner(assistant).add("for Acme, email Sam", otherwise: todo.id).tasks
        #expect(tasks.map(\.project) == [todo.id])
    }

    @Test func theFallbackGoesToTheCapturedProject() async throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        assistant.receive(.activeWindow(app: App(bundleID: "com.apple.finder", name: "Finder"), windowTitle: "Downloads"))
        splitter.fails = true
        let tasks = try await runner(assistant).add("for the Acme deck, email Sam", otherwise: todo.id).tasks
        try expectVerbatim(tasks, assistant, transcript: "for the Acme deck, email Sam")
        #expect(tasks.map(\.project) == [todo.id])
    }

    @Test func aCapturedProjectArchivedSinceIsNoProject() async throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        try assistant.archiveProject(todo.id)
        let tasks = try await runner(assistant).add("email Sam", otherwise: todo.id).tasks
        #expect(tasks.map(\.project) == [nil])
    }

    // MARK: Fallback: one verbatim Task, as in #40

    /// The fallback Task: the transcript with standalone filler and repeated words taken out.
    func expectVerbatim(_ tasks: [AssistantCore.Task], _ assistant: Assistant, transcript: String, title: String? = nil) throws {
        let title = title ?? transcript
        #expect(tasks.map(\.title) == [title])
        #expect(assistant.tasks.map(\.title) == [title])
        #expect(assistant.operationLog.last?.summary == "Added by voice “\(transcript)”")
    }

    @Test func offlineOrAnyErrorAddsTheVerbatimTranscript() async throws {
        let assistant = makeAssistant()
        splitter.fails = true
        let tasks = try await runner(assistant).add("um email Sam", otherwise: nil).tasks
        try expectVerbatim(tasks, assistant, transcript: "um email Sam", title: "email Sam")
        #expect(try store.load().audit.isEmpty)
    }

    @Test func aRefusalIsStillMeteredAndFallsBack() async throws {
        let assistant = makeAssistant()
        splitter.refuses = true
        let tasks = try await runner(assistant).add("um email Sam", otherwise: nil).tasks
        try expectVerbatim(tasks, assistant, transcript: "um email Sam", title: "email Sam")
        #expect(try store.load().audit == [FakeSplitter.call])
    }

    @Test func onlyBlankTitlesFallBack() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in [" ", ""] }
        let tasks = try await runner(assistant).add("um email Sam", otherwise: nil).tasks
        try expectVerbatim(tasks, assistant, transcript: "um email Sam", title: "email Sam")
    }

    @Test func tooManyTitlesIsMalformedAndFallsBack() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in (1...(VoiceSplit.taskLimit + 1)).map { "Task \($0)" } }
        let tasks = try await runner(assistant).add("a long ramble", otherwise: nil).tasks
        try expectVerbatim(tasks, assistant, transcript: "a long ramble")
    }

    @Test func undoTargetsTheEntryTheVoiceAddWroteNotTheLatestOne() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in ["Email Sam", "Book the dentist"] }
        let added = try await runner(assistant).add("email Sam and book the dentist", otherwise: nil)
        // Something else lands in the log before Undo is clicked.
        let typed = try assistant.quickAdd("Typed meanwhile")

        let entry = try #require(added.undoEntry)
        #expect(assistant.operationLog.last?.id != entry)
        try assistant.undo(entry)

        #expect(assistant.tasks.map(\.id) == [typed.id])
        #expect(Set(assistant.deletedTasks.map(\.id)) == Set(added.tasks.map(\.id)))
    }

    @Test func aVoiceAddHeldByTheGuardrailHasNothingToUndo() throws {
        let assistant = makeAssistant()
        try assistant.tighten(.addTask)

        let added = try assistant.addSpoken("Email Sam", otherwise: nil)

        #expect(added.undoEntry == nil)
    }

    @Test func aSlowAnswerTimesOutAndFallsBack() async throws {
        let assistant = makeAssistant()
        splitter.hangs = true
        let tasks = try await runner(assistant, timeout: .milliseconds(50)).add("um email Sam", otherwise: nil).tasks
        try expectVerbatim(tasks, assistant, transcript: "um email Sam", title: "email Sam")
    }

    @Test func silenceAddsNothingAndSendsNothing() async {
        let assistant = makeAssistant()
        await #expect(throws: Assistant.Failure.emptyTitle) { try await runner(assistant).add(" \n ", otherwise: nil) }
        #expect(splitter.seen.isEmpty)
        #expect(assistant.operationLog.isEmpty)
    }

    // MARK: Corrections said out loud

    @Test func retractingEveryTaskAddsNothingButIsMetered() async throws {
        let assistant = makeAssistant()
        splitter.titles = { _ in [] }
        await #expect(throws: Assistant.Failure.emptyTitle) {
            try await runner(assistant).add("buy milk, actually scratch that", otherwise: nil)
        }
        #expect(assistant.tasks.isEmpty)
        #expect(assistant.operationLog.isEmpty)
        #expect(try store.load().audit == [FakeSplitter.call])
    }

    // MARK: Filler left out of the fallback

    @Test func theFallbackDropsStandaloneFillerAndRepeats() {
        #expect(VoiceSplit.withoutFiller("Um, email Sam uh about the the deck") == "email Sam about the deck")
        #expect(VoiceSplit.withoutFiller("UMM call er Jo. Hmm") == "call Jo.")
        #expect(VoiceSplit.withoutFiller("book the dentist") == "book the dentist")
        // Words that merely contain filler stay.
        #expect(VoiceSplit.withoutFiller("summer umbrella hummus") == "summer umbrella hummus")
        #expect(VoiceSplit.withoutFiller("um uh") == "")
    }

    @Test func aFallbackOfOnlyFillerAddsNothing() async {
        let assistant = makeAssistant()
        splitter.fails = true
        await #expect(throws: Assistant.Failure.emptyTitle) { try await runner(assistant).add("um uh", otherwise: nil) }
        #expect(assistant.operationLog.isEmpty)
    }

    @Test func typedTasksAreNeverFiltered() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("um the the plan")
        #expect(task.title == "um the the plan")
    }

    // MARK: The fallback rule

    @Test func theRuleKeepsCleanTitlesInOrder() {
        #expect(VoiceSplit.tasks(from: [" B ", "A"]) == [SpokenTask(title: "B"), SpokenTask(title: "A")])
        #expect(VoiceSplit.tasks(from: []) == nil)
        #expect(VoiceSplit.tasks(from: ["\n"]) == nil)
    }
}
