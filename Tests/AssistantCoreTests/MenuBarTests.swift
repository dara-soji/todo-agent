import Foundation
import Testing
import AssistantCore

@Suite struct MenuBarTests {
    let clock = FakeClock()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: InMemoryStore(), homeDirectory: "/Users/dara")
    }

    @Test func showsADashBeforeAnySignal() {
        let assistant = makeAssistant()
        #expect(assistant.menuBar.title == "—")
        #expect(assistant.menuBar.marker == .unknown)
    }

    @Test func showsTheMatchedProjectsShortNameInCapsWithItsDot() throws {
        let assistant = makeAssistant()
        try assistant.declareProject(name: "Personal assistant", shortName: "todo", matchers: [.repoPath("~/code/todo-agent")])

        assistant.receive(.activeWindow(app: code, windowTitle: "Program.swift — ~/code/todo-agent [main]"))

        #expect(assistant.menuBar.title == "TODO")
        #expect(assistant.menuBar.marker == .project)
    }

    @Test func dropdownGivesTheProjectItsEvidenceAndTheFullWindow() throws {
        let assistant = makeAssistant()
        try assistant.declareProject(name: "Personal assistant", matchers: [.repoPath("~/code/todo-agent")])

        assistant.receive(.activeWindow(app: code, windowTitle: "NowTests.swift — /Users/dara/code/todo-agent [ticket-02]"))

        #expect(assistant.menuBar.nowDetail == "Personal assistant")
        #expect(assistant.menuBar.evidence == "Matched by ~/code/todo-agent")
        #expect(assistant.menuBar.window == "Code — NowTests.swift — /Users/dara/code/todo-agent [ticket-02]")
    }

    @Test func showsNoProjectWhenNothingMatches() {
        let assistant = makeAssistant()

        assistant.receive(.activeWindow(app: code, windowTitle: nil))

        #expect(assistant.menuBar.title == "NO PROJECT")
        #expect(assistant.menuBar.marker == .noProject)
        #expect(assistant.menuBar.nowDetail == "No Project")
        #expect(assistant.menuBar.evidence == nil)
        #expect(assistant.menuBar.window == "Code")
    }

    @Test func shortensLongShortNamesSoTheMenuBarStaysCompact() throws {
        let assistant = makeAssistant()
        try assistant.declareProject(name: "Spreadsheet of household finances", matchers: [.urlPrefix("docs.google.com/spreadsheets/d/abc")])

        assistant.receive(.activeWindow(app: code, windowTitle: nil, url: URL(string: "https://docs.google.com/spreadsheets/d/abc/edit")))

        #expect(assistant.menuBar.title == "SPREADSHEET OF…")
    }

    @Test func dropdownShowsTheCommittedTaskUnderNow() throws {
        let assistant = makeAssistant()
        #expect(assistant.menuBar.committedTaskTitle == nil)

        try assistant.quickAdd("Write the quick-add palette", start: true)

        #expect(assistant.menuBar.committedTaskTitle == "Write the quick-add palette")
    }

    @Test func flagsWaitingPromptsAndShowsNext() throws {
        let assistant = makeAssistant()
        #expect(assistant.menuBar.nextTitle == "Plan tomorrow")

        let task = try assistant.quickAdd("Avoided")
        #expect(assistant.menuBar.nextTitle == "Avoided")
        #expect(!assistant.menuBar.promptsWaiting)

        for _ in 1...3 { try assistant.skipTask(task.id) }
        #expect(assistant.menuBar.promptsWaiting)
    }
}
