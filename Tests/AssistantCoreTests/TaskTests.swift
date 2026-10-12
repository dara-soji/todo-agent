import Foundation
import Testing
import AssistantCore

@Suite struct TaskTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func onTodoAgent(_ assistant: Assistant) throws -> Project {
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        return todo
    }

    // MARK: Quick-add

    @Test func quickAddPutsAByHandTaskInNowsProject() throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)

        let task = try assistant.quickAdd("Write the MCP contract tests")

        #expect(task.title == "Write the MCP contract tests")
        #expect(task.source == .byHand)
        #expect(task.project == todo.id)
        #expect(task.status == .open)
        #expect(task.created == clock.now)
        #expect(assistant.tasks.map(\.id) == [task.id])
    }

    @Test func quickAddWithNoProjectLeavesTheTaskWithoutOne() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Call the bank back")
        #expect(task.project == nil)
    }

    @Test func aTaskNeedsATitle() {
        let assistant = makeAssistant()
        #expect(throws: Assistant.Failure.emptyTitle) { try assistant.quickAdd("   ") }
    }

    @Test func quickAddAndStartCommitsTheTaskAndMarksTheOldOneToResume() throws {
        let assistant = makeAssistant()
        let first = try assistant.quickAdd("Refactor the store", start: true)

        let interruption = try assistant.quickAdd("Reply to the landlord", start: true)

        #expect(assistant.committedTask?.id == interruption.id)
        #expect(assistant.task(first.id)?.status == .open)
        #expect(assistant.task(first.id)?.resumeAfterInterruption == true)
        #expect(assistant.tasks.filter { $0.status == .committed }.count == 1)
    }

    // MARK: Statuses

    @Test func committingATaskUncommitsThePreviousOne() throws {
        let assistant = makeAssistant()
        let a = try assistant.quickAdd("A")
        let b = try assistant.quickAdd("B")

        try assistant.commitTask(a.id)
        try assistant.commitTask(b.id)

        #expect(assistant.committedTask?.id == b.id)
        #expect(assistant.task(a.id)?.status == .open)
        #expect(assistant.task(a.id)?.resumeAfterInterruption == false)
    }

    @Test func markingTheCommittedTaskDoneLeavesNothingCommitted() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Ship ticket 04", start: true)

        try assistant.completeTask(task.id)

        #expect(assistant.task(task.id)?.status == .done)
        #expect(assistant.committedTask == nil)
    }

    @Test func snoozingUntilADateWakesTheTaskWhenThatTimeComes() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Renew passport")
        let wake = clock.now + 60 * 60

        try assistant.snoozeTask(task.id, until: wake)
        #expect(assistant.task(task.id)?.status == .snoozed(until: wake, note: nil))

        clock.advance(minutes: 61)
        assistant.receive(.userIdle(seconds: 0))

        #expect(assistant.task(task.id)?.status == .open)
        #expect(assistant.operationLog.last?.kind == .wakeTask)
        #expect(assistant.operationLog.last?.startedBy == .helper)
    }

    @Test func waitingOnSomeoneHasANoteAndNoWakeTime() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Merge the PR")

        try assistant.snoozeTask(task.id, until: nil, note: "Waiting on review from Sam")
        clock.advance(minutes: 60 * 24 * 30)
        assistant.receive(.userIdle(seconds: 0))

        #expect(assistant.task(task.id)?.status == .snoozed(until: nil, note: "Waiting on review from Sam"))
    }

    @Test func droppingATaskKeepsItButOutOfPlay() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Learn Rust", start: true)

        try assistant.dropTask(task.id)

        #expect(assistant.task(task.id)?.status == .dropped)
        #expect(assistant.committedTask == nil)
    }

    @Test func editingChangesOnlyTheGivenFields() throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        let task = try assistant.quickAdd("Draft README")
        let deadline = clock.now + 2 * 24 * 60 * 60

        try assistant.editTask(task.id, TaskChanges(title: "Draft the README", deadline: .some(deadline), effort: .some(.small), kind: .some(.shallow)))

        let edited = try #require(assistant.task(task.id))
        #expect(edited.title == "Draft the README")
        #expect(edited.deadline == deadline)
        #expect(edited.effort == .small)
        #expect(edited.kind == .shallow)
        #expect(edited.project == todo.id)
        #expect(edited.created == task.created)
    }

    @Test func aTaskFromAnotherSourceKeepsItsBackLink() throws {
        let assistant = makeAssistant()
        let task = try assistant.addTask(TaskDraft(title: "Fix flaky test", source: .code, backLink: "~/code/todo-agent"))
        #expect(task.source == .code)
        #expect(task.backLink == "~/code/todo-agent")
    }

    @Test func editingAnUnknownTaskFails() {
        let assistant = makeAssistant()
        let missing = Task.ID()
        #expect(throws: Assistant.Failure.unknownTask(missing)) { try assistant.completeTask(missing) }
    }

    // MARK: Soft delete

    @Test func deletingMovesATaskToTheDeletedListAndRestoringBringsItBack() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Old idea", start: true)

        try assistant.deleteTask(task.id)
        #expect(assistant.tasks.isEmpty)
        #expect(assistant.deletedTasks.map(\.id) == [task.id])
        #expect(assistant.committedTask == nil)

        try assistant.restoreTask(task.id)
        #expect(assistant.tasks.map(\.id) == [task.id])
        #expect(assistant.deletedTasks.isEmpty)
    }

    @Test func restoringADeletedCommittedTaskNeverMakesASecondCommittedTask() throws {
        let assistant = makeAssistant()
        let a = try assistant.quickAdd("A", start: true)
        try assistant.deleteTask(a.id)
        let b = try assistant.quickAdd("B", start: true)

        try assistant.restoreTask(a.id)

        #expect(assistant.committedTask?.id == b.id)
        #expect(assistant.tasks.filter { $0.status == .committed }.count == 1)
    }

    // MARK: Persistence

    @Test func tasksSurviveARestart() throws {
        let task = try makeAssistant().quickAdd("Persist me", start: true)

        let restarted = makeAssistant()

        #expect(restarted.tasks == [try #require(restarted.task(task.id))])
        #expect(restarted.committedTask?.id == task.id)
    }

    @Test func aTaskChangeThatCannotBeSavedIsNotApplied() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Stay open")
        store.failCommits = true

        #expect(throws: InMemoryStore.CommitFailed.self) { try assistant.completeTask(task.id) }

        #expect(assistant.task(task.id)?.status == .open)
        #expect(assistant.operationLog.count == 1)
    }
}

@Suite struct OperationLogTests {
    let clock = FakeClock()
    let store = InMemoryStore()

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    @Test func everyOperationIsLoggedAsAutoWithWhoStartedIt() throws {
        let assistant = makeAssistant()

        let project = try assistant.declareProject(name: "todo-agent", matchers: [], by: .claudeCode)
        let task = try assistant.quickAdd("Write tests", by: .dara)
        try assistant.commitTask(task.id, by: .claudeCode)
        try assistant.archiveProject(project.id, by: .dara)

        #expect(assistant.operationLog.map(\.kind) == [.declareProject, .addTask, .commitTask, .archiveProject])
        #expect(assistant.operationLog.map(\.startedBy) == [.claudeCode, .dara, .claudeCode, .dara])
        #expect(assistant.operationLog.allSatisfy { $0.tier == .auto && $0.confirmation == .notNeeded })
        #expect(assistant.operationLog.allSatisfy { $0.at == clock.now })
    }

    @Test func undoPutsTasksBackAndIsItselfLogged() throws {
        let assistant = makeAssistant()
        let first = try assistant.quickAdd("First", start: true)
        let second = try assistant.quickAdd("Second", start: true)
        let start = try #require(assistant.operationLog.last)

        try assistant.undo(start.id)

        #expect(assistant.committedTask?.id == first.id)
        #expect(assistant.task(first.id)?.resumeAfterInterruption == false)
        #expect(assistant.deletedTasks.map(\.id) == [second.id])
        #expect(assistant.operationLog.last?.kind == .undo)
        #expect(assistant.operationLog.last?.undoes == start.id)
    }

    @Test func undoIsRefusedOnceTheTaskHasChangedSince() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Changing")
        let added = try #require(assistant.operationLog.last)
        try assistant.completeTask(task.id)

        #expect(throws: Assistant.Failure.changedSince(added.id)) { try assistant.undo(added.id) }
        #expect(assistant.task(task.id)?.status == .done)
    }

    @Test func undoingAProjectEditPutsTheProjectBack() throws {
        let assistant = makeAssistant()
        let project = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])
        try assistant.renameProject(project.id, name: "Assistant")

        try assistant.undo(try #require(assistant.operationLog.last).id)

        #expect(assistant.project(project.id)?.name == "todo-agent")
    }

    @Test func theLogSurvivesARestart() throws {
        let assistant = makeAssistant()
        try assistant.quickAdd("Logged")

        #expect(makeAssistant().operationLog == assistant.operationLog)
    }
}
