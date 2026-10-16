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

        #expect(assistant.task(task.id)?.hasNewReply == true)
        #expect(triager.seen.count == calls)
        #expect(assistant.suggestions.isEmpty)

        mail.sent = [reply()]
        later()
        await runner(assistant).run()
        #expect(assistant.task(task.id)?.hasNewReply == false)  // Dara answered it.
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

        #expect(assistant.task(task.id)?.hasNewReply == false)
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

        #expect(assistant.task(task.id)?.hasNewReply == false)
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

    @Test func aSourceUpdateRenamesATaskWhoseTitleCameFromTheSource() async throws {
        let assistant = makeAssistant()
        let task = try await accepted(assistant)

        let changed = try assistant.updateFromSource(task.id, title: "Send the invoice v2", deadline: nil)

        #expect(changed?.title == "Send the invoice v2")
        #expect(assistant.operationLog.last?.startedBy == .helper)
    }
}
