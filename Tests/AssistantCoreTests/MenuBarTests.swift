import Foundation
import Testing
import AssistantCore

@Suite struct MenuBarTests {
    let clock = FakeClock()
    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")

    @Test func showsADashBeforeAnySignal() {
        let assistant = Assistant(clock: clock)
        #expect(assistant.menuBar.title == "—")
    }

    @Test func showsTheAppInCapsAndTheWindowTitle() {
        let assistant = Assistant(clock: clock)
        assistant.receive(.activeWindow(app: code, windowTitle: "Program.cs"))
        #expect(assistant.menuBar.title == "CODE · Program.cs")
    }

    @Test func showsOnlyTheAppWhenTheTitleCannotBeRead() {
        let assistant = Assistant(clock: clock)
        assistant.receive(.activeWindow(app: code, windowTitle: nil))
        #expect(assistant.menuBar.title == "CODE")
    }

    @Test func shortensLongTitlesSoTheMenuBarStaysCompact() {
        let assistant = Assistant(clock: clock)
        assistant.receive(.activeWindow(app: code, windowTitle: "NowTests.swift — todo-agent — ~/Documents/todo-agent [ticket-01]"))
        #expect(assistant.menuBar.title == "CODE · NowTests.swift — todo-agent — ~/D…")
    }

    @Test func dropdownShowsTheFullWindowTitle() {
        let assistant = Assistant(clock: clock)
        assistant.receive(.activeWindow(app: code, windowTitle: "NowTests.swift — todo-agent — ~/Documents/todo-agent [ticket-01]"))
        #expect(assistant.menuBar.nowDetail == "Code — NowTests.swift — todo-agent — ~/Documents/todo-agent [ticket-01]")
    }
}
