import Foundation
import Testing
import AssistantCore

/// Overlapping ⌥Space presses: each press's completion acts on its own press only.
@Suite struct VoicePressTests {
    let todo = Project.ID()
    let acme = Project.ID()

    // MARK: One press

    @Test func aHoldShowsListeningUnderTheProjectCapturedAtKeyDown() {
        var presses = VoicePresses()
        let press = presses.pressed(.ready, project: todo)

        #expect(presses.held(press.id) == .showListening(press))
        #expect(press.project == todo)
        #expect(presses.palette == press.id)
        // The hold acts once.
        #expect(presses.held(press.id) == .ignore)
    }

    @Test func aTapDiscardsTheRecordingAndOpensTheTypingBox() {
        var presses = VoicePresses()
        _ = presses.pressed(.ready, project: todo)

        #expect(presses.ended(.openTypingBox) == .discardThenType)
        #expect(presses.down == nil)
        #expect(presses.inFlight.isEmpty)
    }

    @Test func aReleasedHoldFinishesThenAddsAndClosesItsPalette() {
        var presses = VoicePresses()
        let press = presses.pressed(.ready, project: todo)
        _ = presses.held(press.id)

        #expect(presses.ended(.finishListening) == .finish(press))
        #expect(presses.inFlight == [press.id])
        #expect(presses.transcribed(press.id, "email Sam") == .add(showAdding: true))
        #expect(presses.added(press.id) == true)
        #expect(presses.palette == nil)
        #expect(presses.inFlight.isEmpty)
    }

    @Test func silenceClosesThePaletteAndAddsNothing() {
        var presses = VoicePresses()
        let press = presses.pressed(.ready, project: nil)
        _ = presses.held(press.id)
        _ = presses.ended(.finishListening)

        #expect(presses.transcribed(press.id, "  \n") == .drop(closePalette: true))
        #expect(presses.inFlight.isEmpty)
    }

    @Test func aReleaseBeforeTheHoldTimerStillFinishesButOwnsNoPalette() {
        var presses = VoicePresses()
        let press = presses.pressed(.ready, project: nil)

        #expect(presses.ended(.finishListening) == .finish(press))
        #expect(presses.transcribed(press.id, "email Sam") == .add(showAdding: false))
        #expect(presses.added(press.id) == false)
    }

    @Test func aHoldWithoutVoiceAsksOnceThenTypes() {
        var presses = VoicePresses()
        let press = presses.pressed(.askForMicrophone, project: nil)

        #expect(presses.held(press.id) == .askThenType(.askForMicrophone))
        // The typing box is already open; the release does nothing more.
        #expect(presses.ended(.finishListening) == .ignore)
    }

    @Test func aHoldWithoutVoiceReleasedBeforeTheTimerAsksThenTypes() {
        var presses = VoicePresses()
        _ = presses.pressed(.unavailable(.microphoneDenied), project: nil)

        #expect(presses.ended(.finishListening) == .askThenType(.unavailable(.microphoneDenied)))
    }

    @Test func theReleaseAfterTheCapEndedThePressIsIgnored() {
        var presses = VoicePresses()
        let press = presses.pressed(.ready, project: nil)
        _ = presses.held(press.id)
        #expect(presses.ended(.finishListening) == .finish(press))

        #expect(presses.ended(nil) == .ignore)
        #expect(presses.inFlight == [press.id])
    }

    // MARK: Overlapping presses

    @Test func aNewPressWhileTheEarlierOneFinishesKeepsTheEarlierInFlight() {
        var presses = VoicePresses()
        let first = presses.pressed(.ready, project: todo)
        _ = presses.held(first.id)
        _ = presses.ended(.finishListening)

        let second = presses.pressed(.ready, project: acme)

        #expect(first.id != second.id)
        #expect(presses.inFlight == [first.id])
        #expect(presses.down == second)
        // The earlier recording is still added, to the Project it captured.
        #expect(presses.transcribed(first.id, "email Sam") == .add(showAdding: true))
        #expect(first.project == todo)
    }

    @Test func theEarlierPressNeverClosesTheNewPressesListening() {
        var presses = VoicePresses()
        let first = presses.pressed(.ready, project: todo)
        _ = presses.held(first.id)
        _ = presses.ended(.finishListening)
        let second = presses.pressed(.ready, project: acme)
        #expect(presses.held(second.id) == .showListening(second))

        // Neither "Adding…" nor closing reaches the new press's palette.
        #expect(presses.transcribed(first.id, "email Sam") == .add(showAdding: false))
        #expect(presses.added(first.id) == false)
        #expect(presses.palette == second.id)
        #expect(presses.inFlight.isEmpty)
    }

    @Test func anEarlierSilentPressDoesNotCloseTheNewPressesListening() {
        var presses = VoicePresses()
        let first = presses.pressed(.ready, project: nil)
        _ = presses.held(first.id)
        _ = presses.ended(.finishListening)
        let second = presses.pressed(.ready, project: nil)
        _ = presses.held(second.id)

        #expect(presses.transcribed(first.id, "") == .drop(closePalette: false))
        #expect(presses.palette == second.id)
    }

    @Test func aTapAfterAnEarlierHoldTakesThePaletteForTyping() {
        var presses = VoicePresses()
        let first = presses.pressed(.ready, project: nil)
        _ = presses.held(first.id)
        _ = presses.ended(.finishListening)
        _ = presses.pressed(.ready, project: nil)

        #expect(presses.ended(.openTypingBox) == .discardThenType)
        // The typing box replaced Listening…; the earlier press leaves it alone.
        #expect(presses.transcribed(first.id, "email Sam") == .add(showAdding: false))
        #expect(presses.added(first.id) == false)
    }

    @Test func aStaleHoldTimerIsIgnored() {
        var presses = VoicePresses()
        let first = presses.pressed(.ready, project: nil)
        _ = presses.ended(.openTypingBox)
        let second = presses.pressed(.ready, project: nil)

        #expect(presses.held(first.id) == .ignore)
        #expect(presses.held(second.id) == .showListening(second))
    }
}

/// One recording's transcript: the words heard are kept whatever ends recognition.
@Suite struct VoiceTranscriptTests {
    @Test func partialsShowWhileRecordingAndTheFinalIsDeliveredOnRelease() {
        var transcript = VoiceTranscript()
        #expect(transcript.received("email", isFinal: false) == [.showPartial("email")])
        #expect(transcript.received("email Sam", isFinal: false) == [.showPartial("email Sam")])

        #expect(transcript.finish() == .stopAudio)
        #expect(transcript.received("Email Sam", isFinal: true) == [.deliver("Email Sam")])
    }

    @Test func finalisingMidHoldStopsTheMicAndKeepsTheWordsForRelease() {
        var transcript = VoiceTranscript()
        _ = transcript.received("email Sam", isFinal: false)

        #expect(transcript.received("Email Sam", isFinal: true) == [.showPartial("Email Sam"), .stopAudio])
        #expect(transcript.received("late", isFinal: false) == [])
        #expect(transcript.finish() == .deliver("Email Sam"))
    }

    @Test func anErrorMidHoldStopsTheMicAndKeepsThePartial() {
        var transcript = VoiceTranscript()
        _ = transcript.received("email Sam", isFinal: false)

        // An error arrives as a final result with no text.
        #expect(transcript.received(nil, isFinal: true) == [.stopAudio])
        #expect(transcript.finish() == .deliver("email Sam"))
    }

    @Test func anEmptyFinalDoesNotReplaceTheWordsHeard() {
        var transcript = VoiceTranscript()
        _ = transcript.received("email Sam", isFinal: false)
        _ = transcript.finish()

        #expect(transcript.received("", isFinal: true) == [.deliver("email Sam")])
    }

    @Test func noFinalInTimeDeliversTheWordsHeardOnce() {
        var transcript = VoiceTranscript()
        _ = transcript.received("email Sam", isFinal: false)
        _ = transcript.finish()

        #expect(transcript.timedOut() == .deliver("email Sam"))
        #expect(transcript.timedOut() == nil)
        #expect(transcript.received("email Sam", isFinal: true) == [])
    }

    @Test func aCancelledRecordingDeliversNothing() {
        var transcript = VoiceTranscript()
        _ = transcript.received("email", isFinal: false)
        transcript.cancel()

        #expect(transcript.received("email Sam", isFinal: true) == [])
        #expect(transcript.finish() == nil)
    }
}
