import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

/// Fake ports for the guess: what was captured and what reached the model.
@MainActor
final class FakeCapturer: ScreenshotCapturer {
    var captured: [GuessKey] = []
    var fails = false
    /// Runs between the shot and the model call, to change the world mid-guess.
    var whileCapturing: () -> Void = {}

    func capture(_ key: GuessKey) async throws -> Data {
        if fails { throw URLError(.cannotConnectToHost) }
        captured.append(key)
        whileCapturing()
        return Data("PNG of \(key.title)".utf8)
    }
}

@MainActor
final class FakeModel: ModelClient {
    struct Seen: Equatable {
        let screenshot: Data
        let choices: [String]
    }

    var seen: [Seen] = []
    /// Which choice label to answer with; nil answers none.
    var answer: (([String]) -> String?)?
    var fails = false

    func chooseProject(screenshot: Data, choices: [String], none: String) async throws -> ModelAnswer {
        if fails { throw URLError(.timedOut) }
        seen.append(Seen(screenshot: screenshot, choices: choices))
        let call = APICall(
            at: Date(timeIntervalSince1970: 0), purpose: .projectGuess, model: "claude-haiku-5-5",
            inputTokens: 1_000, outputTokens: 10, contentKind: .screenshotAndProjectNames)
        return ModelAnswer(choice: answer?(choices) ?? none, call: call)
    }
}

@MainActor
@Suite struct GuessTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let capturer = FakeCapturer()
    let model = FakeModel()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")
    let preview = App(bundleID: "com.apple.Preview", name: "Preview")
    let slack = App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func runner(_ assistant: Assistant) -> GuessRunner {
        GuessRunner(assistant: assistant, capturer: capturer, model: model)
    }

    /// Haiku answers with the Project named `name`.
    func answers(_ name: String?) {
        model.answer = { choices in name.flatMap { name in choices.first { $0.hasPrefix(name) } } }
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

    func onSlides(_ assistant: Assistant) {
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 3 slides.pdf"))
    }

    // MARK: When to guess

    @Test func twoMinutesOnAStableUnmatchedWindowMakesOneGuess() async throws {
        let assistant = makeAssistant()
        let (todo, course) = try projects(assistant)
        onSlides(assistant)

        tick(assistant, minutes: 1)
        await runner(assistant).run()
        #expect(capturer.captured.isEmpty)

        tick(assistant, minutes: 1)
        await runner(assistant).run()
        await runner(assistant).run()
        #expect(capturer.captured == [slides])
        #expect(model.seen.count == 1)
        // Only the screenshot and Project names leave the Mac.
        #expect(model.seen.first?.screenshot == Data("PNG of Week 3 slides.pdf".utf8))
        #expect(model.seen.first?.choices == [course.name, todo.name])
    }

    @Test func aTitleChangeRestartsTheTwoMinutes() async throws {
        let assistant = makeAssistant()
        _ = try projects(assistant)
        onSlides(assistant)
        tick(assistant, minutes: 1.5)
        assistant.receive(.activeWindow(app: preview, windowTitle: "Week 4 slides.pdf"))
        tick(assistant, minutes: 1)
        await runner(assistant).run()
        #expect(capturer.captured.isEmpty)
    }

    @Test(arguments: ["matched", "tie", "neutral", "excluded", "away", "corrected", "no projects"])
    func someWindowsNeverGetAScreenshot(_ situation: String) async throws {
        let assistant = makeAssistant()
        if situation != "no projects" { _ = try projects(assistant) }
        switch situation {
        case "matched": assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        case "tie":
            try assistant.declareProject(name: "A", matchers: [.repoPath("~/code/shared")])
            try assistant.declareProject(name: "B", matchers: [.repoPath("~/code/shared")])
            assistant.receive(.activeWindow(app: code, windowTitle: "~/code/shared"))
        case "neutral": assistant.receive(.activeWindow(app: slack, windowTitle: "general"))
        case "excluded": assistant.receive(.activeWindow(app: preview, windowTitle: "x", excluded: true))
        case "away":
            onSlides(assistant)
            clock.advance(minutes: 10)
            assistant.receive(.userIdle(seconds: 10 * 60))
        case "corrected":
            onSlides(assistant)
            try assistant.correctNow(.none)
        default: onSlides(assistant)
        }
        clock.advance(minutes: 5)
        assistant.receive(.userIdle(seconds: situation == "away" ? 15 * 60 : 0))

        await runner(assistant).run()

        #expect(capturer.captured.isEmpty, "\(situation)")
        #expect(model.seen.isEmpty, "\(situation)")
    }

    @Test func nothingIsSentIfTheWindowChangedOrWasExcludedWhileCapturing() async throws {
        let assistant = makeAssistant()
        _ = try projects(assistant)
        onSlides(assistant)
        tick(assistant, minutes: 2)
        capturer.whileCapturing = {
            assistant.receive(.activeWindow(app: self.preview, windowTitle: "Week 3 slides.pdf", excluded: true))
        }

        await runner(assistant).run()

        #expect(capturer.captured == [slides])
        #expect(model.seen.isEmpty)
    }

    // MARK: Showing a guess

    @Test func aGuessIsShownAsAGuessAndAsked() async throws {
        let assistant = makeAssistant()
        let (_, course) = try projects(assistant)
        onSlides(assistant)
        tick(assistant, minutes: 2)
        answers("Learning .NET")

        await runner(assistant).run()

        #expect(assistant.now.project == course.id)
        #expect(assistant.now.confidentProject == nil)
        #expect(assistant.now.match?.basis == .guess)
        #expect(assistant.menuBar.marker == .guess)
        #expect(assistant.menuBar.title == "DOTNET?")
        #expect(assistant.menuBar.nowDetail == "Learning .NET · guess")
        #expect(assistant.decisions == [.isThis(course.id)])
        #expect(try store.load().audit.count == 1)
    }

    @Test func theAnswerIsCachedPerAppAndTitle() async throws {
        let assistant = makeAssistant()
        _ = try projects(assistant)
        onSlides(assistant)
        tick(assistant, minutes: 2)
        answers("Learning .NET")
        await runner(assistant).run()

        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        onSlides(assistant)
        tick(assistant, minutes: 5)
        await runner(assistant).run()

        #expect(assistant.now.match?.basis == .guess)
        #expect(model.seen.count == 1)
    }

    @Test func noneIsAnAnswerAndIsNotAskedAgain() async throws {
        let assistant = makeAssistant()
        _ = try projects(assistant)
        onSlides(assistant)
        tick(assistant, minutes: 2)
        answers(nil)

        await runner(assistant).run()
        tick(assistant, minutes: 30)
        await runner(assistant).run()

        #expect(assistant.now.project == nil)
        #expect(model.seen.count == 1)
    }

    @Test func aFailureIsNotAnAnswerAndIsTriedAgainLater() async throws {
        let assistant = makeAssistant()
        _ = try projects(assistant)
        onSlides(assistant)
        tick(assistant, minutes: 2)
        model.fails = true

        await runner(assistant).run()
        tick(assistant, minutes: 5)
        await runner(assistant).run()
        #expect(capturer.captured.count == 1)

        model.fails = false
        answers("Learning .NET")
        tick(assistant, minutes: 6)
        await runner(assistant).run()
        #expect(capturer.captured.count == 2)
        #expect(assistant.now.match?.basis == .guess)
    }

    @Test func aNewProjectGetsAnotherLookAtWindowsAnsweredNone() async throws {
        let assistant = makeAssistant()
        _ = try projects(assistant)
        onSlides(assistant)
        tick(assistant, minutes: 2)
        answers(nil)
        await runner(assistant).run()

        try assistant.declareProject(name: "Slides course", matchers: [])
        answers("Slides course")
        tick(assistant, minutes: 2)
        await runner(assistant).run()

        #expect(model.seen.count == 2)
        #expect(assistant.now.match?.basis == .guess)
    }

    @Test func choicesAreUniqueSoAProjectNamedNoneOrTwinNamesCantConfuseIt() async throws {
        let assistant = makeAssistant()
        try assistant.declareProject(name: "none", matchers: [])
        try assistant.declareProject(name: "Twin", matchers: [])
        let second = try assistant.declareProject(name: "Twin", matchers: [])
        onSlides(assistant)
        tick(assistant, minutes: 2)
        model.answer = { choices in choices.last }

        await runner(assistant).run()

        let choices = try #require(model.seen.first?.choices)
        #expect(Set(choices).count == choices.count + 0)
        #expect(!choices.contains("No Project"))
        // The last label is the last active Project by name, whichever twin that is.
        #expect(assistant.now.project == assistant.projects.last?.id)
        _ = second
    }

    @Test func aGuessOfAnArchivedProjectIsIgnored() async throws {
        let assistant = makeAssistant()
        let (_, course) = try projects(assistant)
        onSlides(assistant)
        tick(assistant, minutes: 2)
        model.answer = { _ in
            _ = try? assistant.archiveProject(course.id)
            return "Learning .NET"
        }

        await runner(assistant).run()

        #expect(assistant.now.project == nil)
    }

    // MARK: Yes / No

    @Test func yesCountsAsACorrectionWithoutLearning() async throws {
        let assistant = makeAssistant()
        let (_, course) = try projects(assistant)
        onSlides(assistant)
        tick(assistant, minutes: 2)
        answers("Learning .NET")
        await runner(assistant).run()

        try assistant.confirmGuess()

        #expect(assistant.now.match?.basis == .correction)
        #expect(assistant.project(course.id)?.matchers == [])
        #expect(!assistant.decisions.contains(.isThis(course.id)))
    }

    @Test func noItsSomethingElseCorrectsAndForgetsTheGuess() async throws {
        let assistant = makeAssistant()
        let (todo, _) = try projects(assistant)
        onSlides(assistant)
        tick(assistant, minutes: 2)
        answers("Learning .NET")
        await runner(assistant).run()

        try assistant.correctNow(.project(todo.id))
        #expect(assistant.now.project == todo.id)

        assistant.receive(.activeWindow(app: code, windowTitle: "elsewhere"))
        onSlides(assistant)
        #expect(assistant.now.project == nil)
    }

    // MARK: Never confident

    @Test func aGuessNeverDecidesAnything() async throws {
        let assistant = makeAssistant()
        let (todo, course) = try projects(assistant)
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        try assistant.quickAdd("Work", start: true)
        try assistant.addTask(TaskDraft(title: "Course reading", project: course.id))
        onSlides(assistant)
        tick(assistant, minutes: 2)
        answers("Learning .NET")
        await runner(assistant).run()

        for _ in 1...4 { tick(assistant, minutes: 5) }
        #expect(!assistant.isDrifting)
        // Quick-add doesn't file under a guess, and Next doesn't rank on it.
        let added = try assistant.quickAdd("Note")
        #expect(added.project == nil)
        #expect(assistant.menuBar.nextReason != "Continues DOTNET")

        assistant.receive(.activeWindow(app: slack, windowTitle: "general"))
        #expect(assistant.now.project != course.id)
        _ = todo
    }

    // MARK: Audit log

    @Test func apiCallsAreAuditedWithoutContentAndTodaysSpendSurvivesARestart() throws {
        let assistant = makeAssistant()
        let call = APICall(
            at: clock.now, purpose: .projectGuess, model: "claude-haiku-5-5", inputTokens: 1_800, outputTokens: 40,
            contentKind: .screenshotAndProjectNames)

        assistant.recordAPICall(call)
        assistant.recordAPICall(call)

        #expect(try store.load().audit == [call, call])
        #expect(call.costUSD == (1_800 * 0.10 + 40 * 0.50) / 1_000_000)
        #expect(assistant.apiSpendToday == 2 * call.costUSD)
        #expect(makeAssistant().apiSpendToday == 2 * call.costUSD)
    }
}
