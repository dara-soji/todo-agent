import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

@Suite struct DriftTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")
    let slack = App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    let notes = App(bundleID: "com.apple.Notes", name: "Notes")

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    /// Committed to a Task in todo-agent, working in it; "other" is a second Project.
    func committed() throws -> (Assistant, todo: Project, other: Project, task: Task) {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", shortName: "todo", matchers: [.repoPath("~/code/todo-agent")])
        let other = try assistant.declareProject(name: "Other", shortName: "other", matchers: [.repoPath("~/code/other")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        let task = try assistant.quickAdd("Write the Nudge", start: true)
        return (assistant, todo, other, task)
    }

    func tick(_ assistant: Assistant, minutes: Double) {
        clock.advance(minutes: minutes)
        assistant.receive(.userIdle(seconds: 0))
    }

    func goOther(_ assistant: Assistant) {
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/other"))
    }

    // MARK: Drift

    @Test func fiveMinutesOnAnotherProjectIsDriftWithOneNudge() throws {
        let (assistant, todo, other, task) = try committed()
        goOther(assistant)

        tick(assistant, minutes: 4)
        #expect(!assistant.isDrifting)
        #expect(assistant.nudge == nil)

        tick(assistant, minutes: 1)
        #expect(assistant.isDrifting)
        #expect(assistant.nudge == Nudge(task: task.id, committedProject: todo.id, nowProject: other.id))
        #expect(assistant.menuBar.drifting)
        #expect(assistant.menuBar.title == "OTHER")
    }

    @Test func noProjectCountsAsDriftToo() throws {
        let (assistant, _, _, _) = try committed()
        assistant.receive(.activeWindow(app: notes, windowTitle: "Ideas"))

        tick(assistant, minutes: 5)

        #expect(assistant.isDrifting)
        #expect(assistant.nudge?.nowProject == nil)
    }

    @Test func withoutACommittedTaskThereIsNoDrift() throws {
        let (assistant, _, _, task) = try committed()
        try assistant.completeTask(task.id)
        goOther(assistant)

        tick(assistant, minutes: 30)

        #expect(!assistant.isDrifting)
    }

    @Test func aNeutralHoldOfTheCommittedProjectIsNotDrift() throws {
        let (assistant, _, _, _) = try committed()
        assistant.receive(.activeWindow(app: slack, windowTitle: "general"))

        tick(assistant, minutes: 10)
        #expect(!assistant.isDrifting)

        tick(assistant, minutes: 5)   // Hold over at 15: No Project from here.
        tick(assistant, minutes: 4)
        #expect(!assistant.isDrifting)
        tick(assistant, minutes: 1)
        #expect(assistant.isDrifting)
    }

    @Test func awayTimeDoesNotCount() throws {
        let (assistant, _, _, _) = try committed()
        goOther(assistant)
        tick(assistant, minutes: 3)

        clock.advance(minutes: 20)
        assistant.receive(.userIdle(seconds: 20 * 60))
        #expect(!assistant.isDrifting)
        assistant.receive(.userIdle(seconds: 0))
        tick(assistant, minutes: 3)

        #expect(!assistant.isDrifting)
    }

    // MARK: Once per episode

    @Test func theNudgeComesOncePerEpisodeAndReArmsOnReturn() throws {
        let (assistant, _, _, _) = try committed()
        goOther(assistant)
        tick(assistant, minutes: 5)
        assistant.dismissNudge()

        tick(assistant, minutes: 30)
        #expect(assistant.isDrifting)
        #expect(assistant.nudge == nil)

        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        #expect(!assistant.isDrifting)
        goOther(assistant)
        tick(assistant, minutes: 5)
        #expect(assistant.nudge != nil)
    }

    @Test func itsRelatedCorrectsNowToTheCommittedProject() throws {
        let (assistant, todo, _, _) = try committed()
        goOther(assistant)
        tick(assistant, minutes: 5)

        try assistant.nudgeIsRelated()

        #expect(assistant.now.project == todo.id)
        #expect(assistant.now.match?.basis == .correction)
        #expect(!assistant.isDrifting)
        #expect(assistant.nudge == nil)
    }

    @Test func quietHoldsNudgesBackForThirtyMinutes() throws {
        let (assistant, _, _, _) = try committed()
        goOther(assistant)
        tick(assistant, minutes: 5)
        assistant.quietNudges()
        #expect(assistant.nudge == nil)

        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        goOther(assistant)
        tick(assistant, minutes: 10)
        #expect(assistant.isDrifting)
        #expect(assistant.nudge == nil)

        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        goOther(assistant)
        tick(assistant, minutes: 21)  // Past the 30 quiet minutes.
        #expect(assistant.nudge != nil)
    }

    // MARK: New task?

    @Test func tenMinutesOnNoProjectAsksNewTask() throws {
        let (assistant, _, _, _) = try committed()
        assistant.receive(.activeWindow(app: notes, windowTitle: "Landlord email draft"))

        tick(assistant, minutes: 9)
        #expect(!assistant.decisions.contains(.newTask("Landlord email draft")))

        tick(assistant, minutes: 1)
        #expect(assistant.decisions.contains(.newTask("Landlord email draft")))
    }

    @Test func addingTheNewTaskCommitsItAndRemembersTheInterruptedOne() throws {
        let (assistant, _, _, task) = try committed()
        assistant.receive(.activeWindow(app: notes, windowTitle: "Landlord email draft"))
        tick(assistant, minutes: 10)

        let added = try assistant.addNewTask()

        #expect(assistant.committedTask?.id == added.id)
        #expect(added.title == "Landlord email draft")
        #expect(assistant.task(task.id)?.resumeAfterInterruption == true)
        #expect(!assistant.decisions.contains(.newTask("Landlord email draft")))

        try assistant.completeTask(added.id)
        #expect(assistant.next.task == task.id)
        #expect(assistant.menuBar.nextReason == "Back to what you were doing before the interruption")
    }

    @Test func itsAQuickOneDismissesItForThatStretch() throws {
        let (assistant, _, _, _) = try committed()
        assistant.receive(.activeWindow(app: notes, windowTitle: "Quick"))
        tick(assistant, minutes: 10)

        assistant.dismissNewTask()
        tick(assistant, minutes: 30)

        #expect(!assistant.decisions.contains(.newTask("Quick")))
    }

    @Test func aWindowWithNoTitleIsNamedByItsApp() throws {
        let (assistant, _, _, _) = try committed()
        assistant.receive(.activeWindow(app: notes, windowTitle: nil))
        tick(assistant, minutes: 10)
        #expect(assistant.decisions.contains(.newTask("Notes")))
    }

    // MARK: Now history

    @Test func nowHistoryIsProjectTimeBlocksWithoutTitles() throws {
        let (assistant, todo, other, task) = try committed()
        let start = clock.now
        tick(assistant, minutes: 20)
        goOther(assistant)
        tick(assistant, minutes: 10)
        assistant.receive(.activeWindow(app: notes, windowTitle: "Secret plans"))

        let blocks = try store.load().history
        #expect(blocks == [
            NowBlock(project: todo.id, committedTask: task.id, start: start, end: start + 20 * 60),
            NowBlock(project: other.id, committedTask: task.id, start: start + 20 * 60, end: start + 30 * 60),
        ])
    }

    @Test func closingTheHistoryWritesTheOpenBlock() throws {
        let (assistant, todo, _, task) = try committed()
        let start = clock.now
        tick(assistant, minutes: 7)

        assistant.closeNowHistory()

        #expect(try store.load().history == [NowBlock(project: todo.id, committedTask: task.id, start: start, end: start + 7 * 60)])
    }
}
