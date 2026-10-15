import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

/// A scripted Sonnet: records what reached it and answers with a chosen label and reason.
@MainActor
final class FakeTieBreaker: TieBreaker {
    var seen: [TieBreakRequest] = []
    var attempts = 0
    var choose: ([String]) -> (String, String) = { labels in (labels.last!, "Fresh in your mind") }
    var fails = false

    func breakTie(_ request: TieBreakRequest) async throws -> TieBreakAnswer {
        attempts += 1
        if fails { throw URLError(.timedOut) }
        seen.append(request)
        let (choice, reason) = choose(request.candidates.map(\.label))
        let call = APICall(
            at: Date(timeIntervalSince1970: 0), purpose: .nextTieBreak, model: "claude-sonnet-5-5",
            inputTokens: 300, outputTokens: 40, contentKind: .taskTitles)
        return TieBreakAnswer(choice: choice, reason: reason, call: call)
    }
}

@MainActor
@Suite struct TieBreakTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let tieBreaker = FakeTieBreaker()

    func makeAssistant() -> Assistant {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara", calendar: utc)
    }

    func runner(_ assistant: Assistant) -> TieBreakRunner {
        TieBreakRunner(assistant: assistant, tieBreaker: tieBreaker)
    }

    /// Two Tasks the rule scores the same; only age separates them.
    func tied(_ assistant: Assistant) throws -> (older: Task, newer: Task) {
        let older = try assistant.quickAdd("Read chapter 4")
        clock.advance(minutes: 1)
        let newer = try assistant.quickAdd("Write the summary")
        return (older, newer)
    }

    @Test func aTieIsBrokenBySonnetWithItsReason() async throws {
        let assistant = makeAssistant()
        let (older, newer) = try tied(assistant)
        #expect(assistant.next.task == older.id)  // The rule's own pick until Sonnet answers.

        await runner(assistant).run()

        #expect(assistant.next.task == newer.id)
        #expect(assistant.menuBar.nextReason == "Fresh in your mind")
        let request = try #require(tieBreaker.seen.first)
        #expect(Set(request.candidates.map(\.title)) == ["Read chapter 4", "Write the summary"])
        #expect(try store.load().audit.map(\.purpose) == [.nextTieBreak])
    }

    @Test func noTieNoCall() async throws {
        let assistant = makeAssistant()
        try assistant.quickAdd("Only one")
        await runner(assistant).run()

        try assistant.addTask(TaskDraft(title: "Due soon", deadline: clock.now + 3600))
        await runner(assistant).run()

        #expect(tieBreaker.seen.isEmpty)
    }

    @Test func onlyTasksTiedAtTheTopAreSent() async throws {
        let assistant = makeAssistant()
        try assistant.addTask(TaskDraft(title: "Deep A", kind: .deep))
        clock.advance(minutes: 1)
        try assistant.addTask(TaskDraft(title: "Deep B", kind: .deep))
        try assistant.addTask(TaskDraft(title: "Shallow one", kind: .shallow))  // Morning: ranks below the deep pair.

        await runner(assistant).run()

        #expect(tieBreaker.seen.first?.candidates.map(\.title) == ["Deep A", "Deep B"])
    }

    @Test func atMostFiveCandidatesAreSent() async throws {
        let assistant = makeAssistant()
        for index in 1...8 {
            try assistant.quickAdd("Task \(index)")
            clock.advance(minutes: 1)
        }
        await runner(assistant).run()
        #expect(tieBreaker.seen.first?.candidates.count == 5)
    }

    @Test func anAnswerOutsideTheCandidatesIsIgnored() async throws {
        let assistant = makeAssistant()
        let (older, _) = try tied(assistant)
        tieBreaker.choose = { _ in ("Something else", "Because") }

        await runner(assistant).run()

        #expect(assistant.next.task == older.id)
        #expect(assistant.menuBar.nextReason == "Oldest open Task")
    }

    @Test func whenTheAPIIsUnavailableTheRulesPickStandsAndItIsTriedAgainLater() async throws {
        let assistant = makeAssistant()
        let (older, newer) = try tied(assistant)
        tieBreaker.fails = true

        await runner(assistant).run()
        #expect(assistant.next.task == older.id)
        clock.advance(minutes: 5)
        await runner(assistant).run()
        #expect(tieBreaker.attempts == 1)

        tieBreaker.fails = false
        clock.advance(minutes: 6)
        await runner(assistant).run()
        #expect(assistant.next.task == newer.id)
    }

    @Test func theAnswerIsKeptForTheSameTieAndAskedAgainWhenTheTieChanges() async throws {
        let assistant = makeAssistant()
        _ = try tied(assistant)
        await runner(assistant).run()
        await runner(assistant).run()
        #expect(tieBreaker.seen.count == 1)

        clock.advance(minutes: 1)
        try assistant.quickAdd("A third, just as good")
        await runner(assistant).run()
        #expect(tieBreaker.seen.count == 2)
    }

    @Test func theReasonIsOneShortLine() async throws {
        let assistant = makeAssistant()
        _ = try tied(assistant)
        tieBreaker.choose = { labels in (labels[0], "Line one\nLine two " + String(repeating: "very long ", count: 20)) }

        await runner(assistant).run()

        let reason = try #require(assistant.menuBar.nextReason)
        #expect(!reason.contains("\n"))
        #expect(reason.count <= 80)
    }

    @Test func anInterruptedTaskComingBackIsNeverPutToSonnet() async throws {
        let assistant = makeAssistant()
        let interrupted = try assistant.quickAdd("Refactor", start: true)
        let interruption = try assistant.quickAdd("Landlord", start: true)
        try assistant.completeTask(interruption.id)
        _ = try tied(assistant)

        await runner(assistant).run()

        #expect(tieBreaker.seen.isEmpty)
        #expect(assistant.next.task == interrupted.id)
    }
}
