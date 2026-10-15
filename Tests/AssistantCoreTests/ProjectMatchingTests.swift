import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

@Suite struct ProjectMatchingTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")
    let terminal = App(bundleID: "com.apple.Terminal", name: "Terminal")
    let safari = App(bundleID: "com.apple.Safari", name: "Safari")

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
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

    @Test func aRepoPathWithSpacesMatches() throws {
        let assistant = makeAssistant()
        let notes = try assistant.declareProject(name: "Course notes", matchers: [.repoPath("~/Documents/Course Notes")])

        assistant.receive(.activeWindow(app: code, windowTitle: "week1.md — /Users/dara/Documents/Course Notes/week1 [main]"))

        #expect(assistant.now.project == notes.id)
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

        // Reference docs match no Matcher; they are Neutral, so Now is only held (see NeutralTests).
        browse(assistant, "https://learn.microsoft.com/en-us/dotnet/api/system.string")
        #expect(assistant.now.evidence == nil)
    }

    @Test func aURLPrefixMatchesWholeSegmentsOnly() throws {
        let assistant = makeAssistant()
        try assistant.declareProject(name: "todo", matchers: [.urlPrefix("github.com/dara-soji/todo")])

        browse(assistant, "https://github.com/dara-soji/todo-agent")

        #expect(assistant.now.project == nil)
    }

    @Test func aURLPrefixKeepsThePortAndReadsDecodedPaths() throws {
        let assistant = makeAssistant()
        let local = try assistant.declareProject(name: "Local app", matchers: [.urlPrefix("localhost:3000/course notes")])

        browse(assistant, "http://localhost:3000/course%20notes/week1")
        #expect(assistant.now.project == local.id)

        browse(assistant, "http://localhost:4000/course%20notes/week1")
        #expect(assistant.now.project == nil)
    }

    @Test(arguments: ["github.com", "https://github.com/", "learn.microsoft.com", "github.com/*", "github.com/*/*/"])
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

    @Test func aWildcardSegmentIsLessSpecificThanALiteralOne() throws {
        let assistant = makeAssistant()
        let english = try assistant.declareProject(name: "English docs", matchers: [.urlPrefix("learn.microsoft.com/en-us/training")])
        try assistant.declareProject(name: "Learning .NET", matchers: [.urlPrefix("learn.microsoft.com/*/training")])

        browse(assistant, "https://learn.microsoft.com/en-us/training/modules/csharp-call-methods/")

        // `en-us` is more specific than `*` in the same place.
        #expect(assistant.now.project == english.id)
    }

    @Test func aDeeperPathIsMoreSpecificThanALongerName() throws {
        let assistant = makeAssistant()
        let nested = try assistant.declareProject(name: "Nested", matchers: [.repoPath("~/c/a/b")])
        try assistant.declareProject(name: "Long name", matchers: [.repoPath("~/c/a-very-long-folder-name")])

        assistant.receive(.activeWindow(app: code, windowTitle: "~/c/a/b ~/c/a-very-long-folder-name"))

        #expect(assistant.now.project == nested.id)
    }

    @Test func aTieNeitherProjectHasMatchedBeforeGoesToTheFirstByName() throws {
        let assistant = makeAssistant()
        let alpha = try assistant.declareProject(name: "Alpha", matchers: [.repoPath("~/code/shared")])
        try assistant.declareProject(name: "Beta", matchers: [.repoPath("~/code/shared")])

        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/shared"))

        #expect(assistant.now.project == alpha.id)
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

    @Test func aProjectNeedsAName() throws {
        let assistant = makeAssistant()
        #expect(throws: Assistant.Failure.emptyName) {
            try assistant.declareProject(name: "  ", matchers: [])
        }
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [])
        #expect(throws: Assistant.Failure.emptyName) {
            try assistant.renameProject(todo.id, name: "")
        }
    }

    @Test func addingSeveralMatchersAddsAllOrNone() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [])

        #expect(throws: Matcher.Invalid.self) {
            try assistant.addMatchers([.repoPath("~/code/todo-agent"), .urlPrefix("github.com")], to: todo.id)
        }

        #expect(assistant.project(todo.id)?.matchers == [])
    }

    @Test func aChangeThatCannotBeSavedIsNotApplied() throws {
        let assistant = makeAssistant()
        let todo = try assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])
        assistant.receive(.activeWindow(app: code, windowTitle: "~/code/todo-agent"))
        store.failWrites = true

        #expect(throws: InMemoryStore.WriteFailed.self) { try assistant.archiveProject(todo.id) }
        #expect(throws: InMemoryStore.WriteFailed.self) {
            try assistant.declareProject(name: "Other", matchers: [])
        }

        #expect(assistant.project(todo.id)?.status == .active)
        #expect(assistant.now.project == todo.id)
        #expect(assistant.projects.count == 1)
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
