import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

/// A fake Apple Notes: notes by folder, and what it was asked for.
@MainActor
final class FakeNotes: NotesSource {
    var all: [Note] = []
    var asked: [(since: Date?, skipping: [String])] = []
    var fails = false

    func notes(modifiedSince since: Date?, skippingFolders skipping: [String]) async throws -> [Note] {
        asked.append((since, skipping))
        if fails { throw URLError(.timedOut) }
        // A careless adapter might hand back everything: the core must still drop Excluded folders.
        return all.filter { since == nil || $0.modified > since! }
    }
}

@MainActor
@Suite struct NotesTests {
    let clock = FakeClock()
    let store = InMemoryStore()
    let notes = FakeNotes()

    func makeAssistant() -> Assistant {
        try! Assistant(clock: clock, store: store, homeDirectory: "/Users/dara")
    }

    func runner(_ assistant: Assistant) -> NotesRunner {
        NotesRunner(assistant: assistant, notes: notes)
    }

    func note(_ id: String, _ text: String, folder: String = "Notes", title: String = "Weekend", ago minutes: Double = 1) -> Note {
        Note(id: id, folder: folder, title: title, text: text, modified: clock.now - minutes * 60)
    }

    func put(_ note: Note) {
        notes.all.removeAll { $0.id == note.id }
        notes.all.append(note)
    }

    // MARK: Candidate actions

    @Test func aNoteWithOpenActionsBecomesOneSuggestionWithABackLink() async throws {
        let assistant = makeAssistant()
        put(note("n1", "Shopping\n- [ ] Book the dentist\n☐ Renew passport\n- [x] Buy milk\nTODO: call Mum"))

        await runner(assistant).run()

        let suggestion = try #require(assistant.suggestions.first)
        #expect(assistant.suggestions.count == 1)
        #expect(suggestion.title == "Book the dentist (+2 more)")
        #expect(suggestion.source == .notes)
        #expect(suggestion.backLink == "notes:n1")
        #expect(suggestion.reason == "From the note “Weekend”")
    }

    @Test func aNoteWithNoOpenActionsMakesNoSuggestion() async throws {
        let assistant = makeAssistant()
        put(note("n1", "Ideas for the talk\n- [x] Done already\nJust prose here."))

        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func notesAreDedupedByIdAcrossPollsAndRestarts() async throws {
        let assistant = makeAssistant()
        put(note("n1", "[ ] Book the dentist"))
        await runner(assistant).run()
        clock.advance(minutes: 5)
        await runner(assistant).run()
        await runner(makeAssistant()).run()

        #expect(makeAssistant().suggestions.count == 1)
    }

    @Test func anEditedNoteUpdatesItsSuggestionOrItsAcceptedTask() async throws {
        let assistant = makeAssistant()
        put(note("n1", "[ ] Book the dentist"))
        put(note("n2", "[ ] Renew passport", title: "Admin"))
        await runner(assistant).run()
        let admin = try #require(assistant.suggestions.first { $0.title == "Renew passport" })
        try assistant.acceptSuggestion(admin.id)
        clock.advance(minutes: 5)

        put(note("n1", "[ ] Book the dentist for Tuesday", ago: 0))
        put(note("n2", "[ ] Renew passport before June", title: "Admin", ago: 0))
        clock.advance(minutes: 1)
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Book the dentist for Tuesday"])
        #expect(assistant.tasks.map(\.title) == ["Renew passport before June"])
    }

    @Test func aNoteWhoseActionsAreAllTickedLosesItsSuggestion() async throws {
        let assistant = makeAssistant()
        put(note("n1", "[ ] Book the dentist"))
        await runner(assistant).run()
        clock.advance(minutes: 5)

        put(note("n1", "[x] Book the dentist", ago: 0))
        clock.advance(minutes: 1)
        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func aDismissedNoteStaysQuietWhenEdited() async throws {
        let assistant = makeAssistant()
        put(note("n1", "[ ] Book the dentist"))
        await runner(assistant).run()
        try assistant.dismissSuggestion(try #require(assistant.suggestions.first).id)
        clock.advance(minutes: 5)

        put(note("n1", "[ ] Book the dentist\n[ ] And the optician", ago: 0))
        clock.advance(minutes: 1)
        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func newActionsInADoneTasksNoteBecomeANewSuggestion() async throws {
        let assistant = makeAssistant()
        put(note("n1", "[ ] Book the dentist"))
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)
        try assistant.completeTask(try #require(assistant.tasks.first).id)
        clock.advance(minutes: 5)

        put(note("n1", "[x] Book the dentist\n[ ] Pay the dentist", ago: 0))
        clock.advance(minutes: 1)
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Pay the dentist"])
    }

    @Test func onlyActionsNewSinceTheDoneTaskAreOffered() async throws {
        let assistant = makeAssistant()
        put(note("n1", "[ ] Book the dentist"))
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)
        try assistant.completeTask(try #require(assistant.tasks.first).id)
        clock.advance(minutes: 5)

        put(note("n1", "[ ] Book the dentist\n[ ] Pay the dentist", ago: 0))  // Not ticked in the note.
        clock.advance(minutes: 1)
        await runner(assistant).run()

        #expect(assistant.suggestions.map(\.title) == ["Pay the dentist"])
    }

    @Test func aProseEditToAnExpiredNoteOffersNothing() async throws {
        let assistant = makeAssistant()
        put(note("n1", "[ ] Book the dentist"))
        await runner(assistant).run()
        clock.advance(minutes: 7 * 24 * 60)
        assistant.receive(.userIdle(seconds: 0))

        put(note("n1", "Dentist notes, updated\n[ ] Book the dentist", ago: 0))
        clock.advance(minutes: 1)
        await runner(assistant).run()

        #expect(assistant.suggestions.isEmpty)
    }

    @Test func anAcceptHeldAsAnAskSurvivesANoteEdit() async throws {
        let assistant = makeAssistant()
        try assistant.tighten(.acceptSuggestion)
        put(note("n1", "[ ] Book the dentist"))
        await runner(assistant).run()
        try assistant.acceptSuggestion(try #require(assistant.suggestions.first).id)
        clock.advance(minutes: 5)

        put(note("n1", "[ ] Book the dentist on Tuesday", ago: 0))
        clock.advance(minutes: 1)
        await runner(assistant).run()

        try assistant.confirmAsk(try #require(assistant.asks.first).id)
        #expect(assistant.tasks.map(\.title) == ["Book the dentist"])
    }

    // MARK: Exclusions

    @Test func excludedFoldersAreNeverRead() async throws {
        let assistant = makeAssistant()
        try assistant.exclude(.notesFolder("Private"))
        put(note("n1", "[ ] Secret thing", folder: "Private"))
        put(note("n2", "[ ] Book the dentist"))

        await runner(assistant).run()

        #expect(notes.asked.first?.skipping == ["Private"])
        #expect(assistant.suggestions.map(\.title) == ["Book the dentist"])
        #expect(!String(describing: try store.load()).contains("Secret thing"))
    }

    @Test func excludingAFolderTakesItsOpenSuggestionsAway() async throws {
        let assistant = makeAssistant()
        put(note("n1", "[ ] Secret thing", folder: "Private"))
        await runner(assistant).run()
        #expect(assistant.suggestions.count == 1)

        try assistant.exclude(.notesFolder("Private"))

        #expect(assistant.suggestions.isEmpty)
    }

    // MARK: Polling

    @Test func theFirstPollLooksTwoWeeksBackThenOnlyAtWhatChanged() async throws {
        let assistant = makeAssistant()
        put(note("old", "[ ] Ancient todo", ago: 15 * 24 * 60))
        put(note("n1", "[ ] Book the dentist", ago: 10))

        await runner(assistant).run()
        clock.advance(minutes: 5)
        await runner(makeAssistant()).run()

        #expect(notes.asked.map(\.since) == [clock.now - 5 * 60 - 14 * 86_400, clock.now - 5 * 60 - 10 * 60])
        #expect(assistant.suggestions.map(\.title) == ["Book the dentist"])
    }

    @Test func aFailedReadKeepsTheCursor() async throws {
        let assistant = makeAssistant()
        notes.fails = true
        await runner(assistant).run()
        notes.fails = false
        await runner(assistant).run()

        #expect(notes.asked.map(\.since) == [clock.now - 14 * 86_400, clock.now - 14 * 86_400])
    }

    @Test func noNoteContentGoesToTheAPI() async throws {
        let assistant = makeAssistant()
        put(note("n1", "[ ] Book the dentist"))
        await runner(assistant).run()
        #expect(try store.load().audit.isEmpty)
    }
}
