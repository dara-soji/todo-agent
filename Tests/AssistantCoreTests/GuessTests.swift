import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

@Suite struct GuessTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")
    let preview = App(bundleID: "com.apple.Preview", name: "Preview")
    let slack = App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func tick(_ assistant: Assistant, minutes: Double) {
        clock.advance(minutes: minutes)
        assistant.receive(.userIdle(seconds: 0))
    }

    func projects(_ assistant: Assistant) throws -> (todo: Project, course: Project) {
        (try assistant.declareProject(name: "todo-agent", shortName: "todo", matchers: [.repoPath("~/code/todo-agent")]),
         try assistant.declareProject(name: "Learning .NET", shortName: "dotnet", matchers: []))
    }

    let slides = GuessKey(bundleID: "com.apple.Preview", title: "Week 3 slides.pdf")

    // MARK: When to guess

    @Test func twoMinutesOnAStableUnmatchedWindowAsksForOneGuess() throws {
        let assistant = makeAssistant()
        let (todo, course) = try projects(assistant)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))

        tick(assistant, minutes: 1)
        #expect(assistant.takeGuessRequest() == nil)

        tick(assistant, minutes: 1)
        let request = try #require(assistant.takeGuessRequest())
        #expect(request.key == slides)
        #expect(request.projects.map(\.id) == [course.id, todo.id])
        #expect(assistant.takeGuessRequest() == nil)  // In flight: only one.
    }

    @Test func aTitleChangeRestartsTheTwoMinutes() throws {
        let assistant = makeAssistant()
        _ = try projects(assistant)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
        tick(assistant, minutes: 1.5)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 4 slides.pdf"))
        tick(assistant, minutes: 1)
        #expect(assistant.takeGuessRequest() == nil)
    }

    @Test(arguments: ["matched", "neutral", "excluded", "away", "corrected", "no projects"])
    func someWindowsNeverAskForAGuess(_ situation: String) throws {
        let assistant = makeAssistant()
        if situation != "no projects" { _ = try projects(assistant) }
        switch situation {
        case "matched": assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        case "neutral": assistant.receive(.activeWindow(app: slack, windowTitle: "general"))
        case "excluded": assistant.receive(.activeWindow(app: preview, windowTitle: "x", excluded: true))
        case "away":
            assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
            clock.advance(minutes: 10)
            assistant.receive(.userIdle(seconds: 10 * 60))
        case "corrected":
            assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
            try assistant.correctNow(.none)
        default: assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
        }
        clock.advance(minutes: 5)
        assistant.receive(.userIdle(seconds: situation == "away" ? 15 * 60 : 0))

        #expect(assistant.takeGuessRequest() == nil, "\(situation)")
    }

    // MARK: Showing a guess

    @Test func aGuessIsShownAsAGuessAndAsked() throws {
        let assistant = makeAssistant()
        let (_, course) = try projects(assistant)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
        tick(assistant, minutes: 2)
        _ = assistant.takeGuessRequest()

        assistant.receive(.projectGuess(key: slides, project: course.id))

        #expect(assistant.now.project == course.id)
        #expect(assistant.now.match?.basis == .guess)
        #expect(assistant.menuBar.marker == .guess)
        #expect(assistant.menuBar.title == "DOTNET?")
        #expect(assistant.menuBar.nowDetail == "Learning .NET · guess")
        #expect(assistant.decisions == [.isThis(course.id)])
    }

    @Test func theAnswerIsCachedPerAppAndTitle() throws {
        let assistant = makeAssistant()
        let (_, course) = try projects(assistant)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
        tick(assistant, minutes: 2)
        _ = assistant.takeGuessRequest()
        assistant.receive(.projectGuess(key: slides, project: course.id))

        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))

        #expect(assistant.now.match?.basis == .guess)
        tick(assistant, minutes: 5)
        #expect(assistant.takeGuessRequest() == nil)
    }

    @Test func noneOrAFailureLeavesNoProjectAndIsNotAskedAgain() throws {
        let assistant = makeAssistant()
        _ = try projects(assistant)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
        tick(assistant, minutes: 2)
        _ = assistant.takeGuessRequest()

        assistant.receive(.projectGuess(key: slides, project: nil))
        tick(assistant, minutes: 10)

        #expect(assistant.now.project == nil)
        #expect(assistant.takeGuessRequest() == nil)
    }

    @Test func aGuessForAnotherWindowWaitsUntilThatWindowComesBack() throws {
        let assistant = makeAssistant()
        let (_, course) = try projects(assistant)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
        tick(assistant, minutes: 2)
        _ = assistant.takeGuessRequest()
        assistant.receive(.activeWindow(app: preview, windowTitle: "Other.pdf"))

        assistant.receive(.projectGuess(key: slides, project: course.id))

        #expect(assistant.now.project == nil)
    }

    @Test func aGuessOfAnArchivedOrUnknownProjectIsIgnored() throws {
        let assistant = makeAssistant()
        let (_, course) = try projects(assistant)
        try assistant.archiveProject(course.id)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
        tick(assistant, minutes: 2)
        _ = assistant.takeGuessRequest()

        assistant.receive(.projectGuess(key: slides, project: course.id))

        #expect(assistant.now.project == nil)
    }

    // MARK: Yes / No

    @Test func yesCountsAsACorrectionAndOffersAlwaysWithoutLearning() throws {
        let assistant = makeAssistant()
        let (_, course) = try projects(assistant)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf", url: nil))
        tick(assistant, minutes: 2)
        _ = assistant.takeGuessRequest()
        assistant.receive(.projectGuess(key: slides, project: course.id))

        try assistant.confirmGuess()

        #expect(assistant.now.match?.basis == .correction)
        #expect(assistant.project(course.id)?.matchers == [])
        #expect(!assistant.decisions.contains(.isThis(course.id)))
    }

    @Test func noItsSomethingElseCorrectsAndForgetsTheGuess() throws {
        let assistant = makeAssistant()
        let (todo, course) = try projects(assistant)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
        tick(assistant, minutes: 2)
        _ = assistant.takeGuessRequest()
        assistant.receive(.projectGuess(key: slides, project: course.id))

        try assistant.correctNow(.project(todo.id))
        #expect(assistant.now.project == todo.id)

        assistant.receive(.activeWindow(app: code, windowTitle: "elsewhere"))
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
        #expect(assistant.now.project == nil)
    }

    // MARK: Never confident

    @Test func aGuessNeverCountsTowardDriftNorIsHeld() throws {
        let assistant = makeAssistant()
        let (_, course) = try projects(assistant)
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        try assistant.quickAdd("Work", start: true)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
        tick(assistant, minutes: 2)
        _ = assistant.takeGuessRequest()
        assistant.receive(.projectGuess(key: slides, project: course.id))

        for _ in 1...4 { tick(assistant, minutes: 5) }
        #expect(!assistant.isDrifting)

        assistant.receive(.activeWindow(app: slack, windowTitle: "general"))
        #expect(assistant.now.project != course.id)
    }

    // MARK: Audit log

    @Test func apiCallsAreAuditedWithoutContent() throws {
        let assistant = makeAssistant()
        let call = APICall(
            at: clock.now, purpose: .projectGuess, model: "claude-haiku-5-5", inputTokens: 1_800, outputTokens: 40,
            contentKind: .screenshotAndProjectNames)

        assistant.recordAPICall(call)
        assistant.recordAPICall(call)

        #expect(try store.load().audit == [call, call])
        #expect(call.costUSD == (1_800 * 0.10 + 40 * 0.50) / 1_000_000)
        #expect(assistant.apiSpendSinceLaunch == 2 * call.costUSD)
    }
}
