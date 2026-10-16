import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

/// A fake macOS notification centre: records what was shown.
@MainActor
final class FakeNotifier: Notifier {
    var shown: [(title: String, body: String)] = []

    func notify(title: String, body: String) {
        shown.append((title, body))
    }
}

@MainActor
@Suite struct DigestTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let mail = FakeMailSource()
    let triager = FakeTriager()
    let notifier = FakeNotifier()

    func makeAssistant() -> Assistant {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara", calendar: utc)
    }

    func runner(_ assistant: Assistant) -> TriageRunner {
        TriageRunner(assistant: assistant, mail: mail, triager: triager, notifier: notifier)
    }

    func email(
        _ subject: String, from: String = "Sam <sam@work.example>", thread: String? = nil,
        labels: [String] = ["INBOX"], unsubscribe: Bool = false, received: Date? = nil
    ) -> EmailMessage {
        let message = EmailMessage(
            threadID: thread ?? "t-\(subject)", messageID: "m-\(subject)-\(UUID().uuidString)", from: from,
            subject: subject, labels: labels, hasListUnsubscribe: unsubscribe, receivedAt: received ?? clock.now)
        mail.bodies[message.messageID] = "Body of \(subject)"
        return message
    }

    func worthKnowing() {
        triager.answer = { _ in (.worthKnowing, "", nil) }
    }

    // MARK: Digest

    @Test func worthKnowingMailBecomesADigestLineWithoutItsBody() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = [email("Contract signed")]

        await runner(assistant).run()

        let line = try #require(assistant.digest.first)
        #expect(line.subject == "Contract signed")
        #expect(line.from == "Sam <sam@work.example>")
        #expect(line.reason == "Asks you to reply")
        #expect(line.backLink == "https://mail.google.com/mail/u/0/#all/t-Contract%20signed")
        #expect(assistant.suggestions.isEmpty)
        #expect(!String(describing: try store.load()).contains("Body of"))
    }

    @Test func atMostFiveLinesNewestFirst() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = (1...7).map { index in email("News \(index)", received: clock.now + Double(index)) }

        await runner(assistant).run()

        #expect(assistant.digest.map(\.subject) == ["News 7", "News 6", "News 5", "News 4", "News 3"])
    }

    @Test func oneLinePerThreadTheNewestMessageWins() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = [email("Update", thread: "t1"), email("Re: Update", thread: "t1", received: clock.now + 60)]

        await runner(assistant).run()

        #expect(assistant.digest.map(\.subject) == ["Re: Update"])
    }

    @Test func anOlderMessageArrivingLateDoesNotReplaceANewerLine() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = [email("Re: Update", thread: "t1", received: clock.now + 60), email("Update", thread: "t1")]

        await runner(assistant).run()

        #expect(assistant.digest.map(\.subject) == ["Re: Update"])
    }

    @Test func aLineClearsTwentyFourHoursAfterTheEmailArrived() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = [email("FYI")]
        await runner(assistant).run()

        clock.advance(minutes: 24 * 60 - 1)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.digest.count == 1)

        clock.advance(minutes: 1)
        assistant.receive(.userIdle(seconds: 0))
        #expect(assistant.digest.isEmpty)
        #expect(makeAssistant().digest.isEmpty)
    }

    @Test func mailAlreadyOlderThanADayNeverJoinsTheDigest() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = [email("Old news", received: clock.now - 25 * 3600)]

        await runner(assistant).run()

        #expect(assistant.digest.isEmpty)
        #expect(try store.load().digest.isEmpty)
    }

    @Test func aLineClearsOnceItsThreadIsReadInGmail() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = [email("FYI", thread: "t1"), email("Also", thread: "t2")]
        await runner(assistant).run()
        #expect(assistant.digest.count == 2)

        mail.readThreads = ["t1"]
        await runner(assistant).run()

        #expect(assistant.digest.map(\.threadID) == ["t2"])
        #expect(makeAssistant().digest.map(\.threadID) == ["t2"])
    }

    @Test func oneClickPromotesALineToASuggestion() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = [email("Contract signed", thread: "t1")]
        await runner(assistant).run()

        try assistant.promoteDigestLine(try #require(assistant.digest.first).threadID)

        #expect(assistant.digest.isEmpty)
        let suggestion = try #require(assistant.suggestions.first)
        #expect(suggestion.title == "Contract signed")
        #expect(suggestion.threadID == "t1")
        #expect(assistant.operationLog.last?.kind == .promoteDigestLine)
    }

    @Test func anActionLaterOnTheThreadReplacesItsLine() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = [email("Contract", thread: "t1")]
        await runner(assistant).run()

        triager.answer = { _ in (.action, "Sign the contract", nil) }
        mail.messages = [email("Re: Contract", thread: "t1")]
        await runner(assistant).run()

        #expect(assistant.digest.isEmpty)
        #expect(assistant.suggestions.map(\.title) == ["Sign the contract"])
    }

    @Test func aReadLineDoesNotComeBackWhenTheSameEmailIsSortedAgain() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        let fyi = email("FYI", thread: "t1")
        mail.messages = [fyi]
        await runner(assistant).run()
        mail.readThreads = ["t1"]
        await runner(assistant).run()

        mail.messages = [fyi]  // A retried batch after a restart, with Gmail's read state unavailable.
        mail.unreadFails = true
        await runner(makeAssistant()).run()

        #expect(assistant.digest.isEmpty)
        #expect(makeAssistant().digest.isEmpty)
    }

    @Test func excludingASenderClearsTheirLines() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = [email("Statement", from: "Bank <alerts@bank.example>"), email("FYI")]
        await runner(assistant).run()

        try assistant.exclude(.sender("@bank.example"))

        #expect(assistant.digest.map(\.subject) == ["FYI"])
        #expect(try store.load().digest.filter { !$0.cleared }.map(\.subject) == ["FYI"])
    }

    @Test func undoingAPromoteWorksAfterARestart() async throws {
        let assistant = makeAssistant()
        worthKnowing()
        mail.messages = [email("Contract", thread: "t1")]
        await runner(assistant).run()
        try assistant.promoteDigestLine("t1")

        let restarted = makeAssistant()
        try restarted.undo(try #require(restarted.operationLog.last).id)

        #expect(restarted.digest.map(\.threadID) == ["t1"])
        #expect(restarted.suggestions.isEmpty)
    }

    @Test func aTightenedPromoteAsksAndCanBeConfirmed() async throws {
        let assistant = makeAssistant()
        try assistant.tighten(.promoteDigestLine)
        worthKnowing()
        mail.messages = [email("Contract", thread: "t1")]
        await runner(assistant).run()

        guard case .pending = try assistant.promoteDigestLine("t1") else { Issue.record("should ask"); return }
        try assistant.confirmAsk(try #require(assistant.asks.first).id)

        #expect(assistant.suggestions.map(\.threadID) == ["t1"])
        #expect(assistant.digest.isEmpty)
    }

    @Test func promotingALineThatIsntShowingFails() {
        let assistant = makeAssistant()
        #expect(throws: Assistant.Failure.unknownDigestLine("nope")) { try assistant.promoteDigestLine("nope") }
    }

    // MARK: VIPs

    @Test func recentRecipientsAreReadOnceWhenNoneAreKnownExcludedOnesLeftOut() async throws {
        let assistant = makeAssistant()
        try assistant.exclude(.sender("@bank.example"))
        mail.recent = [SentMail(to: ["Alex <alex@friend.example>", "help@bank.example"], at: clock.now - 86_400)]
        let triage = runner(assistant)

        await triage.run()
        await triage.run()

        #expect(mail.recentAsked == 1)
        #expect(assistant.isVIP(sender: "alex@friend.example"))
        #expect(try store.load().recipients.keys.sorted() == ["alex@friend.example"])
    }

    @Test func withNoSentMailTheBackfillIsNotRepeatedEveryPoll() async {
        let assistant = makeAssistant()
        let triage = runner(assistant)
        await triage.run()
        await triage.run()
        #expect(mail.recentAsked == 1)
    }

    @Test func aVIPWrittenWithANameIsStoredAsTheAddress() throws {
        let assistant = makeAssistant()
        try assistant.addVIP("Sam <Sam@Work.example>")
        #expect(assistant.vips == ["sam@work.example"])
        #expect(throws: Assistant.Failure.alreadyVIP("sam@work.example")) { try assistant.addVIP("sam@work.example") }
        #expect(throws: Assistant.Failure.notAVIP("x@y.example")) { try assistant.removeVIP("x@y.example") }
    }

    @Test func aVIPBypassesTheBulkRulesButIsStillTriaged() async throws {
        let assistant = makeAssistant()
        try assistant.addVIP("boss@work.example")
        mail.messages = [
            email("Quarterly update", from: "Boss <boss@work.example>", labels: ["INBOX", "CATEGORY_UPDATES", "CATEGORY_FORUMS"], unsubscribe: true),
            email("Sale!", labels: ["INBOX", "CATEGORY_PROMOTIONS"]),
        ]

        await runner(assistant).run()

        #expect(triager.seen.map(\.subject) == ["Quarterly update"])
    }

    @Test func aVIPWhoIsExcludedIsStillNeverSent() async throws {
        let assistant = makeAssistant()
        try assistant.addVIP("@bank.example")
        try assistant.exclude(.sender("@bank.example"))
        mail.messages = [email("Statement", from: "alerts@bank.example")]

        await runner(assistant).run()

        #expect(triager.seen.isEmpty)
        #expect(mail.bodiesRead.isEmpty)
    }

    @Test func anyoneEmailedInTheLastNinetyDaysIsAVIP() async throws {
        let assistant = makeAssistant()
        mail.sent = [SentMail(to: ["Alex <alex@friend.example>"], at: clock.now - 89 * 86_400),
                     SentMail(to: ["old@friend.example"], at: clock.now - 91 * 86_400)]
        mail.messages = [
            email("Party", from: "alex@friend.example", unsubscribe: true),
            email("Long time", from: "old@friend.example", unsubscribe: true),
        ]

        await runner(assistant).run()

        #expect(triager.seen.map(\.subject) == ["Party"])
        #expect(makeAssistant().isVIP(sender: "Alex <alex@friend.example>"))
        #expect(try store.load().recipients.keys.sorted() == ["alex@friend.example"])  // Nothing older is kept.
    }

    @Test func aRecentRecipientStopsBeingAVIPAfterNinetyDays() async throws {
        let assistant = makeAssistant()
        mail.sent = [SentMail(to: ["alex@friend.example"], at: clock.now)]
        await runner(assistant).run()
        #expect(assistant.isVIP(sender: "alex@friend.example"))

        clock.advance(minutes: 90 * 24 * 60 + 1)
        #expect(!assistant.isVIP(sender: "alex@friend.example"))
    }

    @Test func theVIPListIsEditableAndKept() throws {
        let assistant = makeAssistant()
        try assistant.addVIP("Boss@Work.example")
        try assistant.addVIP("@family.example")
        #expect(makeAssistant().vips == ["boss@work.example", "@family.example"])
        #expect(assistant.isVIP(sender: "Mum <mum@family.example>"))

        try assistant.removeVIP("boss@work.example")
        #expect(assistant.vips == ["@family.example"])
        #expect(assistant.operationLog.map(\.kind).suffix(1) == [.removeVIP])
        #expect(throws: Exclusion.Invalid.self) { try assistant.addVIP("nobody") }
    }

    // MARK: Notifications

    @Test func aVIPActionDueTodayOrTomorrowNotifies() async throws {
        let assistant = makeAssistant()
        try assistant.addVIP("boss@work.example")
        let tomorrow = clock.now + 30 * 3600  // FakeClock starts at 04:00 UTC: this is tomorrow 10:00.
        triager.answer = { _ in (.action, "Approve the budget", tomorrow) }
        mail.messages = [email("Budget", from: "Boss <boss@work.example>")]

        await runner(assistant).run()

        #expect(notifier.shown.count == 1)
        #expect(notifier.shown.first?.title == "Approve the budget")
        #expect(notifier.shown.first?.body.contains("Boss") == true)
    }

    @Test(arguments: [
        ("not a VIP", false, 3600.0 as Double?),
        ("VIP, due in three days", true, 3 * 86_400.0 as Double?),
        ("VIP, due the day after tomorrow", true, 2 * 86_400.0 as Double?),
        ("VIP, overdue since yesterday", true, -12 * 3600.0 as Double?),
        ("VIP, no deadline", true, nil as Double?),
    ])
    func nothingElseNotifies(_ name: String, vip: Bool, dueIn: Double?) async throws {
        let assistant = makeAssistant()
        if vip { try assistant.addVIP("sam@work.example") }
        let deadline = dueIn.map { clock.now + $0 }
        triager.answer = { _ in (.action, "Do it", deadline) }
        mail.messages = [email("Ask")]

        await runner(assistant).run()

        #expect(notifier.shown.isEmpty, "\(name)")
        #expect(assistant.suggestions.count == 1, "\(name)")
    }

    @Test func worthKnowingFromAVIPDoesNotNotify() async throws {
        let assistant = makeAssistant()
        try assistant.addVIP("sam@work.example")
        triager.answer = { _ in (.worthKnowing, "", clock.now + 3600) }
        mail.messages = [email("FYI")]

        await runner(assistant).run()

        #expect(notifier.shown.isEmpty)
    }
}
