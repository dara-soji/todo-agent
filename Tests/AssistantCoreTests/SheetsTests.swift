import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

/// A fake Google Sheets: rows by sheet id, and which sheets were read.
@MainActor
final class FakeSheets: SheetsSource {
    var rowsBySheet: [String: [[String]]] = [:]
    var read: [String] = []
    var failing: Set<String> = []
    var whileReading: (String) -> Void = { _ in }

    func rows(of sheetID: String) async throws -> [SheetRow] {
        read.append(sheetID)
        whileReading(sheetID)
        if failing.contains(sheetID) { throw URLError(.timedOut) }
        return (rowsBySheet[sheetID] ?? []).enumerated().map { SheetRow(number: $0.offset + 1, cells: $0.element) }
    }
}

@MainActor
@Suite struct SheetsTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let sheets = FakeSheets()
    let chrome = App(bundleID: "com.google.Chrome", name: "Chrome")
    let sheetID = "1AbC_dEf-123456789xyzABCDEFghijkl"
    let otherID = "9ZyX_wVu-987654321abcZYXWVUtsrqpo"

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func runner(_ assistant: Assistant) -> SheetsRunner {
        SheetsRunner(assistant: assistant, sheets: sheets)
    }

    /// A registered sheet, read once with these rows below its header: nothing offered yet.
    func baselined(_ assistant: Assistant, rows: [[String]] = []) async throws {
        try assistant.registerSheet(sheetID, name: "Course plan")
        sheets.rowsBySheet[sheetID] = [["Task", "Due"]] + rows
        await runner(assistant).run()
    }

    func setRows(_ rows: [[String]]) {
        sheets.rowsBySheet[sheetID] = [["Task", "Due"]] + rows
    }

    // MARK: Registering

    @Test func onlyRegisteredSheetsAreRead() async throws {
        let assistant = makeAssistant()
        sheets.rowsBySheet[otherID] = [["Header"], ["Secret row"]]
        try await baselined(assistant, rows: [["Read chapter 4"]])

        #expect(sheets.read == [sheetID])
        #expect(assistant.registeredSheets.map(\.id) == [sheetID])
        #expect(makeAssistant().registeredSheets.map(\.name) == ["Course plan"])
    }

    @Test(arguments: [
        "https://docs.google.com/spreadsheets/d/1AbC_dEf-123456789xyzABCDEFghijkl/edit#gid=0",
        "https://docs.google.com/spreadsheets/u/1/d/1AbC_dEf-123456789xyzABCDEFghijkl/edit",
        "1AbC_dEf-123456789xyzABCDEFghijkl",
    ])
    func aSheetCanBeRegisteredByItsURLOrId(_ text: String) throws {
        let assistant = makeAssistant()
        try assistant.registerSheet(text, name: "")
        #expect(assistant.registeredSheets == [RegisteredSheet(id: sheetID, name: sheetID)])
        #expect(throws: Assistant.Failure.alreadyRegisteredSheet(sheetID)) { try assistant.registerSheet(sheetID, name: "x") }
    }

    @Test(arguments: [" ", "foo", "https://docs.google.com/spreadsheets/d/e/2PACX-1vQabcdefghijklmnopqrstuvwxyz/pubhtml"])
    func whatIsntASheetIsRefused(_ text: String) {
        let assistant = makeAssistant()
        #expect(throws: Assistant.Failure.malformedSheet(text)) { try assistant.registerSheet(text, name: "x") }
    }

    @Test func unregisteringStopsReadingItAndItsOpenSuggestionsGo() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        await runner(assistant).run()
        #expect(assistant.suggestions.count == 1)
        sheets.read = []

        try assistant.unregisterSheet(sheetID)
        await runner(assistant).run()

        #expect(sheets.read.isEmpty)
        #expect(assistant.suggestions.isEmpty)
        #expect(assistant.operationLog.map(\.kind) == [.registerSheet, .unregisterSheet])
        #expect(throws: Assistant.Failure.unknownSheet(sheetID)) { try assistant.unregisterSheet(sheetID) }
    }

    // MARK: Rows to Suggestions

    @Test func theFirstReadOffersNothingOnlyNewRowsAfterIt() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant, rows: [["Old task, maybe done"], ["Another old one"]])
        #expect(assistant.suggestions.isEmpty)

        setRows([["Old task, maybe done"], ["Another old one"], ["Read chapter 4", "Fri"], [], ["", "Write summary"]])
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Read chapter 4", "Write summary"])
        let first = try #require(assistant.suggestions.first)
        #expect(first.source == .sheet)
        #expect(first.backLink == "https://docs.google.com/spreadsheets/d/\(sheetID)/edit#range=A4")
        #expect(first.reason == "New row in Course plan")
    }

    @Test func anEmptySheetsFirstRowsAfterRegisteringAreOffered() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        await runner(assistant).run()
        #expect(assistant.suggestions.map(\.title) == ["Read chapter 4"])
    }

    @Test func anEditedOldRowIsOffered() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant, rows: [["Read chapter 4"]])

        setRows([["Read chapter 4 and 5"]])
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Read chapter 4 and 5"])
    }

    @Test func rowsAreDedupedAcrossPollsAndRestarts() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        await runner(assistant).run()
        await runner(assistant).run()

        await runner(makeAssistant()).run()

        #expect(makeAssistant().suggestions.count == 1)
    }

    @Test func anEditedRowUpdatesItsOpenSuggestion() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        await runner(assistant).run()
        let original = try #require(assistant.suggestions.first)

        setRows([["Read chapters 4 and 5"]])
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.id) == [original.id])
        #expect(assistant.suggestions.map(\.title) == ["Read chapters 4 and 5"])
    }

    @Test func insertingARowAboveMovesTheOthersWithoutRetitlingThem() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"], ["Write summary"]])
        await runner(assistant).run()
        let summary = try #require(assistant.suggestions.first { $0.title == "Write summary" })
        try assistant.acceptSuggestion(summary.id)
        let task = try #require(assistant.tasks.first)

        setRows([["Pay the course fee"], ["Read chapter 4"], ["Write summary"]])
        await runner(assistant).run()

        #expect(Set(assistant.suggestions.map(\.title)) == ["Pay the course fee", "Read chapter 4"])
        #expect(assistant.task(task.id)?.title == "Write summary")
        #expect(assistant.task(task.id)?.backLink == "https://docs.google.com/spreadsheets/d/\(sheetID)/edit#range=A4")
    }

    @Test func aMoveWhileTheTaskIsHeldIsPickedUpAfterwards() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Write summary"]])
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)
        let task = try #require(assistant.tasks.first)
        try assistant.tighten(.editTask)
        _ = try assistant.editTask(task.id, TaskChanges(effort: .some(.small)))

        setRows([["Pay the course fee"], ["Write summary"]])
        await runner(assistant).run()
        try assistant.confirmAsk(try #require(assistant.asks.first).id)  // Dara's held edit still runs.
        await runner(assistant).run()

        #expect(assistant.task(task.id)?.effort == .small)
        #expect(assistant.task(task.id)?.backLink == "https://docs.google.com/spreadsheets/d/\(sheetID)/edit#range=A3")
    }

    @Test func sortingTheSheetChangesNothing() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["B task"], ["A task"]])
        await runner(assistant).run()
        let before = Set(assistant.suggestions.map(\.title))

        setRows([["A task"], ["B task"]])
        await runner(assistant).run()

        #expect(Set(assistant.suggestions.map(\.title)) == before)
        #expect(assistant.suggestions.count == 2)
    }

    @Test func aDeletedRowsOpenSuggestionGoes() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"], ["Write summary"]])
        await runner(assistant).run()

        setRows([["Write summary"]])
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Write summary"])
    }

    @Test func anEditedRowUpdatesItsAcceptedTaskButNotATitleDaraSet() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"], ["Write summary"]])
        await runner(assistant).run()
        for suggestion in assistant.suggestions { try assistant.acceptSuggestion(suggestion.id) }
        let renamed = try #require(assistant.tasks.first { $0.title == "Write summary" })
        try assistant.editTask(renamed.id, TaskChanges(title: "Summary for the course"))

        setRows([["Read chapters 4 and 5"], ["Write a longer summary"]])
        await runner(assistant).run()

        #expect(Set(assistant.tasks.map(\.title)) == ["Read chapters 4 and 5", "Summary for the course"])
        #expect(assistant.suggestions.isEmpty)
    }

    @Test func anEditWaitingOnAHeldTaskUpdateIsRetriedNotLost() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)
        let task = try #require(assistant.tasks.first)
        try assistant.tighten(.editTask)  // Holds an edit of Dara's on the Task.
        _ = try assistant.editTask(task.id, TaskChanges(effort: .some(.small)))

        setRows([["Read chapters 4 and 5"]])
        await runner(assistant).run()
        #expect(assistant.task(task.id)?.title == "Read chapter 4")

        try assistant.declineAsk(try #require(assistant.asks.first).id)
        await runner(assistant).run()
        #expect(assistant.task(task.id)?.title == "Read chapters 4 and 5")
    }

    @Test func aDismissedRowStaysQuietWhenEdited() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        await runner(assistant).run()
        try assistant.dismissSuggestion(try #require(assistant.suggestions.first).id)

        setRows([["Read chapter 4 again"]])
        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func anEditToADoneTasksRowBecomesANewSuggestionAndTheTaskKeepsItsLink() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)
        let task = try #require(assistant.tasks.first)
        try assistant.completeTask(task.id)

        setRows([["Read chapter 5"]])
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Read chapter 5"])
        try assistant.undo(try #require(assistant.operationLog.last { $0.kind == .completeTask }).id)
        #expect(assistant.task(task.id)?.status == .open)
    }

    @Test func anUnchangedRowWhoseTaskIsDoneStaysDone() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)
        try assistant.completeTask(try #require(assistant.tasks.first).id)

        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func anExpiredRowIsOfferedAgainWhenEdited() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        await runner(assistant).run()
        clock.advance(minutes: 7 * 24 * 60)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.suggestions.isEmpty)

        setRows([["Read chapter 4, properly"]])
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Read chapter 4, properly"])
    }

    @Test func anAcceptHeldAsAnAskSurvivesAnEditToItsRow() async throws {
        let assistant = makeAssistant()
        try assistant.tighten(.acceptSuggestion)
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)

        setRows([["Read chapter 4, carefully"]])
        await runner(assistant).run()

        try assistant.confirmAsk(try #require(assistant.asks.first).id)
        #expect(assistant.tasks.map(\.title) == ["Read chapter 4"])
    }

    @Test func aSheetUnregisteredWhileItIsReadMakesNoSuggestions() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows([["Read chapter 4"]])
        sheets.whileReading = { id in try? assistant.unregisterSheet(id) }

        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func oneFailingSheetDoesNotStopTheOthers() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        try assistant.registerSheet(otherID, name: "Other")
        sheets.rowsBySheet[otherID] = [["Task"]]
        await runner(assistant).run()
        setRows([["Read chapter 4"]])
        sheets.rowsBySheet[otherID] = [["Task"], ["Pay rent"]]
        sheets.failing = [sheetID]

        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Pay rent"])
    }

    @Test func rowTwoComesBeforeRowTen() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant)
        setRows((2...11).map { ["Row \($0)"] })
        await runner(assistant).run()
        #expect(assistant.suggestions.first?.title == "Row 2")
    }

    @Test func noSheetContentGoesToTheAPI() async throws {
        let assistant = makeAssistant()
        try await baselined(assistant, rows: [["Read chapter 4"]])
        #expect(try store.load().audit.isEmpty)
    }

    // MARK: Matcher

    @Test func aSheetIdMatchesThatSheetInTheBrowser() throws {
        let assistant = makeAssistant()
        let course = try assistant.declareProject(name: "Course", matchers: [.sheetID(sheetID)])
        _ = try assistant.declareProject(name: "Google", matchers: [.urlPrefix("docs.google.com/spreadsheets")])
        try assistant.registerSheet(sheetID, name: "Course plan")

        assistant.receive(.activeWindow(app: chrome, windowTitle: "Course plan - Google Sheets",
                                        url: URL(string: "https://docs.google.com/spreadsheets/u/1/d/\(sheetID)/edit#gid=0")))
        #expect(assistant.now.project == course.id)
        #expect(assistant.menuBar.evidence == "Matched by the sheet “Course plan”")

        assistant.receive(.activeWindow(app: chrome, windowTitle: "Other - Google Sheets",
                                        url: URL(string: "https://docs.google.com/spreadsheets/d/\(otherID)/edit")))
        #expect(assistant.now.project != course.id)
    }

    @Test func aSheetIdMatcherIsKeptAndCanBeWrittenAsAURL() throws {
        let assistant = makeAssistant()
        let course = try assistant.declareProject(
            name: "Course", matchers: [.sheetID("https://docs.google.com/spreadsheets/d/\(sheetID)/edit")])
        #expect(course.matchers == [.sheetID(sheetID)])
        #expect(makeAssistant().project(course.id)?.matchers == [.sheetID(sheetID)])
        #expect(throws: Matcher.Invalid.self) { try assistant.declareProject(name: "Bad", matchers: [.sheetID("a/b")]) }
    }
}
