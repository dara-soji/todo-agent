import Foundation
import Testing
import AssistantCore

/// The fake clock starts on Saturday 3 October 2026 at 04:00 UTC: morning.
@Suite struct NextTests {
    let clock = FakeClock()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")

    func makeAssistant() -> Assistant {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return try! Assistant(clock: clock, store: InMemoryStore(), homeDirectory: "/Users/dara", calendar: utc)
    }

    func add(_ assistant: Assistant, _ title: String, effort: Task.Effort? = nil, kind: Task.Kind? = nil,
             dueIn hours: Double? = nil, project: Project.ID? = nil) throws -> Task {
        try assistant.addTask(TaskDraft(
            title: title, deadline: hours.map { clock.now + $0 * 60 * 60 }, project: project, effort: effort, kind: kind))
    }

    func meeting(startsIn minutes: Double, lasts: Double = 30) -> CalendarEvent {
        CalendarEvent(title: "Meeting", start: clock.now + minutes * 60, end: clock.now + (minutes + lasts) * 60)
    }

    // MARK: Always one Next

    @Test func withNothingOpenNextIsPlanTomorrow() {
        #expect(makeAssistant().next == .planTomorrow)
    }

    @Test func theOnlyOpenTaskIsNext() throws {
        let assistant = makeAssistant()
        let task = try add(assistant, "Only one")
        #expect(assistant.next.task == task.id)
    }

    @Test func committedSnoozedFinishedAndDeletedTasksAreNeverNext() throws {
        let assistant = makeAssistant()
        let committed = try assistant.quickAdd("Committed", start: true)
        try assistant.snoozeTask(try add(assistant, "Snoozed").id, until: nil, note: "Sam")
        try assistant.completeTask(try add(assistant, "Done").id)
        try assistant.dropTask(try add(assistant, "Dropped").id)
        try assistant.deleteTask(try add(assistant, "Deleted").id)

        #expect(assistant.next == .planTomorrow)
        #expect(assistant.committedTask?.id == committed.id)
    }

    // MARK: Hard filters

    @Test func aTaskThatFitsTheNextFreeBlockBeatsOneThatDoesnt() throws {
        let assistant = makeAssistant()
        try add(assistant, "Long", effort: .large)
        let short = try add(assistant, "Short", effort: .small)
        assistant.receive(.calendar(events: [meeting(startsIn: 45)]))

        #expect(assistant.next.task == short.id)
        #expect(assistant.next.wontFitBefore == nil)
    }

    @Test func whenNothingFitsTheBestTaskIsFlaggedWontFitBeforeTheMeeting() throws {
        let assistant = makeAssistant()
        let long = try add(assistant, "Long", effort: .large)
        assistant.receive(.calendar(events: [meeting(startsIn: 20)]))

        #expect(assistant.next.task == long.id)
        #expect(assistant.next.wontFitBefore == clock.now + 20 * 60)
        #expect(assistant.menuBar.nextReason == "Oldest open Task · won't fit before 04:20")
    }

    @Test func aTaskDueWithinADayIsNextEvenIfItWontFit() throws {
        let assistant = makeAssistant()
        let overdue = try add(assistant, "Overdue report", effort: .large, dueIn: -1)
        try add(assistant, "Quick tidy", effort: .small)
        assistant.receive(.calendar(events: [meeting(startsIn: 45)]))

        #expect(assistant.next.task == overdue.id)
        #expect(assistant.menuBar.nextReason == "Overdue · won't fit before 04:45")
    }

    @Test func meetingsAfterTodayDontLimitTheFreeBlock() throws {
        let assistant = makeAssistant()
        try add(assistant, "Long", effort: .large)
        clock.advance(minutes: 19 * 60)  // 23:00
        assistant.receive(.calendar(events: [meeting(startsIn: 90)]))  // 00:30 tomorrow
        #expect(assistant.next.wontFitBefore == nil)
    }

    @Test func theFreeBlockStartsWhenAMeetingUnderWayEnds() throws {
        let assistant = makeAssistant()
        try add(assistant, "Medium", effort: .medium)
        // Under way until 05:30, then free until 06:30: 60 minutes, not enough for 90.
        assistant.receive(.calendar(events: [meeting(startsIn: -10, lasts: 100), meeting(startsIn: 150)]))

        #expect(assistant.next.wontFitBefore == clock.now + 150 * 60)
    }

    @Test func aTaskWithUnknownEffortIsAssumedToFit() throws {
        let assistant = makeAssistant()
        let unknown = try add(assistant, "Unknown effort")
        assistant.receive(.calendar(events: [meeting(startsIn: 5)]))
        #expect(assistant.next.wontFitBefore == nil)
        #expect(assistant.next.task == unknown.id)
    }

    // MARK: Score order

    @Test func anUrgentDeadlineBeatsContinuingTheCurrentProject() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        try add(assistant, "Same Project", project: todo.id)
        let urgent = try add(assistant, "Tax return", dueIn: 3)

        #expect(assistant.next.task == urgent.id)
        #expect(assistant.menuBar.nextReason == "Due today")
    }

    @Test func theEarlierDeadlineWinsAmongUrgentTasks() throws {
        let assistant = makeAssistant()
        try add(assistant, "Later", dueIn: 20)
        let sooner = try add(assistant, "Sooner", dueIn: 5)
        #expect(assistant.next.task == sooner.id)
    }

    @Test func aDeadlineThisWeekBeatsNoDeadline() throws {
        let assistant = makeAssistant()
        try add(assistant, "Whenever")
        let thisWeek = try add(assistant, "Thursday", dueIn: 5 * 24)
        #expect(assistant.next.task == thisWeek.id)
        #expect(assistant.menuBar.nextReason == "Due Thu")
    }

    @Test func aFarDeadlineCountsNoMoreThanNone() throws {
        let assistant = makeAssistant()
        let older = try add(assistant, "Older, no deadline")
        clock.advance(minutes: 1)
        try add(assistant, "Due next month", dueIn: 30 * 24)
        #expect(assistant.next.task == older.id)
    }

    @Test func continuingTheCurrentProjectBeatsTimeOfDay() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", shortName: "todo", matchers: [.repoPath("~/code/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        try add(assistant, "Deep, elsewhere", kind: .deep)
        let continues = try add(assistant, "Shallow, same Project", kind: .shallow, project: todo.id)

        #expect(assistant.next.task == continues.id)
        #expect(assistant.menuBar.nextReason == "Continues TODO")
    }

    @Test func deepWorkInTheMorningShallowInTheAfternoon() throws {
        let assistant = makeAssistant()
        let shallow = try add(assistant, "Inbox zero", kind: .shallow)
        let deep = try add(assistant, "Design the schema", kind: .deep)

        #expect(assistant.next.task == deep.id)
        #expect(assistant.menuBar.nextReason == "Deep work while it's morning")

        clock.advance(minutes: 10 * 60)  // 14:00
        #expect(assistant.next.task == shallow.id)
        #expect(assistant.menuBar.nextReason == "A shallow one for the afternoon")
    }

    @Test func otherwiseTheOldestTaskComesFirst() throws {
        let assistant = makeAssistant()
        let older = try add(assistant, "Older")
        clock.advance(minutes: 5)
        try add(assistant, "Newer")
        #expect(assistant.next.task == older.id)
        #expect(assistant.menuBar.nextReason == "Oldest open Task")
    }

    @Test func aSkippedInterruptedTaskWaitsLikeAnyOther() throws {
        let assistant = makeAssistant()
        let other = try add(assistant, "Other")
        let interrupted = try assistant.quickAdd("Refactor", start: true)
        let interruption = try assistant.quickAdd("Landlord", start: true)
        try assistant.completeTask(interruption.id)

        try assistant.skipTask(interrupted.id)

        #expect(assistant.next.task == other.id)
    }

    @Test func theInterruptedTaskComesBackFirst() throws {
        let assistant = makeAssistant()
        try add(assistant, "Urgent but new", dueIn: 1)
        let interrupted = try assistant.quickAdd("Refactor", start: true)
        let interruption = try assistant.quickAdd("Landlord", start: true)
        try assistant.completeTask(interruption.id)

        #expect(assistant.next.task == interrupted.id)
        #expect(assistant.menuBar.nextReason == "Back to what you were doing before the interruption")
    }

    // MARK: Start, Skip, Snooze

    @Test func startCommitsNext() throws {
        let assistant = makeAssistant()
        let task = try add(assistant, "Do it")
        try assistant.startNext()
        #expect(assistant.committedTask?.id == task.id)
        #expect(assistant.next == .planTomorrow)
    }

    @Test func skipDemotesTheTaskForTwoHours() throws {
        let assistant = makeAssistant()
        let first = try add(assistant, "First")
        clock.advance(minutes: 1)
        let second = try add(assistant, "Second")

        try assistant.skipTask(first.id)
        #expect(assistant.next.task == second.id)
        #expect(assistant.operationLog.last?.kind == .skipTask)

        clock.advance(minutes: 119)
        #expect(assistant.next.task == second.id)
        clock.advance(minutes: 1)
        #expect(assistant.next.task == first.id)
    }

    @Test func aSkippedTaskIsStillNextIfItIsTheOnlyOne() throws {
        let assistant = makeAssistant()
        let only = try add(assistant, "Only")
        try assistant.skipTask(only.id)
        #expect(assistant.next.task == only.id)
    }

    @Test func theThirdSkipAsksWhatToDoWithTheTask() throws {
        let assistant = makeAssistant()
        let task = try add(assistant, "Avoided")
        try assistant.skipTask(task.id)
        try assistant.skipTask(task.id)
        #expect(assistant.decisions.isEmpty)

        try assistant.skipTask(task.id)

        #expect(assistant.decisions == [.skippedThreeTimes(task.id)])
    }

    @Test func keepingASkippedTaskClearsTheDecisionButItStillSitsOutItsSkip() throws {
        let assistant = makeAssistant()
        let task = try add(assistant, "Avoided")
        let other = try add(assistant, "Other")
        for _ in 1...3 { try assistant.skipTask(task.id) }

        try assistant.keepTask(task.id)

        #expect(assistant.decisions.isEmpty)
        #expect(assistant.next.task == other.id)
        try assistant.skipTask(task.id)
        #expect(assistant.decisions.isEmpty)
    }

    @Test func onlyAnOpenTaskCanBeSkipped() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Committed", start: true)
        #expect(throws: Assistant.Failure.notOpen(task.id)) { try assistant.skipTask(task.id) }
    }

    @Test func snoozingForAnHourWakesItAnHourLater() throws {
        let assistant = makeAssistant()
        let task = try add(assistant, "Later")
        try assistant.snoozeTask(task.id, forHours: 1)
        #expect(assistant.task(task.id)?.status == .snoozed(until: clock.now + 60 * 60, note: nil))
    }

    @Test func snoozingTillTomorrowWakesItAtNineTheNextMorning() throws {
        let assistant = makeAssistant()
        let task = try add(assistant, "Avoided")
        for _ in 1...3 { try assistant.skipTask(task.id) }

        try assistant.snoozeTillTomorrow(task.id)

        let nine = Date(timeIntervalSince1970: 1_791_000_000 + (24 + 5) * 60 * 60)  // Sunday 09:00 UTC
        #expect(assistant.task(task.id)?.status == .snoozed(until: nine, note: nil))
        #expect(assistant.decisions.isEmpty)

        clock.advance(minutes: 30 * 60)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.task(task.id)?.status == .open)
        #expect(assistant.decisions.isEmpty)
    }

    @Test func droppingASkippedTaskClearsThePrompt() throws {
        let assistant = makeAssistant()
        let task = try add(assistant, "Avoided")
        for _ in 1...3 { try assistant.skipTask(task.id) }

        try assistant.dropTask(task.id)

        #expect(assistant.decisions.isEmpty)
    }

    // MARK: Stored Tasks

    @Test func aTaskStoredBeforeSkipsWereTrackedStillLoads() throws {
        let json = """
            {"id":{"rawValue":"6F9619FF-8B86-D011-B42D-00C04FC964FF"},"title":"Old","source":"byHand",
             "status":{"open":{}},"created":0,"resumeAfterInterruption":false}
            """
        let task = try JSONDecoder().decode(Task.self, from: Data(json.utf8))
        #expect(task.title == "Old")
        #expect(task.skipCount == 0)
        #expect(task.skippedUntil == nil)
    }
}
