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
    let code = App(bundleID: "com.google.Chrome", name: "Chrome")
    let sheetID = "1AbC_dEf-123"

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func runner(_ assistant: Assistant) -> SheetsRunner {
        SheetsRunner(assistant: assistant, sheets: sheets)
    }

    func registered(_ assistant: Assistant, rows: [[String]]) throws {
        try assistant.registerSheet(sheetID, name: "Course plan")
        sheets.rowsBySheet[sheetID] = [["Task", "Due"]] + rows
    }

    // MARK: Registering

    @Test func onlyRegisteredSheetsAreRead() async throws {
        let assistant = makeAssistant()
        sheets.rowsBySheet["someone-elses"] = [["Header"], ["Secret row"]]
        try registered(assistant, rows: [["Read chapter 4"]])

        await runner(assistant).run()

        #expect(sheets.read == [sheetID])
        #expect(assistant.registeredSheets.map(\.id) == [sheetID])
        #expect(makeAssistant().registeredSheets.map(\.name) == ["Course plan"])
    }

    @Test func aSheetCanBeRegisteredByItsURL() throws {
        let assistant = makeAssistant()
        try assistant.registerSheet("https://docs.google.com/spreadsheets/d/\(sheetID)/edit#gid=0", name: "Plan")
        #expect(assistant.registeredSheets.map(\.id) == [sheetID])
        #expect(throws: Assistant.Failure.self) { try assistant.registerSheet(" ", name: "x") }
    }

    @Test func unregisteringStopsReadingIt() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4"]])
        try assistant.unregisterSheet(sheetID)

        await runner(assistant).run()

        #expect(sheets.read.isEmpty)
        #expect(assistant.operationLog.map(\.kind) == [.registerSheet, .unregisterSheet])
    }

    // MARK: Rows to Suggestions

    @Test func eachRowBelowTheHeaderBecomesASuggestion() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4", "Fri"], [], ["", "Write summary"]])

        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Read chapter 4", "Write summary"])
        let first = try #require(assistant.suggestions.first)
        #expect(first.source == .sheet)
        #expect(first.backLink == "https://docs.google.com/spreadsheets/d/\(sheetID)/edit#range=A2")
        #expect(first.reason == "New row in Course plan")
    }

    @Test func rowsAreDedupedBySheetAndRowAcrossPollsAndRestarts() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4"]])
        await runner(assistant).run()
        await runner(assistant).run()

        await runner(makeAssistant()).run()

        #expect(makeAssistant().suggestions.count == 1)
    }

    @Test func anEditedRowUpdatesItsOpenSuggestion() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4"]])
        await runner(assistant).run()
        let original = try #require(assistant.suggestions.first)

        sheets.rowsBySheet[sheetID]?[1] = ["Read chapters 4 and 5"]
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.id) == [original.id])
        #expect(assistant.suggestions.map(\.title) == ["Read chapters 4 and 5"])
    }

    @Test func anEditedRowUpdatesItsAcceptedTaskButNotATitleDaraSet() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4"], ["Write summary"]])
        await runner(assistant).run()
        for suggestion in assistant.suggestions { try assistant.acceptSuggestion(suggestion.id) }
        let renamed = try #require(assistant.tasks.first { $0.title == "Write summary" })
        try assistant.editTask(renamed.id, TaskChanges(title: "Summary for the course"))

        sheets.rowsBySheet[sheetID] = [["Task"], ["Read chapters 4 and 5"], ["Write a longer summary"]]
        await runner(assistant).run()

        #expect(Set(assistant.tasks.map(\.title)) == ["Read chapters 4 and 5", "Summary for the course"])
        #expect(assistant.suggestions.isEmpty)
        #expect(assistant.tasks.allSatisfy { $0.backLink?.hasPrefix("https://docs.google.com/spreadsheets/d/") == true })
    }

    @Test func aDismissedRowStaysQuietWhenEdited() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4"]])
        await runner(assistant).run()
        try assistant.dismissSuggestion(try #require(assistant.suggestions.first).id)

        sheets.rowsBySheet[sheetID]?[1] = ["Read chapter 4 again"]
        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func aNewRowInADoneTasksPlaceBecomesANewSuggestion() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4"]])
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)
        try assistant.completeTask(try #require(assistant.tasks.first).id)

        sheets.rowsBySheet[sheetID]?[1] = ["Read chapter 5"]
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Read chapter 5"])
    }

    @Test func aSheetUnregisteredWhileItIsReadMakesNoSuggestions() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4"]])
        sheets.whileReading = { id in try? assistant.unregisterSheet(id) }

        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func anUnchangedRowWhoseTaskIsDoneStaysDone() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4"]])
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)
        try assistant.completeTask(try #require(assistant.tasks.first).id)

        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func anAcceptHeldAsAnAskSurvivesAnEditToItsRow() async throws {
        let assistant = makeAssistant()
        try assistant.tighten(.acceptSuggestion)
        try registered(assistant, rows: [["Read chapter 4"]])
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)

        sheets.rowsBySheet[sheetID]?[1] = ["Read chapter 4, carefully"]
        await runner(assistant).run()

        try assistant.confirmAsk(try #require(assistant.asks.first).id)
        #expect(assistant.tasks.map(\.title) == ["Read chapter 4"])
    }

    @Test func oneFailingSheetDoesNotStopTheOthers() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4"]])
        try assistant.registerSheet("other-sheet", name: "Other")
        sheets.rowsBySheet["other-sheet"] = [["Task"], ["Pay rent"]]
        sheets.failing = [sheetID]

        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Pay rent"])
    }

    @Test func noSheetContentGoesToTheAPI() async throws {
        let assistant = makeAssistant()
        try registered(assistant, rows: [["Read chapter 4"]])
        await runner(assistant).run()
        #expect(try store.load().audit.isEmpty)
    }

    // MARK: Matcher

    @Test func aSheetIdMatchesThatSheetInTheBrowser() throws {
        let assistant = makeAssistant()
        let course = try assistant.declareProject(name: "Course", matchers: [.sheetID(sheetID)])
        _ = try assistant.declareProject(name: "Google", matchers: [.urlPrefix("docs.google.com/spreadsheets")])

        assistant.receive(.activeWindow(app: code, windowTitle: "Course plan - Google Sheets",
                                        url: URL(string: "https://docs.google.com/spreadsheets/d/\(sheetID)/edit#gid=0")))
        #expect(assistant.now.project == course.id)
        #expect(assistant.menuBar.evidence == "Matched by sheet \(sheetID)")

        assistant.receive(.activeWindow(app: code, windowTitle: "Other - Google Sheets",
                                        url: URL(string: "https://docs.google.com/spreadsheets/d/zzz/edit")))
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
