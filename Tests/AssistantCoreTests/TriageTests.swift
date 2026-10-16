import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

/// A fake Gmail: hands out messages after the cursor it is given, and records whose bodies were read.
@MainActor
final class FakeMailSource: MailSource {
    var messages: [EmailMessage] = []
    var bodies: [String: String] = [:]
    var bodiesRead: [String] = []
    var cursorsAskedFor: [String?] = []
    var nextCursor = "h1"
    var fails = false
    var whileReading: (EmailMessage) -> Void = { _ in }
    /// Threads Dara has read in Gmail.
    var readThreads: Set<String> = []
    /// Mail Dara sent, handed out with the next batch.
    var sent: [SentMail] = []

    func fetchNew(after cursor: String?) async throws -> MailBatch {
        cursorsAskedFor.append(cursor)
        if fails { throw URLError(.notConnectedToInternet) }
        defer { (messages, sent) = ([], []) }
        return MailBatch(messages: messages, sent: sent, cursor: nextCursor)
    }

    func unreadThreads(among threadIDs: [String]) async throws -> Set<String> {
        Set(threadIDs).subtracting(readThreads)
    }

    func plainText(of message: EmailMessage) async throws -> String {
        bodiesRead.append(message.subject)
        whileReading(message)
        return bodies[message.messageID] ?? ""
    }
}

/// A scripted Haiku: records exactly what reached it.
@MainActor
final class FakeTriager: EmailTriager {
    var seen: [TriageInput] = []
    var answer: (TriageInput) -> (EmailTier, String, Date?) = { input in (.action, "Reply to \(input.from)", nil) }
    var failOn: String?
    var refuseOn: String?

    struct Refused: BilledFailure {
        let call: APICall
    }

    func triage(_ input: TriageInput) async throws -> TriageAnswer {
        if input.subject == failOn { throw URLError(.timedOut) }
        if input.subject == refuseOn {
            throw Refused(call: APICall(
                at: Date(timeIntervalSince1970: 0), purpose: .triage, model: "claude-haiku-5-5",
                inputTokens: 500, outputTokens: 2, contentKind: .emailExcerpt))
        }
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
        let message = EmailMessage(
            threadID: thread ?? "t-\(subject)", messageID: "m-\(subject)-\(UUID().uuidString)", from: from,
            subject: subject, labels: labels, hasListUnsubscribe: unsubscribe, receivedAt: clock.now)
        mail.bodies[message.messageID] = body
        return message
    }

    func accept(_ assistant: Assistant, _ id: Suggestion.ID) throws -> Task {
        try assistant.acceptSuggestion(id)
        return try #require(assistant.tasks.first { $0.source == .email })
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
        #expect(mail.bodiesRead == ["Invoice"])  // Bulk and Excluded mail is never even read.
    }

    @Test(arguments: ["no-reply@x.example", "noreply@x.example", "Do_Not_Reply <donotreply@x.example>", "do-not-reply@x.example"])
    func noReplySendersAreBulk(_ sender: String) async {
        let assistant = makeAssistant()
        mail.messages = [email("Receipt", from: sender), email("Invoice", from: "replies@x.example")]
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

        let task = try accept(assistant, suggestion.id)

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
        let task = try accept(assistant, try #require(assistant.suggestions.first).id)

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

    @Test func anEmptySummaryFallsBackToTheSubjectAndLongOnesAreCut() async throws {
        let assistant = makeAssistant()
        triager.answer = { input in (.action, input.subject == "Plain" ? " " : String(repeating: "word ", count: 50), nil) }
        mail.messages = [email("Plain"), email("Wordy")]

        await runner(assistant).run()

        let titles = Set(assistant.suggestions.map(\.title))
        #expect(titles.contains("Plain"))
        #expect(titles.contains { $0.count == 120 && $0.hasSuffix("…") })
    }

    @Test func acceptingWhenTightenedAsksAndIsNotOfferedTwice() async throws {
        let assistant = makeAssistant()
        try assistant.tighten(.acceptSuggestion)
        mail.messages = [email("Invoice")]
        await runner(assistant).run()
        let suggestion = try #require(assistant.suggestions.first)

        guard case .pending = try assistant.acceptSuggestion(suggestion.id) else {
            Issue.record("a tightened accept should ask"); return
        }
        #expect(assistant.tasks.isEmpty)
        #expect(assistant.suggestions.isEmpty)
        #expect(throws: Assistant.Failure.unknownSuggestion(suggestion.id)) { try assistant.acceptSuggestion(suggestion.id) }

        try assistant.confirmAsk(try #require(assistant.asks.first).id)
        #expect(assistant.tasks.map(\.title) == ["Reply to Sam <sam@work.example>"])
    }

    @Test func undoingADismissBringsItBackForAFreshWeek() async throws {
        let assistant = makeAssistant()
        mail.messages = [email("Invoice")]
        await runner(assistant).run()
        clock.advance(minutes: 6 * 24 * 60)
        try assistant.dismissSuggestion(try #require(assistant.suggestions.first).id)
        clock.advance(minutes: 2 * 24 * 60)

        try assistant.undo(try #require(assistant.operationLog.last).id)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.suggestions.count == 1)

        clock.advance(minutes: 7 * 24 * 60)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.suggestions.isEmpty)
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
        _ = try accept(assistant, try #require(assistant.suggestions.first).id)

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
        let triage = runner(assistant)
        mail.nextCursor = "h1"
        await triage.run()

        mail.nextCursor = "h2"
        mail.messages = [email("Invoice"), email("Breaks")]
        triager.failOn = "Breaks"
        await triage.run()

        triager.failOn = nil
        mail.messages = [email("Invoice"), email("Breaks")]
        await triage.run()

        #expect(mail.cursorsAskedFor == [nil, "h1", "h1"])
        #expect(assistant.suggestions.count == 2)
        #expect(triager.seen.map(\.subject) == ["Invoice", "Breaks"])  // What was sorted isn't sent again.
    }

    @Test func noiseAlreadySortedIsNotSentAgainWhenTheBatchIsRetried() async throws {
        let assistant = makeAssistant()
        let triage = runner(assistant)
        triager.answer = { _ in (.noise, "x", nil) }
        let batch = [email("Meh"), email("Breaks")]
        mail.messages = batch
        triager.failOn = "Breaks"
        await triage.run()

        triager.failOn = nil
        mail.messages = batch
        await triage.run()

        #expect(triager.seen.map(\.subject) == ["Meh", "Breaks"])
    }

    @Test func aSenderExcludedWhileTheBodyIsReadIsNotSent() async throws {
        let assistant = makeAssistant()
        mail.whileReading = { _ in try? assistant.exclude(.sender("@work.example")) }
        mail.messages = [email("Invoice")]

        await runner(assistant).run()

        #expect(triager.seen.isEmpty)
    }

    @Test func aRefusalIsAuditedAndCountsAsHandled() async throws {
        let assistant = makeAssistant()
        let triage = runner(assistant)
        mail.nextCursor = "h2"
        mail.messages = [email("Odd one")]
        triager.refuseOn = "Odd one"

        await triage.run()

        #expect(try store.load().audit.count == 1)
        #expect(assistant.mailCursor == "h2")
    }

    @Test func aFailedFetchChangesNothing() async throws {
        let assistant = makeAssistant()
        mail.fails = true
        mail.messages = [email("Invoice")]

        await runner(assistant).run()

        #expect(assistant.mailCursor == nil)
        #expect(assistant.suggestions.isEmpty)
        #expect(triager.seen.isEmpty)
    }
}
