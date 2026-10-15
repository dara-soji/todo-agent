import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

@Suite struct ExclusionTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")
    let bank = App(bundleID: "com.example.bank", name: "My Bank")
    let safari = App(bundleID: "com.apple.Safari", name: "Safari")
    let firefox = App(bundleID: "org.mozilla.firefox", name: "Firefox")
    let securityAgent = App(bundleID: "com.apple.SecurityAgent", name: "SecurityAgent")

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func onTodoAgent(_ assistant: Assistant) throws -> Project {
        let todo = try assistant.declareProject(name: "todo-agent", shortName: "todo", matchers: [.repoPath("~/code/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        return todo
    }

    func tick(_ assistant: Assistant, minutes: Double) {
        clock.advance(minutes: minutes)
        assistant.receive(.userIdle(seconds: 0))
    }

    // MARK: Nothing read

    @Test func anExcludedAppLeavesOnlyExcludedAndTheTime() throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        try assistant.exclude(.app("com.example.bank"))

        assistant.receive(.activeWindow(app: bank, windowTitle: "Balance £1,234", url: URL(string: "https://bank.example/acct/9")))

        let window = try #require(assistant.now.window)
        #expect(window.isExcluded)
        #expect(window.title == nil)
        #expect(window.url == nil)
        #expect(window.app.name == "Excluded")
        #expect(window.app.bundleID.isEmpty)
        #expect(assistant.menuBar.window == "Excluded")
        // Counts as Neutral: Now holds the last Project.
        #expect(assistant.now.project == todo.id)
        #expect(assistant.now.match?.basis == .neutralHold(.excluded))
        #expect(assistant.menuBar.evidence == "Kept while Excluded")
    }

    @Test func anExcludedSiteBeatsAProjectMatcher() throws {
        let assistant = makeAssistant()
        _ = try onTodoAgent(assistant)
        try assistant.declareProject(name: "Bills", matchers: [.urlPrefix("bank.example/acct")])
        try assistant.exclude(.site("bank.example"))

        assistant.receive(.activeWindow(app: safari, windowTitle: "Balance", url: URL(string: "https://www.bank.example/acct/9")))

        #expect(assistant.now.window?.isExcluded == true)
        #expect(assistant.now.evidence == nil)
    }

    @Test(arguments: [
        ("system password prompt", "com.apple.SecurityAgent", "Authenticate", false),
        ("secure text field", "com.microsoft.VSCode", "~/code/todo-agent", true),
        ("Firefox private window", "org.mozilla.firefox", "Search — Mozilla Firefox Private Browsing", false),
    ])
    func theMostSensitiveWindowsAreAlwaysExcluded(_ name: String, bundleID: String, title: String, sensitive: Bool) {
        let assistant = makeAssistant()
        assistant.receive(.activeWindow(app: App(bundleID: bundleID, name: name), windowTitle: title, excluded: sensitive))
        #expect(assistant.now.window?.isExcluded == true, "\(name)")
        #expect(assistant.now.window?.title == nil, "\(name)")
    }

    @Test func passwordAppsAreLeftToDarasListNotAlwaysExcluded() {
        let assistant = makeAssistant()
        assistant.receive(.activeWindow(app: App(bundleID: "com.apple.Passwords", name: "Passwords"), windowTitle: "Passwords"))
        #expect(assistant.now.window?.isExcluded == false)
        #expect(assistant.exclusionToOffer == .app("com.apple.Passwords"))
    }

    @Test func alwaysExcludedOnesAreNotOnTheListAndCannotBeRemoved() throws {
        let assistant = makeAssistant()
        #expect(assistant.exclusions.isEmpty)
        #expect(throws: Assistant.Failure.notExcluded(.app("com.apple.SecurityAgent"))) {
            try assistant.removeExclusion(.app("com.apple.SecurityAgent"))
        }
    }

    // MARK: Neutral for Now and Drift

    @Test func excludedTimeIsNeverDriftNorANewTask() throws {
        let assistant = makeAssistant()
        _ = try onTodoAgent(assistant)
        try assistant.quickAdd("Work", start: true)
        try assistant.exclude(.app("com.example.bank"))
        assistant.receive(.activeWindow(app: bank, windowTitle: "Balance"))

        for _ in 1...8 { tick(assistant, minutes: 5) }  // Well past the 15-minute hold.

        #expect(!assistant.isDrifting)
        #expect(assistant.decisions.isEmpty)
    }

    // MARK: The list

    @Test func addingIsAutoAndKeptRemovingAsksFirst() throws {
        let assistant = makeAssistant()
        try assistant.exclude(.app("com.example.bank"))
        try assistant.exclude(.sender("@bank.example"))
        #expect(assistant.operationLog.last?.kind == .addExclusion)
        #expect(assistant.operationLog.last?.tier == .auto)
        #expect(makeAssistant().exclusions == [.app("com.example.bank"), .sender("@bank.example")])

        guard case .pending = try assistant.removeExclusion(.app("com.example.bank")) else {
            Issue.record("removing an exclusion should ask"); return
        }
        #expect(assistant.exclusions.count == 2)
        try assistant.confirmAsk(try #require(assistant.asks.first).id)
        #expect(assistant.exclusions == [.sender("@bank.example")])
    }

    @Test func undoingAnExclusionAsksLikeRemovingIt() throws {
        let assistant = makeAssistant()
        try assistant.exclude(.app("com.example.bank"))

        guard case .pending = try assistant.undo(try #require(assistant.operationLog.last).id) else {
            Issue.record("undoing an exclusion should ask"); return
        }
        #expect(assistant.exclusions == [.app("com.example.bank")])
    }

    @Test func theLogSaysAnExclusionChangedButNotWhat() throws {
        let assistant = makeAssistant()
        try assistant.exclude(.site("bank.example"))
        #expect(assistant.operationLog.last?.summary == "Added an exclusion")
    }

    @Test func anExcludedWindowCannotBeCorrected() throws {
        let assistant = makeAssistant()
        let todo = try onTodoAgent(assistant)
        try assistant.exclude(.app("com.example.bank"))
        assistant.receive(.activeWindow(app: bank, windowTitle: "Balance"))

        #expect(throws: Assistant.Failure.windowExcluded) { try assistant.correctNow(.project(todo.id)) }
        #expect(throws: Assistant.Failure.windowExcluded) { try assistant.correctNow(.neutral) }
    }

    @Test func removingAnExclusionCannotBeLoosened() {
        let assistant = makeAssistant()
        #expect(throws: Assistant.Failure.cannotLoosen(.removeExclusion)) { try assistant.loosen(.removeExclusion) }
    }

    @Test func excludingTheWindowInFrontScrubsItAtOnce() throws {
        let assistant = makeAssistant()
        assistant.receive(.activeWindow(app: bank, windowTitle: "Balance £1,234"))
        #expect(assistant.exclusionToOffer == .app("com.example.bank"))

        try assistant.exclude(.app("com.example.bank"))

        #expect(assistant.now.window?.title == nil)
        #expect(assistant.now.window?.isExcluded == true)
        #expect(assistant.exclusionToOffer == nil)
    }

    @Test func theOfferIsTheSiteInABrowser() {
        let assistant = makeAssistant()
        assistant.receive(.activeWindow(app: safari, windowTitle: "Balance", url: URL(string: "https://www.bank.example/acct")))
        #expect(assistant.exclusionToOffer == .site("bank.example"))
    }

    @Test func sendersAndNotesFoldersAreExcludedByNameOrDomain() throws {
        let assistant = makeAssistant()
        try assistant.exclude(.sender("@bank.example"))
        try assistant.exclude(.sender("doctor@clinic.example"))
        try assistant.exclude(.notesFolder("Private"))

        #expect(assistant.isExcluded(sender: "Alerts@Bank.example"))
        #expect(assistant.isExcluded(sender: "Bank Alerts <alerts@mail.bank.example>"))
        #expect(!assistant.isExcluded(sender: "someone@notbank.example"))
        #expect(assistant.isExcluded(sender: "doctor@clinic.example"))
        #expect(!assistant.isExcluded(sender: "nurse@clinic.example"))
        #expect(assistant.isExcluded(notesFolder: "Private"))
        #expect(!assistant.isExcluded(notesFolder: "Work"))
    }

    @Test(arguments: [Exclusion.site("bank.example/"), .site(""), .sender("no-at-sign"), .notesFolder(" "), .app("")])
    func malformedExclusionsAreRejected(_ exclusion: Exclusion) {
        let assistant = makeAssistant()
        #expect(throws: Exclusion.Invalid.self) { try assistant.exclude(exclusion) }
    }

    // MARK: Nothing sent

    @Test func noExcludedDataReachesTheStore() throws {
        let assistant = makeAssistant()
        _ = try onTodoAgent(assistant)
        try assistant.exclude(.app("com.example.bank"))
        assistant.receive(.activeWindow(app: bank, windowTitle: "SECRET-TITLE", url: URL(string: "https://secret.example/x")))

        try assistant.quickAdd("Added while excluded", start: true)
        tick(assistant, minutes: 20)
        assistant.closeNowHistory()

        let everything = String(describing: try store.load())
        #expect(!everything.contains("SECRET-TITLE"))
        #expect(!everything.contains("secret.example"))
        #expect(!everything.contains("My Bank"))
    }
}
