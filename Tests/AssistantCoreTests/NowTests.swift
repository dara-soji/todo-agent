import Foundation
import Testing
import AssistantCore

@Suite struct NowTests {
    let clock = FakeClock()

    @Test func nowIsUnknownBeforeAnySignal() {
        let assistant = Assistant(clock: clock)
        #expect(assistant.now == .unknown)
    }

    @Test func focusSignalSetsNowToTheActiveAppAndWindowTitle() {
        let assistant = Assistant(clock: clock)
        let code = App(bundleID: "com.microsoft.VSCode", name: "Code")

        assistant.receive(.focus(app: code, windowTitle: "Package.swift — todo-agent [main]"))

        #expect(assistant.now == .window(app: code, title: "Package.swift — todo-agent [main]", since: clock.now))
    }

    @Test func repeatedSignalForTheSameWindowKeepsWhenDaraArrived() {
        let assistant = Assistant(clock: clock)
        let arrived = clock.now

        assistant.receive(.focus(app: code, windowTitle: "Program.cs — dotnet-exercises"))
        clock.advance(minutes: 3)
        assistant.receive(.focus(app: code, windowTitle: "Program.cs — dotnet-exercises"))

        #expect(assistant.now == .window(app: code, title: "Program.cs — dotnet-exercises", since: arrived))
    }

    @Test func movingToAnotherWindowStartsAFreshNow() {
        let assistant = Assistant(clock: clock)

        assistant.receive(.focus(app: code, windowTitle: "Program.cs — dotnet-exercises"))
        clock.advance(minutes: 3)
        assistant.receive(.focus(app: safari, windowTitle: nil))

        #expect(assistant.now == .window(app: safari, title: nil, since: clock.now))
    }

    let code = App(bundleID: "com.microsoft.VSCode", name: "Code")
    let safari = App(bundleID: "com.apple.Safari", name: "Safari")
}
