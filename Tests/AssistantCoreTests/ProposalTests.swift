import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

@Suite struct ProposalTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")
    let chrome = App(bundleID: "com.google.Chrome", name: "Chrome")

    func makeAssistant() -> Assistant {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara", calendar: utc)
    }

    func work(_ assistant: Assistant, in title: String, url: String? = nil, minutes: Double = 10) {
        assistant.receive(.activeWindow(app: url == nil ? code : chrome, windowTitle: title, url: url.flatMap(URL.init(string:))))
        clock.advance(minutes: minutes)
        assistant.receive(.userIdle(seconds: 0))
    }

    /// The proposals and archive suggestions waiting, without other Decisions.
    func proposals(_ assistant: Assistant) -> [Decision] {
        assistant.decisions.filter {
            switch $0 {
            case .newProject, .archiveStale: true
            default: false
            }
        }
    }

    /// A night away, then back the next day.
    func nextDay(_ assistant: Assistant? = nil) {
        clock.advance(minutes: 24 * 60)
        assistant?.receive(.userIdle(seconds: 8 * 3600))
        assistant?.receive(.userIdle(seconds: 0))
    }

    // MARK: Setup

    @Test func setupProposesProjectsFromReposAndSheetsAndDaraPrunesOnce() throws {
        let assistant = makeAssistant()
        try assistant.registerSheet("1AbC_dEf-123456789xyzABCDEFghijkl", name: "Course plan")
        _ = try assistant.declareProject(name: "Known", matchers: [.repoPath("~/code/known")])

        let proposals = assistant.setupProposals(repoPaths: ["/Users/dara/code/todo-agent", "/Users/dara/code/known", "/Users/dara/code/dotnet-course"])

        #expect(proposals.map(\.name) == ["todo-agent", "dotnet-course", "Course plan"])
        #expect(proposals.map(\.matcher) == [
            .repoPath("~/code/todo-agent"), .repoPath("~/code/dotnet-course"), .sheetID("1AbC_dEf-123456789xyzABCDEFghijkl"),
        ])

        try assistant.addProposedProjects(proposals.filter { $0.name != "dotnet-course" })

        #expect(Set(assistant.projects.map(\.name)) == ["Known", "todo-agent", "Course plan"])
        #expect(assistant.operationLog.suffix(2).allSatisfy { $0.kind == .declareProject && $0.tier == .auto && $0.startedBy == .dara })
        #expect(assistant.setupProposals(repoPaths: ["/Users/dara/code/todo-agent"]).isEmpty)
    }

    // MARK: Seen on two days

    @Test func theSameUnmatchedKeyOnTwoSeparateDaysProposesANewProject() throws {
        let assistant = makeAssistant()
        work(assistant, in: "~/code/side-project — main.cs")
        #expect(proposals(assistant).isEmpty)
        work(assistant, in: "~/code/side-project — notes.md")
        #expect(proposals(assistant).isEmpty)  // Still the same day.

        nextDay(assistant)
        work(assistant, in: "~/code/side-project — main.cs")

        let proposal = ProjectProposal(name: "side-project", matcher: .repoPath("~/code/side-project"), days: 2)
        #expect(proposals(assistant) == [.newProject(proposal)])
        #expect(proposals(makeAssistant()) == [.newProject(proposal)])
    }

    @Test func addingTheProposalDeclaresTheProjectAndNowMatchesIt() throws {
        let assistant = makeAssistant()
        work(assistant, in: "~/code/side-project")
        nextDay(assistant)
        work(assistant, in: "~/code/side-project")
        guard case let .newProject(proposal)? = proposals(assistant).first else { Issue.record("no proposal"); return }

        try assistant.addProposedProjects([proposal])

        #expect(assistant.now.project == assistant.projects.first?.id)
        #expect(proposals(assistant).isEmpty)
        #expect(assistant.operationLog.last?.tier == .auto)
    }

    @Test func dismissingTheProposalKeepsItAwayForGood() throws {
        let assistant = makeAssistant()
        work(assistant, in: "~/code/side-project")
        nextDay(assistant)
        work(assistant, in: "~/code/side-project")
        guard case let .newProject(proposal)? = proposals(assistant).first else { Issue.record("no proposal"); return }

        assistant.dismissProposal(proposal)
        nextDay(assistant)
        work(assistant, in: "~/code/side-project")

        #expect(proposals(assistant).isEmpty)
        #expect(proposals(makeAssistant()).isEmpty)
    }

    @Test func sitesAndSheetsAreProposedTooButNotExcludedOrNeutralOnes() throws {
        let assistant = makeAssistant()
        try assistant.exclude(.site("bank.example"))
        for _ in 1...2 {
            work(assistant, in: "Course", url: "https://www.udemy.com/course/csharp-basics/learn/lecture/1")
            work(assistant, in: "Bank", url: "https://bank.example/accounts/1")
            work(assistant, in: "A question", url: "https://stackoverflow.com/questions/1/how")  // Neutral by default.
            nextDay(assistant)
        }

        #expect(proposals(assistant) == [
            .newProject(ProjectProposal(name: "csharp-basics", matcher: .urlPrefix("udemy.com/course/csharp-basics"), days: 2)),
        ])
        #expect(!String(describing: try store.load()).contains("bank.example/accounts"))
    }

    @Test func aSheetOpenOnTwoDaysIsProposedByItsId() throws {
        let assistant = makeAssistant()
        for _ in 1...2 {
            work(assistant, in: "Budget - Google Sheets", url: "https://docs.google.com/spreadsheets/d/1AbC_dEf-123456789xyzABCDEFghijkl/edit")
            nextDay(assistant)
        }
        guard case let .newProject(proposal)? = proposals(assistant).first else { Issue.record("no proposal"); return }
        #expect(proposal.matcher == .sheetID("1AbC_dEf-123456789xyzABCDEFghijkl"))
    }

    @Test func briefVisitsDoNotCount() throws {
        let assistant = makeAssistant()
        for _ in 1...3 {
            work(assistant, in: "~/code/side-project", minutes: 1)
            nextDay(assistant)
        }
        #expect(proposals(assistant).isEmpty)
    }

    // MARK: Archiving

    @Test func aProjectUnmatchedForThirtyDaysIsSuggestedForArchiving() throws {
        let assistant = makeAssistant()
        let old = try assistant.declareProject(name: "Old course", matchers: [.repoPath("~/code/old")])
        let busy = try assistant.declareProject(name: "Busy", matchers: [.repoPath("~/code/busy")])
        work(assistant, in: "~/code/old")
        work(assistant, in: "~/code/busy", minutes: 0)  // Off it before the day ends.

        for _ in 1...29 {
            nextDay(assistant)
            work(assistant, in: "~/code/busy")
        }
        #expect(proposals(assistant).isEmpty)

        nextDay(assistant)
        work(assistant, in: "~/code/busy")
        #expect(proposals(assistant) == [.archiveStale(old.id)])
        _ = busy
    }

    @Test func keepWaitsAnotherThirtyDaysAndArchiveArchives() throws {
        let assistant = makeAssistant()
        let old = try assistant.declareProject(name: "Old course", matchers: [.repoPath("~/code/old")])
        clock.advance(minutes: 31 * 24 * 60)
        assistant.receive(.userIdle(seconds: 0))
        #expect(proposals(assistant) == [.archiveStale(old.id)])

        assistant.keepProject(old.id)
        #expect(proposals(assistant).isEmpty)
        #expect(proposals(makeAssistant()).isEmpty)

        clock.advance(minutes: 31 * 24 * 60)
        assistant.receive(.userIdle(seconds: 0))
        try assistant.archiveProject(old.id)
        #expect(assistant.project(old.id)?.status == .archived)
        #expect(proposals(assistant).isEmpty)
    }

    // MARK: Who asked

    @Test func assistantProposedProjectChangesAskAndDaraRequestedOnesRun() throws {
        let assistant = makeAssistant()
        let project = try assistant.declareProject(name: "Mine", matchers: [], by: .claudeCode)
        #expect(assistant.operationLog.last?.tier == .auto)

        guard case .pending = try assistant.addMatchers([.repoPath("~/code/mine")], to: project.id, by: .claudeCode, proposed: true)
        else { Issue.record("a proposed Matcher should ask"); return }
        guard case .pending = try assistant.archiveProject(project.id, by: .claudeCode, proposed: true)
        else { Issue.record("a proposed archive should ask"); return }
        #expect(assistant.project(project.id)?.matchers.isEmpty == true)

        let proposed = try assistant.declareProjectProposed(name: "Theirs", matchers: [], by: .claudeCode)
        guard case .pending = proposed.outcome else { Issue.record("a proposed Project should ask"); return }
        #expect(assistant.projects.count == 1)
    }
}
