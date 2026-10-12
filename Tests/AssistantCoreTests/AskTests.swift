import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

@Suite struct AskTests {
    let clock = FakeClock()
    let store = InMemoryStore()

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    // MARK: Pending and confirming

    @Test func anAskOperationWaitsForDaraAndChangesNothingYet() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Ship it")
        try assistant.tighten(.completeTask)

        let outcome = try assistant.inSession("s1") { try assistant.completeTask(task.id, by: .claudeCode) }

        let ask = try #require(assistant.asks.first)
        #expect(outcome == .pending(ask.id))
        #expect(assistant.task(task.id)?.status == .open)
        #expect(ask.startedBy == .claudeCode)
        #expect(ask.summary == "Completed “Ship it”")
        #expect(assistant.decisions == [.confirm(ask.id)])
        #expect(assistant.menuBar.decisionsWaiting)
    }

    @Test func confirmingRunsItAndLogsItAsConfirmedAsk() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Ship it")
        try assistant.tighten(.completeTask)
        try assistant.inSession("s1") { try assistant.completeTask(task.id, by: .claudeCode) }
        let ask = try #require(assistant.asks.first)

        try assistant.confirmAsk(ask.id)

        #expect(assistant.task(task.id)?.status == .done)
        #expect(assistant.asks.isEmpty)
        let entry = try #require(assistant.operationLog.last)
        #expect(entry.kind == .completeTask)
        #expect(entry.tier == .ask)
        #expect(entry.confirmation == .confirmed)
        #expect(entry.startedBy == .claudeCode)
    }

    @Test func decliningLeavesEverythingAndLogsItNotRun() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Ship it")
        try assistant.tighten(.completeTask)
        try assistant.completeTask(task.id)
        let ask = try #require(assistant.asks.first)

        try assistant.declineAsk(ask.id)

        #expect(assistant.task(task.id)?.status == .open)
        #expect(assistant.asks.isEmpty)
        #expect(assistant.operationLog.last?.confirmation == .declined)
        #expect(assistant.operationLog.last?.summary == "Not run: Completed “Ship it”")
    }

    @Test func anAskThatCreatesSomethingCanBeConfirmed() throws {
        let assistant = makeAssistant()
        try assistant.tighten(.addTask)
        try assistant.tighten(.declareProject)

        let task = try assistant.quickAdd("New")
        let project = try assistant.declareProject(name: "New Project", matchers: [])
        #expect(assistant.task(task.id) == nil)
        #expect(assistant.project(project.id) == nil)

        for ask in assistant.asks { try assistant.confirmAsk(ask.id) }

        #expect(assistant.task(task.id)?.title == "New")
        #expect(assistant.project(project.id)?.name == "New Project")
    }

    @Test func anAskThatCreatesSomethingAlreadyCreatedSinceIsRefused() throws {
        let assistant = makeAssistant()
        try assistant.tighten(.restoreTask)
        let task = try assistant.quickAdd("Gone")
        try assistant.deleteTask(task.id)
        try assistant.restoreTask(task.id)
        let ask = try #require(assistant.asks.first)
        try assistant.resetTier(.restoreTask)
        try assistant.restoreTask(task.id)

        #expect(throws: Assistant.Failure.askChangedSince(ask.id)) { try assistant.confirmAsk(ask.id) }
    }

    @Test func anUnansweredAskExpiresAfterThirtyMinutes() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Ship it")
        try assistant.tighten(.completeTask)
        try assistant.completeTask(task.id)

        clock.advance(minutes: 29)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.asks.count == 1)

        clock.advance(minutes: 1)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.asks.isEmpty)
        #expect(assistant.task(task.id)?.status == .open)
        #expect(assistant.operationLog.last?.confirmation == .expired)
        #expect(assistant.operationLog.last?.summary == "Expired, not run: Completed “Ship it”")
    }

    @Test func anExpiredAskLeavesTheMenuOnTimeAndIsLoggedWhenItExpired() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Ship it")
        try assistant.tighten(.completeTask)
        try assistant.completeTask(task.id)
        let expires = try #require(assistant.asks.first).expires

        clock.advance(minutes: 45)  // No Signal arrives.

        #expect(assistant.decisions.isEmpty)
        assistant.expireDueAsks()
        #expect(assistant.asks.isEmpty)
        #expect(assistant.operationLog.last?.at == expires)
    }

    @Test func quittingExpiresEveryPendingAsk() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Ship it")
        try assistant.tighten(.completeTask)
        try assistant.completeTask(task.id)

        assistant.expireAllAsks()

        #expect(assistant.asks.isEmpty)
        #expect(assistant.operationLog.last?.confirmation == .expired)
    }

    @Test func aDeclinedOrExpiredEntryCannotBeUndone() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Ship it")
        try assistant.tighten(.completeTask)
        try assistant.completeTask(task.id)
        try assistant.declineAsk(try #require(assistant.asks.first).id)
        let declined = try #require(assistant.operationLog.last)

        #expect(throws: Assistant.Failure.notUndoable(declined.id)) { try assistant.undo(declined.id) }
    }

    @Test func anExpiredAskCanNoLongerBeConfirmed() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Ship it")
        try assistant.tighten(.completeTask)
        try assistant.completeTask(task.id)
        let ask = try #require(assistant.asks.first)
        clock.advance(minutes: 31)

        #expect(throws: Assistant.Failure.unknownAsk(ask.id)) { try assistant.confirmAsk(ask.id) }
        #expect(assistant.task(task.id)?.status == .open)
    }

    @Test func endingAConversationExpiresOnlyItsAsks() throws {
        let assistant = makeAssistant()
        let a = try assistant.quickAdd("A")
        let b = try assistant.quickAdd("B")
        try assistant.tighten(.completeTask)
        try assistant.inSession("s1") { try assistant.completeTask(a.id, by: .claudeCode) }
        try assistant.inSession("s2") { try assistant.completeTask(b.id, by: .claudeCode) }

        assistant.endSession("s1")

        #expect(assistant.asks.map(\.session) == ["s2"])
        #expect(assistant.operationLog.last?.confirmation == .expired)
    }

    @Test func confirmingIsRefusedIfTheTaskChangedSince() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Ship it")
        try assistant.tighten(.completeTask)
        try assistant.completeTask(task.id)
        let ask = try #require(assistant.asks.first)
        try assistant.editTask(task.id, TaskChanges(title: "Ship it today"))

        #expect(throws: Assistant.Failure.askChangedSince(ask.id)) { try assistant.confirmAsk(ask.id) }
        #expect(assistant.task(task.id)?.status == .open)
        #expect(assistant.asks.map(\.id) == [ask.id])
    }

    // MARK: Grouping

    @Test func severalAsksFromOneConversationAreOneConfirm() throws {
        let assistant = makeAssistant()
        let a = try assistant.quickAdd("A")
        let b = try assistant.quickAdd("B")
        try assistant.tighten(.dropTask)

        try assistant.inSession("s1") { try assistant.dropTask(a.id, by: .claudeCode) }
        clock.advance(minutes: 1)
        try assistant.inSession("s1") { try assistant.dropTask(b.id, by: .claudeCode) }

        let ask = try #require(assistant.asks.first)
        #expect(assistant.asks.count == 1)
        #expect(ask.operations.map(\.summary) == ["Dropped “A”", "Dropped “B”"])

        try assistant.confirmAsk(ask.id)
        #expect(assistant.task(a.id)?.status == .dropped)
        #expect(assistant.task(b.id)?.status == .dropped)
        #expect(assistant.operationLog.suffix(2).map(\.confirmation) == [.confirmed, .confirmed])
    }

    @Test func asksFromDifferentConversationsOrFromDaraStaySeparate() throws {
        let assistant = makeAssistant()
        let a = try assistant.quickAdd("A")
        let b = try assistant.quickAdd("B")
        let c = try assistant.quickAdd("C")
        try assistant.tighten(.dropTask)

        try assistant.inSession("s1") { try assistant.dropTask(a.id, by: .claudeCode) }
        try assistant.inSession("s2") { try assistant.dropTask(b.id, by: .claudeCode) }
        try assistant.dropTask(c.id)

        #expect(assistant.asks.count == 3)
    }

    @Test func aSecondAskOnATaskAlreadyWaitingStartsItsOwnConfirm() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("A")
        try assistant.tighten(.dropTask)
        try assistant.tighten(.editTask)

        try assistant.inSession("s1") { try assistant.dropTask(task.id, by: .claudeCode) }
        try assistant.inSession("s1") { try assistant.editTask(task.id, TaskChanges(title: "A2"), by: .claudeCode) }

        #expect(assistant.asks.count == 2)
    }

    // MARK: Bulk edits

    @Test func editingUpToFiveTasksAtOnceRunsWithoutAsking() throws {
        let assistant = makeAssistant()
        let tasks = try (1...5).map { try assistant.quickAdd("T\($0)") }

        let outcome = try assistant.editTasks(tasks.map(\.id), TaskChanges(kind: .some(.shallow)))

        guard case .ran = outcome else { Issue.record("expected ran, got \(outcome)"); return }
        #expect(assistant.tasks.allSatisfy { $0.kind == .shallow })
        #expect(assistant.operationLog.last?.kind == .bulkEditTasks)
    }

    @Test func editingMoreThanFiveTasksAsksWithAPreview() throws {
        let assistant = makeAssistant()
        let tasks = try (1...6).map { try assistant.quickAdd("T\($0)") }

        try assistant.editTasks(tasks.map(\.id), TaskChanges(kind: .some(.shallow)), by: .claudeCode)

        let ask = try #require(assistant.asks.first)
        #expect(assistant.tasks.allSatisfy { $0.kind == nil })
        #expect(ask.summary == "Edited 6 Tasks: kind")
        #expect(ask.preview == ["T1", "T2", "T3", "T4", "T5", "T6"])
    }

    @Test func aBulkRenamePreviewsTheTasksAsTheyAreNow() throws {
        let assistant = makeAssistant()
        let tasks = try (1...6).map { try assistant.quickAdd("T\($0)") }

        try assistant.editTasks(tasks.map(\.id), TaskChanges(title: "Same", deadline: .some(nil)))

        #expect(assistant.asks.first?.summary == "Edited 6 Tasks: title, deadline")
        #expect(assistant.asks.first?.preview == ["T1", "T2", "T3", "T4", "T5", "T6"])
    }

    // MARK: Changing tiers

    @Test func daraCanLoosenAnAskOperationForOneProject() throws {
        let assistant = makeAssistant()
        let course = try assistant.declareProject(name: "Course", matchers: [])
        let inCourse = try (1...6).map { try assistant.addTask(TaskDraft(title: "C\($0)", project: course.id)) }
        let mixed = try (1...5).map { try assistant.quickAdd("M\($0)") } + [inCourse[0]]

        try assistant.loosen(.bulkEditTasks, in: course.id)

        guard case .ran = try assistant.editTasks(inCourse.map(\.id), TaskChanges(effort: .some(.small))) else {
            Issue.record("bulk edit in the loosened Project should run"); return
        }
        guard case .pending = try assistant.editTasks(mixed.map(\.id), TaskChanges(effort: .some(.large))) else {
            Issue.record("bulk edit outside it should still ask"); return
        }
    }

    @Test func onlyAskOperationsCanBeLoosened() throws {
        let assistant = makeAssistant()
        #expect(throws: Assistant.Failure.cannotLoosen(.completeTask)) { try assistant.loosen(.completeTask) }
        #expect(assistant.guardrailRules.isEmpty)
    }

    @Test func tighteningWinsOverLoosening() throws {
        let assistant = makeAssistant()
        let course = try assistant.declareProject(name: "Course", matchers: [])
        let tasks = try (1...6).map { try assistant.addTask(TaskDraft(title: "C\($0)", project: course.id)) }
        try assistant.loosen(.bulkEditTasks, in: course.id)
        try assistant.tighten(.bulkEditTasks)
        #expect(assistant.guardrailRules.count == 2)

        guard case .pending = try assistant.editTasks(tasks.map(\.id), TaskChanges(kind: .some(.deep))) else {
            Issue.record("tightened should ask"); return
        }
    }

    @Test func aTightenedProjectScopeAsksOnlyForThatProject() throws {
        let assistant = makeAssistant()
        let work = try assistant.declareProject(name: "Work", matchers: [])
        let inWork = try assistant.addTask(TaskDraft(title: "W", project: work.id))
        let elsewhere = try assistant.quickAdd("E")

        try assistant.tighten(.dropTask, in: work.id)

        guard case .pending = try assistant.dropTask(inWork.id) else { Issue.record("should ask"); return }
        guard case .ran = try assistant.dropTask(elsewhere.id) else { Issue.record("should run"); return }
    }

    @Test func movingATaskOutOfATightenedProjectStillAsks() throws {
        let assistant = makeAssistant()
        let work = try assistant.declareProject(name: "Work", matchers: [])
        let home = try assistant.declareProject(name: "Home", matchers: [])
        let task = try assistant.addTask(TaskDraft(title: "W", project: work.id))
        try assistant.tighten(.editTask, in: work.id)

        guard case .pending = try assistant.editTask(task.id, TaskChanges(project: .some(home.id))) else {
            Issue.record("moving out of Work should ask"); return
        }
        #expect(assistant.task(task.id)?.project == work.id)
    }

    @Test func movingTasksIntoALoosenedProjectStillAsks() throws {
        let assistant = makeAssistant()
        let course = try assistant.declareProject(name: "Course", matchers: [])
        let others = try (1...6).map { try assistant.quickAdd("O\($0)") }
        try assistant.loosen(.bulkEditTasks, in: course.id)

        guard case .pending = try assistant.editTasks(others.map(\.id), TaskChanges(project: .some(course.id))) else {
            Issue.record("Tasks from outside Course should ask"); return
        }
    }

    @Test func everyTierChangeIsLoggedAndSurvivesARestart() throws {
        let assistant = makeAssistant()
        try assistant.tighten(.deleteTask)
        try assistant.loosen(.bulkEditTasks)

        #expect(assistant.operationLog.suffix(2).map(\.kind) == [.changeGuardrail, .changeGuardrail])
        #expect(assistant.operationLog.last?.startedBy == .dara)
        let restarted = makeAssistant()
        #expect(restarted.guardrailRules == assistant.guardrailRules)
        #expect(restarted.tier(for: .deleteTask) == .ask)
    }

    @Test func aNewRuleForTheSameOperationAndScopeReplacesTheOld() throws {
        let assistant = makeAssistant()
        try assistant.loosen(.bulkEditTasks)
        try assistant.tighten(.bulkEditTasks)
        #expect(assistant.guardrailRules == [GuardrailRule(kind: .bulkEditTasks, tier: .ask)])
    }

    @Test func resettingATierPutsTheDefaultBack() throws {
        let assistant = makeAssistant()
        try assistant.tighten(.deleteTask)
        try assistant.resetTier(.deleteTask)
        #expect(assistant.tier(for: .deleteTask) == .auto)
        #expect(assistant.guardrailRules.isEmpty)
    }

    // MARK: Never

    @Test func noOperationTheAssistantCanPerformIsNever() throws {
        let assistant = makeAssistant()
        for kind in OperationKind.allCases {
            #expect(assistant.tier(for: kind) != .never, "\(kind)")
            _ = try? assistant.tighten(kind)
            #expect(assistant.tier(for: kind) != .never, "\(kind)")
        }
    }
}
