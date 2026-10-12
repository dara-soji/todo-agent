import Foundation
import Testing
import AssistantCore

@Suite struct ProjectMatchingTests {
    let clock = FakeClock()
    let store = InMemoryProjectStore()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")
    let terminal = App(bundleID: "com.apple.Terminal", name: "Terminal")
    let safari = App(bundleID: "com.apple.Safari", name: "Safari")

    func makeAssistant() -> Assistant {
        Assistant(clock: clock, projects: store, homeDirectory: "/Users/dara")
    }

    func browse(_ assistant: Assistant, _ url: String) {
        assistant.receive(.activeWindow(app: safari, windowTitle: "Page", url: URL(string: url)))
    }

    // MARK: Repo-path Matchers

    @Test func vsCodeWindowInADeclaredRepoMatchesThatProject() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])

        assistant.receive(.activeWindow(app: code, windowTitle: "Package.swift — /Users/dara/code/todo-agent [main]"))

        #expect(assistant.now.project == todo.id)
        #expect(assistant.now.evidence == .repoPath("~/code/todo-agent"))
    }

    @Test func terminalWorkingDirectoryInsideTheRepoMatchesThatProject() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])

        assistant.receive(.activeWindow(app: terminal, windowTitle: "dara — ~/code/todo-agent/Sources — -zsh — 80×24"))

        #expect(assistant.now.project == todo.id)
    }

    @Test func aSiblingFolderSharingTheNamePrefixDoesNotMatch() throws {
        let assistant = makeAssistant()
        try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])

        assistant.receive(.activeWindow(app: code, windowTitle: "README.md — /Users/dara/code/todo-agent-old"))

        #expect(assistant.now.project == nil)
    }

    @Test func anAbsoluteRepoPathUnderHomeIsStoredWithTilde() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("/Users/dara/code/todo-agent/")])

        #expect(todo.matchers == [.repoPath("~/code/todo-agent")])
    }

    @Test func aRelativeRepoPathIsRejected() {
        let assistant = makeAssistant()
        #expect(throws: Matcher.Invalid.relativePath("code/todo-agent")) {
            try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("code/todo-agent")])
        }
    }

    // MARK: URL-prefix Matchers

    @Test func urlPrefixMatchesIgnoringSchemeAndWWW() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.urlPrefix("https://github.com/dara-soji/todo-agent")])

        browse(assistant, "https://www.github.com/dara-soji/todo-agent/issues/3")

        #expect(assistant.now.project == todo.id)
        #expect(assistant.now.evidence == .urlPrefix("github.com/dara-soji/todo-agent"))
    }

    @Test func starInAURLPrefixStandsForOnePathSegment() throws {
        let assistant = makeAssistant()
        let dotnet = try assistant.declareProject(name: "Learning .NET", matchers: [.urlPrefix("learn.microsoft.com/*/training/")])

        browse(assistant, "https://learn.microsoft.com/en-us/training/modules/csharp-call-methods/")
        #expect(assistant.now.project == dotnet.id)

        browse(assistant, "https://learn.microsoft.com/en-us/dotnet/api/system.string")
        #expect(assistant.now.project == nil)
    }

    @Test(arguments: ["github.com", "https://github.com/", "learn.microsoft.com"])
    func bareDomainURLPrefixesAreRejected(prefix: String) {
        let assistant = makeAssistant()
        #expect(throws: Matcher.Invalid.self) {
            try assistant.declareProject(name: "Too broad", matchers: [.urlPrefix(prefix)])
        }
        #expect(assistant.projects.isEmpty)
    }

    // MARK: Conflicts

    @Test func theMostSpecificMatcherWins() throws {
        let assistant = makeAssistant()
        try assistant.declareProject(name: "All code", matchers: [.repoPath("~/code")])
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])

        assistant.receive(.activeWindow(app: code, windowTitle: "Assistant.swift — ~/code/todo-agent"))

        #expect(assistant.now.project == todo.id)
    }

    @Test func equallySpecificMatchersGoToTheMostRecentlyMatchedProject() throws {
        let assistant = makeAssistant()
        let course = try assistant.declareProject(name: "Course", matchers: [.repoPath("~/code/shared"), .repoPath("~/code/course")])
        let work = try assistant.declareProject(name: "Work", matchers: [.repoPath("~/code/shared"), .repoPath("~/code/work")])

        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/work"))
        clock.advance(minutes: 1)
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/shared"))
        #expect(assistant.now.project == work.id)

        clock.advance(minutes: 1)
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/course"))
        clock.advance(minutes: 1)
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/shared"))
        #expect(assistant.now.project == course.id)
    }

    // MARK: Lifecycle and edits

    @Test func archivedProjectsMatchNothingUntilRestored() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))

        try assistant.archiveProject(todo.id)
        #expect(assistant.now.project == nil)
        #expect(assistant.project(todo.id)?.status == .archived)

        try assistant.restoreProject(todo.id)
        #expect(assistant.now.project == todo.id)
    }

    @Test func addingAndRemovingAMatcherChangesNowStraightAway() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        #expect(assistant.now.project == nil)

        try assistant.addMatcher(.repoPath("/Users/dara/code/todo-agent"), to: todo.id)
        #expect(assistant.now.project == todo.id)

        try assistant.removeMatcher(.repoPath("~/code/todo-agent"), from: todo.id)
        #expect(assistant.now.project == nil)
    }

    @Test func renamingChangesTheNameAndShortName() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [])

        try assistant.renameProject(todo.id, name: "Personal assistant", shortName: "PA")

        #expect(assistant.project(todo.id)?.name == "Personal assistant")
        #expect(assistant.project(todo.id)?.shortName == "PA")
    }

    @Test func editingAnUnknownProjectFails() {
        let assistant = makeAssistant()
        let missing = Project.ID()
        #expect(throws: Assistant.Failure.unknownProject(missing)) {
            try assistant.archiveProject(missing)
        }
    }

    @Test func projectsSurviveARestart() throws {
        let todo = try makeAssistant().declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])

        let restarted = makeAssistant()
        restarted.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))

        #expect(restarted.projects.map(\.id) == [todo.id])
        #expect(restarted.now.project == todo.id)
    }
}
