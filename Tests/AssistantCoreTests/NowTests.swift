import Foundation
import Testing
import AssistantCore

@Suite struct NowTests {
    let clock = FakeClock()

    func makeAssistant() -> Assistant {
        Assistant(clock: clock, projects: InMemoryProjectStore(), homeDirectory: "/Users/dara")
    }

    @Test func nowIsUnknownBeforeAnySignal() {
        let assistant = makeAssistant()
        #expect(assistant.now == .unknown)
    }

    @Test func activeWindowSignalSetsNowToTheActiveAppAndWindowTitle() {
        let assistant = makeAssistant()

        assistant.receive(.activeWindow(app: code, windowTitle: "Package.swift — todo-agent [main]"))

        #expect(assistant.now.window == ActiveWindow(app: code, title: "Package.swift — todo-agent [main]"))
        #expect(assistant.now.since == clock.now)
    }

    @Test func repeatedSignalForTheSameWindowKeepsWhenDaraArrived() {
        let assistant = makeAssistant()
        let arrived = clock.now

        assistant.receive(.activeWindow(app: code, windowTitle: "Program.cs — dotnet-exercises"))
        clock.advance(minutes: 3)
        assistant.receive(.activeWindow(app: code, windowTitle: "Program.cs — dotnet-exercises"))

        #expect(assistant.now.since == arrived)
    }

    @Test func movingToAnotherWindowStartsAFreshNow() {
        let assistant = makeAssistant()

        assistant.receive(.activeWindow(app: code, windowTitle: "Program.cs — dotnet-exercises"))
        clock.advance(minutes: 3)
        assistant.receive(.activeWindow(app: safari, windowTitle: nil))

        #expect(assistant.now.window == ActiveWindow(app: safari, title: nil))
        #expect(assistant.now.since == clock.now)
    }

    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")
    let safari = App(bundleID: "com.apple.Safari", name: "Safari")
}
