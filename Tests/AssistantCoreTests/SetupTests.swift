import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

@Suite struct SetupTests {
    let clock = FakeClock()
    let store = InMemoryStore()

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func days(_ n: Double) {
        clock.advance(minutes: n * 24 * 60)
    }

    // MARK: First run

    @Test func setupRunsOnceAndIsRemembered() throws {
        let assistant = makeAssistant()
        #expect(assistant.needsSetup)

        assistant.finishSetup()

        #expect(!assistant.needsSetup)
        #expect(!makeAssistant().needsSetup)
    }

    @Test func passwordManagersAndBankingAppsAreOfferedForExcludingUnticked() {
        let assistant = makeAssistant()
        let installed = [
            App(bundleID: "com.1password.1password", name: "1Password 8"),
            App(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
            App(bundleID: "uk.co.examplebank.app", name: "Example Bank"),
            App(bundleID: "com.monzo.mac", name: "Monzo"),
            App(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
            App(bundleID: "com.apple.Safari", name: "Safari"),
            App(bundleID: "com.example.otherwise", name: "Otherwise"),  // Words inside words don't count.
            App(bundleID: "com.example.bankruptcy", name: "Bankruptcy Simulator"),
        ]
        #expect(assistant.exclusionOffers(installed: installed) == [
            ExclusionOffer(app: installed[0], why: .passwordManager, ticked: false),
            ExclusionOffer(app: installed[1], why: .passwordManager, ticked: false),
            ExclusionOffer(app: installed[2], why: .banking, ticked: false),
            ExclusionOffer(app: installed[3], why: .banking, ticked: false),
        ])
    }

    @Test func appsAlreadyExcludedAreNotOfferedAgain() throws {
        let assistant = makeAssistant()
        try assistant.exclude(.app("com.1password.1password"))
        let offers = assistant.exclusionOffers(installed: [App(bundleID: "com.1password.1password", name: "1Password")])
        #expect(offers.isEmpty)
    }

    // MARK: Retention

    @Test func deletedTasksArePurgedAfterThirtyDays() throws {
        let assistant = makeAssistant()
        let old = try assistant.quickAdd("Old")
        let recent = try assistant.quickAdd("Recent")
        try assistant.deleteTask(old.id)
        days(20)
        try assistant.deleteTask(recent.id)
        days(10)

        assistant.pruneLogs()

        #expect(assistant.deletedTasks.map(\.title) == ["Recent"])
        #expect(try store.load().tasks.map(\.title) == ["Recent"])
        #expect(makeAssistant().deletedTasks.map(\.title) == ["Recent"])
    }

    @Test func theOperationLogKeepsNinetyDays() throws {
        let assistant = makeAssistant()
        try assistant.quickAdd("Long ago")
        days(60)
        try assistant.quickAdd("Lately")
        days(31)

        assistant.pruneLogs()

        #expect(assistant.operationLog.map(\.summary) == ["Added “Lately”"])
        #expect(try store.load().log.map(\.summary) == ["Added “Lately”"])
    }

    @Test func theAuditLogKeepsThirtyDaysAndNowHistoryNinety() throws {
        let assistant = makeAssistant()
        let call = { (at: Date) in
            APICall(at: at, purpose: .triage, model: "claude-haiku-5-5", inputTokens: 1, outputTokens: 1, contentKind: .emailExcerpt)
        }
        let project = try assistant.declareProject(name: "P", matchers: [])
        assistant.recordAPICall(call(clock.now))
        try store.record(NowBlock(project: project.id, committedTask: nil, start: clock.now, end: clock.now + 60))
        days(29)
        assistant.recordAPICall(call(clock.now))
        try store.record(NowBlock(project: project.id, committedTask: nil, start: clock.now, end: clock.now + 60))
        days(62)

        assistant.pruneLogs()

        let snapshot = try store.load()
        #expect(snapshot.audit.isEmpty)
        #expect(snapshot.history.count == 1)
    }

    @Test func pruningRunsByItselfOnceADay() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Old")
        try assistant.deleteTask(task.id)
        days(31)

        assistant.receive(.userIdle(seconds: 0))

        #expect(assistant.deletedTasks.isEmpty)
    }

    @Test func aPurgedTasksOldEntriesCanNoLongerBeUndone() throws {
        let assistant = makeAssistant()
        let task = try assistant.quickAdd("Old")
        try assistant.deleteTask(task.id)
        let delete = try #require(assistant.operationLog.last)
        days(31)
        assistant.pruneLogs()

        #expect(throws: Assistant.Failure.self) { try assistant.undo(delete.id) }
        #expect(assistant.tasks.isEmpty)
    }
}
