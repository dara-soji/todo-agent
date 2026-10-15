import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

/// A fake Gmail: hands out messages after the cursor it is given.
@MainActor
final class FakeMailSource: MailSource {
    var messages: [EmailMessage] = []
    var cursorsAskedFor: [String?] = []
    var nextCursor = "h1"
    var fails = false

    func fetchNew(after cursor: String?) async throws -> MailBatch {
        cursorsAskedFor.append(cursor)
        if fails { throw URLError(.notConnectedToInternet) }
        defer { messages = [] }
        return MailBatch(messages: messages, cursor: nextCursor)
    }
}

/// A scripted Haiku: records exactly what reached it.
@MainActor
final class FakeTriager: EmailTriager {
    var seen: [TriageInput] = []
    var answer: (TriageInput) -> (EmailTier, String, Date?) = { input in (.action, "Reply to \(input.from)", nil) }
    var failOn: String?

    func triage(_ input: TriageInput) async throws -> TriageAnswer {
        if input.subject == failOn { throw URLError(.timedOut) }
        seen.append(input)
        let (tier, summary, deadline) = answer(input)
        let call = APICall(
            at: Date(timeIntervalSince1970: 0), purpose: .triage, model: "claude-haiku-5-5",
            inputTokens: 500, outputTokens: 30, contentKind: .emailExcerpt)
        return TriageAnswer(tier: tier, summary: summary, reason: "Asks you to reply", deadline: deadline, call: call)
    }
}

@MainActor
@Suite struct TriageTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let mail = FakeMailSource()
    let triager = FakeTriager()

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func runner(_ assistant: Assistant) -> TriageRunner {
        TriageRunner(assistant: assistant, mail: mail, triager: triager)
    }

    func email(
        _ subject: String, from: String = "Sam <sam@work.example>", thread: String? = nil,
        labels: [String] = ["INBOX"], unsubscribe: Bool = false, body: String = "Can you send the invoice by Friday?"
    ) -> EmailMessage {
        EmailMessage(
            threadID: thread ?? "t-\(subject)", messageID: "m-\(subject)-\(UUID().uuidString)", from: from,
            subject: subject, labels: labels, hasListUnsubscribe: unsubscribe, plainText: body, receivedAt: clock.now)
    }

    // MARK: Rules first

    @Test func bulkMailAndMailDaraSentNeverReachTheModel() async throws {
        let assistant = makeAssistant()
        try assistant.exclude(.sender("@bank.example"))
        mail.messages = [
            email("Sale!", labels: ["INBOX", "CATEGORY_PROMOTIONS"]),
            email("You were tagged", labels: ["INBOX", "CATEGORY_SOCIAL"]),
            email("Forum digest", labels: ["INBOX", "CATEGORY_FORUMS"]),
            email("Newsletter", unsubscribe: true),
            email("Receipt", from: "Shop <no-reply@shop.example>"),
            email("Your statement", from: "Bank <alerts@mail.bank.example>"),
            email("My own reply", labels: ["SENT", "INBOX"]),
            email("Archived", labels: ["CATEGORY_UPDATES"]),
            email("Invoice"),
        ]

        await runner(assistant).run()

        #expect(triager.seen.map(\.subject) == ["Invoice"])
    }

    @Test func theModelGetsOnlySenderSubjectAndTheStartOfTheText() async throws {
        let assistant = makeAssistant()
        mail.messages = [email("Long one", body: String(repeating: "x", count: 10_000))]

        await runner(assistant).run()

        let input = try #require(triager.seen.first)
        #expect(input.from == "Sam <sam@work.example>")
        #expect(input.subject == "Long one")
        #expect(input.excerpt.count == 2_048)
    }

    // MARK: Suggestions

    @Test func anActionEmailBecomesASuggestionWithAGuessedDeadline() async throws {
        let assistant = makeAssistant()
        let friday = clock.now + 3 * 86_400
        triager.answer = { _ in (.action, "Send Sam the invoice", friday) }
        mail.messages = [email("Invoice", thread: "thread-1")]

        await runner(assistant).run()

        let suggestion = try #require(assistant.suggestions.first)
        #expect(suggestion.title == "Send Sam the invoice")
        #expect(suggestion.guessedDeadline == friday)
        #expect(suggestion.backLink == "https://mail.google.com/mail/u/0/#all/thread-1")
        #expect(suggestion.source == .email)
        #expect(assistant.tasks.isEmpty)
        #expect(try store.load().audit.map(\.purpose) == [.triage])
    }

    @Test func worthKnowingAndNoiseMakeNoSuggestion() async throws {
        let assistant = makeAssistant()
        triager.answer = { input in (input.subject == "FYI" ? .worthKnowing : .noise, "x", nil) }
        mail.messages = [email("FYI"), email("Meh")]

        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func oneSuggestionPerThread() async throws {
        let assistant = makeAssistant()
        mail.messages = [email("Invoice", thread: "thread-1"), email("Re: Invoice", thread: "thread-1")]

        await runner(assistant).run()

        #expect(assistant.suggestions.count == 1)
    }

    @Test func acceptingMakesATaskWithTheGuessedDeadline() async throws {
        let assistant = makeAssistant()
        let friday = clock.now + 3 * 86_400
        triager.answer = { _ in (.action, "Send Sam the invoice", friday) }
        mail.messages = [email("Invoice", thread: "thread-1")]
        await runner(assistant).run()
        let suggestion = try #require(assistant.suggestions.first)

        let task = try assistant.acceptSuggestion(suggestion.id)

        #expect(task.title == "Send Sam the invoice")
        #expect(task.source == .email)
        #expect(task.deadline == friday)
        #expect(task.backLink == suggestion.backLink)
        #expect(assistant.suggestions.isEmpty)
        #expect(assistant.operationLog.last?.kind == .acceptSuggestion)
    }

    @Test func undoingAnAcceptBringsTheSuggestionBack() async throws {
        let assistant = makeAssistant()
        mail.messages = [email("Invoice")]
        await runner(assistant).run()
        let task = try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)

        try assistant.undo(try #require(assistant.operationLog.last).id)

        #expect(assistant.suggestions.count == 1)
        #expect(assistant.task(task.id)?.deletedAt != nil)
    }

    @Test func anExcludedSenderAddedMidBatchIsNotSent() async throws {
        let assistant = makeAssistant()
        triager.answer = { input in
            if input.subject == "First" { try? assistant.exclude(.sender("@later.example")) }
            return (.noise, "x", nil)
        }
        mail.messages = [email("First"), email("Second", from: "Later <x@later.example>")]

        await runner(assistant).run()

        #expect(triager.seen.map(\.subject) == ["First"])
    }

    @Test func dismissingDropsItAndALaterMessageOnTheThreadDoesNotBringItBack() async throws {
        let assistant = makeAssistant()
        mail.messages = [email("Invoice", thread: "thread-1")]
        await runner(assistant).run()

        try assistant.dismissSuggestion(try #require(assistant.suggestions.first).id)
        #expect(assistant.suggestions.isEmpty)

        mail.messages = [email("Re: Invoice", thread: "thread-1")]
        await runner(assistant).run()
        #expect(assistant.suggestions.isEmpty)
        #expect(triager.seen.count == 1)  // A thread with a Suggestion is never sent again.
    }

    @Test func anAcceptedThreadDoesNotGetASecondSuggestion() async throws {
        let assistant = makeAssistant()
        mail.messages = [email("Invoice", thread: "thread-1")]
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)

        mail.messages = [email("Re: Invoice", thread: "thread-1")]
        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func anUnansweredSuggestionExpiresQuietlyAfterSevenDays() async throws {
        let assistant = makeAssistant()
        mail.messages = [email("Invoice")]
        await runner(assistant).run()

        clock.advance(minutes: 7 * 24 * 60 - 1)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.suggestions.count == 1)

        clock.advance(minutes: 1)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.suggestions.isEmpty)
        #expect(assistant.decisions.isEmpty)
    }

    @Test func suggestionsNeverFeedNextButNextSaysToReviewThem() async throws {
        let assistant = makeAssistant()
        mail.messages = [email("Invoice"), email("Contract")]
        await runner(assistant).run()

        #expect(assistant.next == .reviewSuggestions(2))
        #expect(assistant.menuBar.nextTitle == "Review Suggestions (2)")

        try assistant.quickAdd("A real Task")
        #expect(assistant.next.task != nil)
    }

    @Test func suggestionsSurviveARestartAndNoBodyIsStored() async throws {
        let assistant = makeAssistant()
        mail.messages = [email("Invoice", body: "SECRET-BODY-TEXT please pay")]
        await runner(assistant).run()

        #expect(makeAssistant().suggestions.map(\.title) == assistant.suggestions.map(\.title))
        #expect(!String(describing: try store.load()).contains("SECRET-BODY-TEXT"))
    }

    @Test func aLogEntryWrittenBeforeSuggestionsStillLoads() throws {
        let old = #"{"tasks":[],"projects":[]}"#
        let change = try JSONDecoder().decode(Change.self, from: Data(old.utf8))
        #expect(change.suggestions.isEmpty)
        #expect(change.mailCursor == nil)
    }

    // MARK: Cursor

    @Test func theFirstRunStartsFreshAndLaterRunsResumeFromTheStoredCursor() async throws {
        let assistant = makeAssistant()
        mail.nextCursor = "h42"
        await runner(assistant).run()
        mail.nextCursor = "h43"
        await runner(assistant).run()

        await runner(makeAssistant()).run()

        #expect(mail.cursorsAskedFor == [nil, "h42", "h43"])
    }

    @Test func aFailureKeepsTheCursorSoNothingIsMissed() async throws {
        let assistant = makeAssistant()
        mail.nextCursor = "h1"
        await runner(assistant).run()

        mail.nextCursor = "h2"
        mail.messages = [email("Invoice"), email("Breaks")]
        triager.failOn = "Breaks"
        await runner(assistant).run()

        triager.failOn = nil
        mail.messages = [email("Invoice"), email("Breaks")]
        await runner(assistant).run()

        #expect(mail.cursorsAskedFor == [nil, "h1", "h1"])
        #expect(assistant.suggestions.count == 2)
    }
}
