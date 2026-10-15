import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

@Suite struct NeutralTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")
    let terminal = App(bundleID: "com.apple.Terminal", name: "Terminal")
    let slack = App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    let zoom = App(bundleID: "us.zoom.xos", name: "zoom.us")
    let safari = App(bundleID: "com.apple.Safari", name: "Safari")
    let notes = App(bundleID: "com.apple.Notes", name: "Notes")

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func onTodoAgent(_ assistant: Assistant) throws -> Project {
        let todo = try assistant.declareProject(name: "todo-agent", shortName: "todo", matchers: [.repoPath("~/code/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        return todo
    }

    func browse(_ assistant: Assistant, _ url: String) {
        assistant.receive(.activeWindow(app: safari, windowTitle: "Page", url: URL(string: url)))
    }

    // MARK: The hold

    @Test func aNeutralAppKeepsNowOnTheLastProject() throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)

        assistant.receive(.activeWindow(app: terminal, windowTitle: "dara — -zsh"))

        #expect(assistant.now.project == todo.id)
        #expect(assistant.now.match?.basis == .neutralHold(.app("com.apple.Terminal")))
        #expect(assistant.now.neutral == .app("com.apple.Terminal"))
        #expect(assistant.menuBar.title == "TODO")
        #expect(assistant.menuBar.evidence == "Kept while Terminal is Neutral")
    }

    @Test func theHoldEndsAfterFifteenMinutesOfNeutral() throws {
        let assistant = makeAssistant()
        _ = try onTodoAgent(assistant)
        assistant.receive(.activeWindow(app: slack, windowTitle: "general"))

        clock.advance(minutes: 14)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.now.project != nil)

        clock.advance(minutes: 1)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.now.project == nil)
        #expect(assistant.menuBar.title == "NO PROJECT")
    }

    @Test func movingBetweenNeutralWindowsDoesNotRestartTheHold() throws {
        let assistant = makeAssistant()
        _ = try onTodoAgent(assistant)
        assistant.receive(.activeWindow(app: slack, windowTitle: "general"))
        clock.advance(minutes: 10)
        assistant.receive(.activeWindow(app: terminal, windowTitle: "dara — -zsh"))
        clock.advance(minutes: 5)
        assistant.receive(.userIdle(seconds: 0))

        #expect(assistant.now.project == nil)
    }

    @Test func comingBackToTheProjectStartsAFreshHoldNextTime() throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        assistant.receive(.activeWindow(app: slack, windowTitle: "general"))
        clock.advance(minutes: 10)
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        assistant.receive(.activeWindow(app: slack, windowTitle: "general"))
        clock.advance(minutes: 10)
        assistant.receive(.userIdle(seconds: 0))

        #expect(assistant.now.project == todo.id)
    }

    @Test func neutralWithNoProjectBeforeIsNoProject() {
        let assistant = makeAssistant()
        assistant.receive(.activeWindow(app: slack, windowTitle: "general"))
        #expect(assistant.now.project == nil)
        #expect(assistant.now.neutral == .app("com.tinyspeck.slackmacgap"))
    }

    @Test func aMeetingBeatsTheHold() throws {
        let assistant = makeAssistant()
        _ = try onTodoAgent(assistant)
        let standup = try assistant.declareProject(name: "Standups", matchers: [.calendarKeyword("standup")])
        assistant.receive(.calendar(events: [
            CalendarEvent(title: "Team standup", start: clock.now - 60, end: clock.now + 900),
        ]))

        assistant.receive(.activeWindow(app: zoom, windowTitle: "Zoom Meeting"))

        #expect(assistant.now.project == standup.id)
    }

    @Test func aMatcherBeatsNeutral() throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        try assistant.declareProject(name: "Other", matchers: [.repoPath("~/code/other")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/other"))

        assistant.receive(.activeWindow(app: terminal, windowTitle: "dara — ~/code/todo-agent — -zsh"))

        #expect(assistant.now.project == todo.id)
        #expect(assistant.now.match?.basis == .matcher(.repoPath("~/code/todo-agent")))
        #expect(assistant.now.neutral == nil)
    }

    @Test func neutralSitesHoldButAMoreSpecificProjectPrefixStillMatches() throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        let dotnet = try assistant.declareProject(name: "Learning .NET", matchers: [.urlPrefix("learn.microsoft.com/*/training")])

        browse(assistant, "https://stackoverflow.com/questions/1")
        #expect(assistant.now.project == todo.id)
        #expect(assistant.now.neutral == .site("stackoverflow.com"))

        browse(assistant, "https://learn.microsoft.com/en-us/training/modules/x")
        #expect(assistant.now.project == dotnet.id)

        browse(assistant, "https://learn.microsoft.com/en-us/dotnet/api/system.string")
        #expect(assistant.now.project == dotnet.id)
        #expect(assistant.now.match?.basis == .neutralHold(.site("learn.microsoft.com")))
    }

    // MARK: Marking Neutral

    @Test func daraCanTreatAnAppAsNeutralAndItIsKept() throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        assistant.receive(.activeWindow(app: notes, windowTitle: "Ideas"))
        #expect(assistant.now.project == nil)
        #expect(assistant.neutralSuggestion == .app("com.apple.Notes"))

        try assistant.markNeutral(.app("com.apple.Notes"))

        #expect(assistant.now.project == todo.id)
        #expect(assistant.neutralSuggestion == nil)
        #expect(assistant.operationLog.last?.kind == .markNeutral)
        #expect(makeAssistant().neutrals == [.app("com.apple.Notes")])
    }

    @Test func theSuggestionIsTheSiteInABrowserAndNothingWhenAlreadyNeutral() {
        let assistant = makeAssistant()
        browse(assistant, "https://news.ycombinator.com/item?id=1")
        #expect(assistant.neutralSuggestion == .site("news.ycombinator.com"))

        browse(assistant, "https://stackoverflow.com/questions/1")
        #expect(assistant.neutralSuggestion == nil)
    }

    // MARK: Corrections

    @Test func notThisFixesNowAtOnceAndOffersAMatcherWithoutLearningIt() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [])
        browse(assistant, "https://github.com/dara-soji/todo-agent/pulls")

        try assistant.correctNow(.project(todo.id))

        #expect(assistant.now.project == todo.id)
        #expect(assistant.now.match?.basis == .correction)
        #expect(assistant.menuBar.evidence == "You said so")
        #expect(assistant.decisions == [.alwaysMatch(.urlPrefix("github.com/dara-soji/todo-agent"), todo.id)])
        #expect(assistant.project(todo.id)?.matchers == [])
        #expect(assistant.operationLog.count == 1)
    }

    @Test func alwaysAddsTheMatcherSoTheWindowMatchesNextTime() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [])
        browse(assistant, "https://github.com/dara-soji/todo-agent/pulls")
        try assistant.correctNow(.project(todo.id))

        try assistant.acceptOffer()

        #expect(assistant.decisions.isEmpty)
        #expect(assistant.project(todo.id)?.matchers == [.urlPrefix("github.com/dara-soji/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "elsewhere"))
        browse(assistant, "https://github.com/dara-soji/todo-agent/issues/9")
        #expect(assistant.now.match?.basis == .matcher(.urlPrefix("github.com/dara-soji/todo-agent")))
    }

    @Test func noAlwaysIsOfferedWhenTheProjectAlreadyHasThatMatcher() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.urlPrefix("github.com/dara-soji/todo-agent")])
        try assistant.declareProject(name: "Other", matchers: [.urlPrefix("github.com/dara-soji/todo-agent/pulls")])
        browse(assistant, "https://github.com/dara-soji/todo-agent/pulls")

        try assistant.correctNow(.project(todo.id))

        #expect(assistant.decisions.isEmpty)
    }

    @Test func aRepoInATerminalTitleIsOfferedAsARepoPath() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [])
        assistant.receive(.activeWindow(app: terminal, windowTitle: "dara — /Users/dara/code/todo-agent — -zsh"))

        try assistant.correctNow(.project(todo.id))

        #expect(assistant.decisions == [.alwaysMatch(.repoPath("~/code/todo-agent"), todo.id)])
    }

    @Test func correctingToNeutralHoldsAndOffersToKeepItNeutral() throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        browse(assistant, "https://news.ycombinator.com/item?id=1")
        #expect(assistant.now.project == nil)

        try assistant.correctNow(.neutral)

        #expect(assistant.now.project == todo.id)
        #expect(assistant.decisions == [.alwaysNeutral(.site("news.ycombinator.com"))])

        assistant.dismissOffer()
        #expect(assistant.decisions.isEmpty)
        #expect(assistant.neutrals.isEmpty)
    }

    @Test func correctingToNoneLeavesNoProjectAndOffersNothing() throws {
        let assistant = makeAssistant()
        _ = try onTodoAgent(assistant)

        try assistant.correctNow(.none)

        #expect(assistant.now.project == nil)
        #expect(assistant.decisions.isEmpty)
    }

    @Test func aCorrectionLastsOnlyForThatWindow() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [])
        browse(assistant, "https://example.com/a")
        try assistant.correctNow(.project(todo.id))

        assistant.receive(.activeWindow(app: notes, windowTitle: "Ideas"))
        browse(assistant, "https://example.com/a")

        #expect(assistant.now.project == nil)
    }

    @Test func aCorrectedProjectIsWhatALaterNeutralHolds() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [])
        browse(assistant, "https://example.com/a")
        try assistant.correctNow(.project(todo.id))

        assistant.receive(.activeWindow(app: slack, windowTitle: "general"))

        #expect(assistant.now.project == todo.id)
    }

    @Test func correctingToAnArchivedOrUnknownProjectFails() throws {
        let assistant = makeAssistant()
        let old = try assistant.declareProject(name: "Old", matchers: [])
        try assistant.archiveProject(old.id)
        browse(assistant, "https://example.com/a")

        #expect(throws: Assistant.Failure.unknownProject(old.id)) { try assistant.correctNow(.project(old.id)) }
        let missing = Project.ID()
        #expect(throws: Assistant.Failure.unknownProject(missing)) { try assistant.correctNow(.project(missing)) }
    }

    @Test func thereIsNothingToCorrectBeforeAnyWindow() {
        let assistant = makeAssistant()
        #expect(throws: Assistant.Failure.noWindow) { try assistant.correctNow(.none) }
    }
}
