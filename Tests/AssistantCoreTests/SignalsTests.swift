import Foundation
import Testing
import AssistantCore

@Suite struct CalendarTests {
    let clock = FakeClock()
    let zoom = App(bundleID: "us.zoom.xos", name: "zoom.us")
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, projects: InMemoryProjectStore(), homeDirectory: "/Users/dara")
    }

    func event(_ title: String, startsIn start: Double = -5, lasts minutes: Double = 30) -> CalendarEvent {
        let begins = clock.now + start * 60
        return CalendarEvent(title: title, start: begins, end: begins + minutes * 60)
    }

    @Test func aMeetingWithAKeywordSetsNowWhenTheForegroundMatchesNothing() throws {
        let assistant = makeAssistant()
        let dotnet = try assistant.declareProject(name: "Learning .NET", matchers: [.calendarKeyword("dotnet")])

        assistant.receive(.calendar(events: [event("Dotnet study group")]))
        assistant.receive(.activeWindow(app: zoom, windowTitle: "Zoom Meeting"))

        #expect(assistant.now.project == dotnet.id)
        #expect(assistant.now.evidence == .calendarKeyword("dotnet"))
        #expect(assistant.menuBar.evidence == "Matched by “dotnet” in Dotnet study group")
    }

    @Test func aMatchedForegroundWindowBeatsTheCalendar() throws {
        let assistant = makeAssistant()
        try assistant.declareProject(name: "Learning .NET", matchers: [.calendarKeyword("dotnet")])
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])

        assistant.receive(.calendar(events: [event("Dotnet study group")]))
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))

        #expect(assistant.now.project == todo.id)
    }

    @Test func keywordsMatchWholeWordsIgnoringCase() throws {
        let assistant = makeAssistant()
        try assistant.declareProject(name: "Standups", matchers: [.calendarKeyword("Standup")])

        assistant.receive(.activeWindow(app: zoom, windowTitle: "Zoom Meeting"))
        assistant.receive(.calendar(events: [event("Standupish retro")]))
        #expect(assistant.now.project == nil)

        assistant.receive(.calendar(events: [event("Team STANDUP (daily)")]))
        #expect(assistant.now.project != nil)
    }

    @Test func onlyEventsUnderWayCount() throws {
        let assistant = makeAssistant()
        let dotnet = try assistant.declareProject(name: "Learning .NET", matchers: [.calendarKeyword("dotnet")])
        assistant.receive(.activeWindow(app: zoom, windowTitle: "Zoom Meeting"))

        assistant.receive(.calendar(events: [event("Dotnet study group", startsIn: 10, lasts: 30)]))
        #expect(assistant.now.project == nil)

        clock.advance(minutes: 10)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.now.project == dotnet.id)

        clock.advance(minutes: 30)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.now.project == nil)
    }

    @Test func sittingStillInAMatchingMeetingIsTheMeetingNotAway() throws {
        let assistant = makeAssistant()
        let dotnet = try assistant.declareProject(name: "Learning .NET", matchers: [.calendarKeyword("dotnet")])
        assistant.receive(.activeWindow(app: zoom, windowTitle: "Zoom Meeting"))
        assistant.receive(.calendar(events: [event("Dotnet study group")]))

        assistant.receive(.userIdle(seconds: 20 * 60))

        #expect(!assistant.now.isAway)
        #expect(assistant.now.project == dotnet.id)
    }

    @Test func idleWithNoMatchingMeetingIsStillAway() throws {
        let assistant = makeAssistant()
        try assistant.declareProject(name: "Learning .NET", matchers: [.calendarKeyword("dotnet")])
        assistant.receive(.activeWindow(app: zoom, windowTitle: "Zoom Meeting"))
        assistant.receive(.calendar(events: [event("Lunch")]))

        assistant.receive(.userIdle(seconds: 20 * 60))

        #expect(assistant.now.isAway)
    }

    @Test func aMeetingCanSetNowBeforeAnyWindowIsKnown() throws {
        let assistant = makeAssistant()
        let dotnet = try assistant.declareProject(name: "Learning .NET", matchers: [.calendarKeyword("dotnet")])

        assistant.receive(.calendar(events: [event("Dotnet study group")]))

        #expect(assistant.now.project == dotnet.id)
        #expect(assistant.menuBar.title == "LEARNING .NET")
        #expect(assistant.menuBar.window == nil)
    }

    @Test(arguments: ["", " ", "a"])
    func keywordsTooShortToMeanAnythingAreRejected(keyword: String) {
        let assistant = makeAssistant()
        #expect(throws: Matcher.Invalid.self) {
            try assistant.declareProject(name: "Too broad", matchers: [.calendarKeyword(keyword)])
        }
    }
}

@Suite struct IdleTests {
    let clock = FakeClock()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")

    func makeAssistant() throws -> (Assistant, Project) {
        let assistant = try Assistant(clock: clock, projects: InMemoryProjectStore(), homeDirectory: "/Users/dara")
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        return (assistant, todo)
    }

    @Test func fiveMinutesWithoutInputIsAwayAndNotWork() throws {
        let (assistant, _) = try makeAssistant()

        assistant.receive(.userIdle(seconds: 5 * 60))

        #expect(assistant.now.isAway)
        #expect(assistant.now.project == nil)
        #expect(assistant.menuBar.title == "AWAY")
        #expect(assistant.menuBar.marker == .away)
    }

    @Test func aShortPauseIsStillWork() throws {
        let (assistant, todo) = try makeAssistant()

        assistant.receive(.userIdle(seconds: 4 * 60))

        #expect(!assistant.now.isAway)
        #expect(assistant.now.project == todo.id)
    }

    @Test func comingBackResumesTheWindowsProjectFromThatMoment() throws {
        let (assistant, todo) = try makeAssistant()
        assistant.receive(.userIdle(seconds: 10 * 60))
        clock.advance(minutes: 20)

        assistant.receive(.userIdle(seconds: 2))

        #expect(!assistant.now.isAway)
        #expect(assistant.now.project == todo.id)
        #expect(assistant.now.since == clock.now)
    }

    @Test func aWindowChangeWhileAwayIsRememberedForWhenDaraComesBack() throws {
        let (assistant, _) = try makeAssistant()
        assistant.receive(.userIdle(seconds: 10 * 60))

        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/other"))
        #expect(assistant.now.isAway)

        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.now.window?.title == "~/code/other")
        #expect(assistant.now.project == nil)
    }
}

@Suite struct GitTests {
    let clock = FakeClock()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")

    @Test func theBranchOfTheMatchedRepoIsShownWithItsEvidence() throws {
        let assistant = try Assistant(clock: clock, projects: InMemoryProjectStore(), homeDirectory: "/Users/dara")
        try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])

        assistant.receive(.git(repo: "/Users/dara/code/todo-agent", branch: "ticket-03"))
        assistant.receive(.activeWindow(app: code, windowTitle: "Signal.swift — ~/code/todo-agent/Sources"))

        #expect(assistant.menuBar.evidence == "Matched by ~/code/todo-agent · ticket-03")
    }

    @Test func reposToWatchAreTheActiveProjectsRepoPathsInFull() throws {
        let assistant = try Assistant(clock: clock, projects: InMemoryProjectStore(), homeDirectory: "/Users/dara")
        try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent"), .urlPrefix("github.com/dara-soji/todo-agent")])
        let old = try assistant.declareProject(name: "old", matchers: [.repoPath("/opt/old")])
        try assistant.archiveProject(old.id)

        #expect(assistant.repoPathsToWatch == ["/Users/dara/code/todo-agent"])
    }
}
