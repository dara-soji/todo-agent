import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

/// Gmail activity on a thread keeps its Suggestion or Task current.
@MainActor
@Suite struct ThreadTests {
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
        _ subject: String, from: String = "Sam <sam@work.example>", thread: String = "t1", labels: [String] = ["INBOX"]
    ) -> EmailMessage {
        let message = EmailMessage(
            threadID: thread, messageID: "m-\(subject)-\(UUID().uuidString)", from: from, subject: subject,
            labels: labels, hasListUnsubscribe: false, receivedAt: clock.now)
        mail.bodies[message.messageID] = "Body of \(subject)"
        return message
    }

    func reply(on thread: String = "t1") -> SentMail {
        SentMail(to: ["sam@work.example"], at: clock.now, threadID: thread)
    }

    /// An open Suggestion on thread t1.
    func suggested(_ assistant: Assistant, _ title: String = "Send the invoice") async throws -> Suggestion {
        triager.answer = { _ in (.action, title, nil) }
        mail.messages = [email("Invoice")]
        await runner(assistant).run()
        return try #require(assistant.suggestions.first)
    }

    /// An accepted Suggestion's Task on thread t1.
    func accepted(_ assistant: Assistant) async throws -> Task {
        let suggestion = try await suggested(assistant)
        try assistant.acceptSuggestion(suggestion.id)
        return try #require(assistant.tasks.first)
    }

    func later() {
        clock.advance(minutes: 10)
    }

    // MARK: Dara's reply

    @Test func daraReplyingDismissesAnOpenSuggestionQuietly() async throws {
        let assistant = makeAssistant()
        _ = try await suggested(assistant)
        later()

        mail.sent = [reply()]
        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
        #expect(assistant.decisions.isEmpty)
        #expect(assistant.operationLog.isEmpty)
    }

    @Test func aReplyBeforeTheEmailDoesNotDismissIt() async throws {
        let assistant = makeAssistant()
        let earlier = SentMail(to: ["sam@work.example"], at: clock.now - 3600, threadID: "t1")
        _ = try await suggested(assistant)

        mail.sent = [earlier]
        await runner(assistant).run()

        #expect(assistant.suggestions.count == 1)
    }

    @Test func daraReplyingOnAnAcceptedTasksThreadAsksDone() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        later()

        mail.sent = [reply()]
        await runner(assistant).run()

        #expect(assistant.decisions == [.isItDone(task.id)])
        #expect(assistant.task(task.id)?.status == .open)  // Only Dara marks it done.

        try assistant.completeTask(task.id)
        #expect(assistant.decisions.isEmpty)
    }

    @Test func notYetKeepsTheTaskAndClearsTheQuestion() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        later()
        mail.sent = [reply()]
        await runner(assistant).run()

        assistant.notDoneYet(task.id)

        #expect(assistant.decisions.isEmpty)
        #expect(assistant.task(task.id)?.status == .open)
    }

    // MARK: New messages

    @Test func aNewMessageUpdatesAnOpenSuggestion() async throws {
        let assistant = makeAssistant()
        let original = try await suggested(assistant)
        later()
        let friday = clock.now + 3 * 86_400
        triager.answer = { _ in (.action, "Send the corrected invoice", friday) }

        mail.messages = [email("Re: Invoice")]
        await runner(assistant).run()

        let updated = try #require(assistant.suggestions.first)
        #expect(assistant.suggestions.count == 1)
        #expect(updated.id == original.id)
        #expect(updated.title == "Send the corrected invoice")
        #expect(updated.guessedDeadline == friday)
    }

    @Test func aNewMessageThatIsntAnActionLeavesTheSuggestionAsItIs() async throws {
        let assistant = makeAssistant()
        _ = try await suggested(assistant)
        later()
        triager.answer = { _ in (.noise, "", nil) }

        mail.messages = [email("Re: Invoice — thanks!")]
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Send the invoice"])
    }

    @Test func aNewMessageMarksAnOpenTaskNewReplyWithoutAskingTheModel() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        later()
        let calls = triager.seen.count

        mail.messages = [email("Re: Invoice")]
        await runner(assistant).run()

        #expect(assistant.hasNewReply(task.id))
        #expect(triager.seen.count == calls)
        #expect(assistant.suggestions.isEmpty)

        mail.sent = [reply()]
        later()
        await runner(assistant).run()
        #expect(!assistant.hasNewReply(task.id))  // Dara answered it.
    }

    @Test func aFreshActionOnADoneTasksThreadBecomesANewSuggestion() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        try assistant.completeTask(task.id)
        later()
        triager.answer = { _ in (.action, "Send next month's invoice", nil) }

        mail.messages = [email("Re: Invoice — next month")]
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Send next month's invoice"])
        #expect(assistant.task(task.id)?.status == .done)
    }

    @Test func aFreshActionOnADroppedTasksThreadBecomesANewSuggestion() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        try assistant.dropTask(task.id)
        later()

        mail.messages = [email("Re: Invoice — again")]
        await runner(assistant).run()

        #expect(assistant.suggestions.count == 1)
    }

    @Test func archivingInGmailChangesNothing() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        let before = try store.load()
        later()

        mail.messages = [email("Invoice", labels: ["CATEGORY_UPDATES"])]  // The same thread, now out of the inbox.
        await runner(assistant).run()

        #expect(!assistant.hasNewReply(task.id))
        #expect(try store.load().tasks == before.tasks)
        #expect(try store.load().suggestions == before.suggestions)
    }

    @Test func theSameMessageDeliveredAgainIsNotANewReply() async throws {
        let assistant = makeAssistant()
        triager.answer = { _ in (.action, "Send the invoice", nil) }
        let original = email("Invoice")
        mail.messages = [original]
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)
        let task = try #require(assistant.tasks.first)

        mail.messages = [original]  // A retried batch.
        await runner(assistant).run()

        #expect(!assistant.hasNewReply(task.id))
    }

    @Test func aReplyFoundWhileReadingSentMailSettlesTheSuggestion() async throws {
        let assistant = makeAssistant()
        mail.messages = [email("Invoice")]
        mail.recent = [SentMail(to: ["sam@work.example"], at: clock.now + 60, threadID: "t1")]

        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func anUpdateToASuggestionDoesNotNotifyAgain() async throws {
        let assistant = makeAssistant()
        let notifier = FakeNotifier()
        try assistant.addVIP("sam@work.example")
        let tomorrow = clock.now + 30 * 3600
        triager.answer = { _ in (.action, "Approve it", tomorrow) }
        let triage = TriageRunner(assistant: assistant, mail: mail, triager: triager, notifier: notifier)
        mail.messages = [email("Budget")]
        await triage.run()
        later()

        mail.messages = [email("Re: Budget")]
        await triage.run()

        #expect(notifier.shown.count == 1)
    }

    @Test func anOlderReplyInTheSameBatchDoesNotHideANewerMessage() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        later()
        let replyAt = clock.now
        later()
        mail.sent = [SentMail(to: ["sam@work.example"], at: replyAt, threadID: "t1")]
        mail.messages = [email("Re: Re: Invoice")]  // Sam answered after Dara.

        await runner(assistant).run()

        #expect(assistant.hasNewReply(task.id))
        #expect(assistant.decisions.isEmpty)
    }

    @Test func aRetriedBatchDoesNotAskDoneAgainAfterNotYet() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        later()
        let triage = runner(assistant)
        let answer = reply()
        mail.sent = [answer]
        await triage.run()
        assistant.notDoneYet(task.id)

        mail.sent = [answer]  // The same reply, handed out again.
        await runner(makeAssistant()).run()

        #expect(assistant.decisions.isEmpty)
        #expect(makeAssistant().decisions.isEmpty)
    }

    @Test func doneIsAskedAgainAfterARestart() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        later()
        mail.sent = [reply()]
        await runner(assistant).run()

        #expect(makeAssistant().decisions == [.isItDone(task.id)])
    }

    @Test func mailOnTheThreadDoesNotBreakAHeldEditOrAnUndo() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        try assistant.tighten(.editTask)
        guard case .pending = try assistant.editTask(task.id, TaskChanges(title: "Invoice for Sam (paid?)")) else {
            Issue.record("should ask"); return
        }
        later()

        mail.messages = [email("Re: Invoice")]
        mail.sent = [reply()]
        await runner(assistant).run()

        try assistant.confirmAsk(try #require(assistant.asks.first).id)
        #expect(assistant.task(task.id)?.title == "Invoice for Sam (paid?)")
        #expect(throws: Never.self) { try assistant.undo(try #require(assistant.operationLog.last).id) }
    }

    @Test func anAcceptCanBeUndoneAfterMailOnItsThread() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        let accept = try #require(assistant.operationLog.last)
        later()
        mail.messages = [email("Re: Invoice")]
        await runner(assistant).run()

        try assistant.undo(accept.id)

        #expect(assistant.task(task.id)?.deletedAt != nil)
        #expect(assistant.suggestions.count == 1)
    }

    @Test func anAcceptHeldAsAnAskSurvivesNewMail() async throws {
        let assistant = makeAssistant()
        try assistant.tighten(.acceptSuggestion)
        let suggestion = try await suggested(assistant)
        try assistant.acceptSuggestion(suggestion.id)
        later()

        triager.answer = { _ in (.action, "Something else", nil) }
        mail.messages = [email("Re: Invoice")]
        mail.sent = [reply()]
        await runner(assistant).run()

        try assistant.confirmAsk(try #require(assistant.asks.first).id)
        #expect(assistant.tasks.map(\.title) == ["Send the invoice"])
    }

    @Test func aFreshAskAfterDaraRepliedBecomesANewSuggestion() async throws {
        let assistant = makeAssistant()
        _ = try await suggested(assistant)
        later()
        mail.sent = [reply()]
        await runner(assistant).run()
        later()

        triager.answer = { _ in (.action, "Send the receipt by Friday", nil) }
        mail.messages = [email("Re: Invoice — one more thing")]
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Send the receipt by Friday"])
    }

    @Test func aFailedSentMailReadKeepsTheCursorSoTheReplyIsntMissed() async throws {
        let assistant = makeAssistant()
        _ = try await suggested(assistant)
        let cursor = assistant.mailCursor
        mail.sentIncomplete = true
        mail.nextCursor = "h9"

        await runner(assistant).run()

        #expect(assistant.mailCursor == cursor)
    }

    @Test func aWorthKnowingFollowUpOnAThreadInHandStaysOutOfTheDigest() async throws {
        let assistant = makeAssistant()
        _ = try await suggested(assistant)
        later()
        triager.answer = { _ in (.worthKnowing, "", nil) }

        mail.messages = [email("Re: Invoice — FYI")]
        await runner(assistant).run()

        #expect(assistant.digest.isEmpty)
        #expect(assistant.suggestions.count == 1)
    }

    @Test func aTaskAcceptedBeforeThreadTrackingIsFoundByItsLink() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        // Strip the Task link, as a Suggestion stored before this release would be.
        var snapshot = try store.load()
        let index = try #require(snapshot.suggestions.firstIndex { $0.threadID == "t1" })
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.suggestions[index])) as! [String: Any]
        snapshot.suggestions[index] = try JSONDecoder().decode(
            Suggestion.self, from: JSONSerialization.data(withJSONObject: legacy.filter { $0.key != "task" }))
        let legacyStore = InMemoryStore(snapshot)
        let restarted = try Assistant(clock: clock, store: legacyStore, homeDirectory: "/Users/dara")
        later()

        mail.messages = [email("Re: Invoice")]
        await TriageRunner(assistant: restarted, mail: mail, triager: triager).run()

        #expect(restarted.suggestions.isEmpty)
        #expect(restarted.hasNewReply(task.id))
    }

    @Test func aPromotedLineCanBeNeverFromItsSender() async throws {
        let assistant = makeAssistant()
        triager.answer = { _ in (.worthKnowing, "", nil) }
        mail.messages = [email("FYI", thread: "t2")]
        await runner(assistant).run()
        try assistant.promoteDigestLine("t2")

        try assistant.dismissSuggestion(try #require(assistant.suggestions.first).id, neverFromSender: true)

        #expect(assistant.noiseSenders == ["sam@work.example"])
        try assistant.forgetNoiseSender("Sam <sam@work.example>")
        #expect(assistant.noiseSenders.isEmpty)
    }

    // MARK: Teaching

    @Test func neverFromThisSenderSendsTheirMailToNoise() async throws {
        let assistant = makeAssistant()
        let suggestion = try await suggested(assistant)

        try assistant.dismissSuggestion(suggestion.id, neverFromSender: true)
        let calls = triager.seen.count
        mail.messages = [email("Another ask", thread: "t2")]
        await runner(assistant).run()

        #expect(triager.seen.count == calls)
        #expect(assistant.suggestions.isEmpty)
        #expect(assistant.noiseSenders == ["sam@work.example"])
        #expect(makeAssistant().noiseSenders == ["sam@work.example"])
    }

    @Test func aPlainDismissTeachesNothing() async throws {
        let assistant = makeAssistant()
        let suggestion = try await suggested(assistant)

        try assistant.dismissSuggestion(suggestion.id)
        mail.messages = [email("Another ask", thread: "t2")]
        await runner(assistant).run()

        #expect(assistant.noiseSenders.isEmpty)
        #expect(assistant.suggestions.count == 1)
    }

    @Test func undoingNeverFromThisSenderForgetsIt() async throws {
        let assistant = makeAssistant()
        let suggestion = try await suggested(assistant)
        try assistant.dismissSuggestion(suggestion.id, neverFromSender: true)

        try assistant.undo(try #require(assistant.operationLog.last).id)

        #expect(assistant.noiseSenders.isEmpty)
        #expect(assistant.suggestions.count == 1)
    }

    // MARK: Titles

    @Test func aSourceUpdateNeverOverwritesATitleDaraSet() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        try assistant.editTask(task.id, TaskChanges(title: "Invoice for Sam (March)"))

        let changed = try assistant.updateFromSource(task.id, title: "Send the invoice v2", deadline: clock.now + 86_400)

        #expect(changed?.title == "Invoice for Sam (March)")
        #expect(changed?.deadline == clock.now + 86_400)
    }

    @Test func resendingTheSameTitleDoesNotPinIt() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)
        try assistant.editTask(task.id, TaskChanges(title: task.title, effort: .some(.small)), by: .claudeCode)

        let changed = try assistant.updateFromSource(task.id, title: "Send the invoice v2", deadline: nil)

        #expect(changed?.title == "Send the invoice v2")
    }

    @Test func aSourceUpdateRenamesATaskWhoseTitleCameFromTheSource() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)

        let changed = try assistant.updateFromSource(task.id, title: "Send the invoice v2", deadline: nil)

        #expect(changed?.title == "Send the invoice v2")
        #expect(assistant.operationLog.last?.startedBy == .helper)
    }
}
