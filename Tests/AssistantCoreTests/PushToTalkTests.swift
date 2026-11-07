import Foundation
import Testing
import AssistantCore
import AssistantTestSupport

@Suite struct PushToTalkTests {
    let clock = FakeClock()

    @Test func pressingStartsBufferingAtOnce() {
        var talk = PushToTalk(clock: clock)
        #expect(talk.keyDown() == .startBuffering)
        #expect(talk.isDown)
    }

    @Test func releasingWithin300msIsATap() {
        var talk = PushToTalk(clock: clock)
        _ = talk.keyDown()
        clock.advance(seconds: 0.299)
        #expect(talk.holdCheck() == nil)
        #expect(talk.keyUp() == .openTypingBox)
        #expect(!talk.isDown)
    }

    @Test func holdingPast300msStartsListeningOnce() {
        var talk = PushToTalk(clock: clock)
        _ = talk.keyDown()
        clock.advance(seconds: 0.3)
        #expect(talk.holdCheck() == .startListening)
        clock.advance(seconds: 0.5)
        #expect(talk.holdCheck() == nil)
        #expect(talk.keyUp() == .finishListening)
    }

    @Test func aLongHoldReleasedWithoutACheckStillCountsAsAHold() {
        // The release can arrive before the hold timer fires; the clock decides, not the timer.
        var talk = PushToTalk(clock: clock)
        _ = talk.keyDown()
        clock.advance(seconds: 2)
        #expect(talk.keyUp() == .finishListening)
    }

    @Test func aRepeatedPressWhileDownIsIgnored() {
        var talk = PushToTalk(clock: clock)
        _ = talk.keyDown()
        clock.advance(seconds: 0.2)
        #expect(talk.keyDown() == nil)
        clock.advance(seconds: 0.15)
        #expect(talk.keyUp() == .finishListening)
    }

    @Test func aReleaseWithoutAPressDoesNothing() {
        var talk = PushToTalk(clock: clock)
        #expect(talk.keyUp() == nil)
    }

    @Test func eachPressIsClassifiedOnItsOwn() {
        var talk = PushToTalk(clock: clock)
        _ = talk.keyDown()
        clock.advance(seconds: 1)
        _ = talk.holdCheck()
        #expect(talk.keyUp() == .finishListening)
        _ = talk.keyDown()
        clock.advance(seconds: 0.1)
        #expect(talk.holdCheck() == nil)
        #expect(talk.keyUp() == .openTypingBox)
    }
}

@Suite struct PushToTalkCapTests {
    let clock = FakeClock()

    @Test func recordingStopsAt60sAsIfReleased() {
        var talk = PushToTalk(clock: clock)
        _ = talk.keyDown()
        clock.advance(seconds: 0.3)
        _ = talk.holdCheck()
        clock.advance(seconds: 59.6)
        #expect(talk.capCheck() == nil)
        clock.advance(seconds: 0.1)
        #expect(talk.capCheck() == .finishListening)
        #expect(!talk.isDown)
    }

    @Test func theRealReleaseAfterTheCapDoesNothing() {
        var talk = PushToTalk(clock: clock)
        _ = talk.keyDown()
        clock.advance(seconds: 61)
        #expect(talk.capCheck() == .finishListening)
        clock.advance(seconds: 5)
        #expect(talk.keyUp() == nil)
        #expect(talk.capCheck() == nil)
    }

    @Test func theCapDoesNotFireWithTheKeyUp() {
        var talk = PushToTalk(clock: clock)
        #expect(talk.capCheck() == nil)
        _ = talk.keyDown()
        clock.advance(seconds: 1)
        #expect(talk.keyUp() == .finishListening)
        clock.advance(seconds: 60)
        #expect(talk.capCheck() == nil)
    }

    @Test func aNewPressAfterTheCapStartsAfresh() {
        var talk = PushToTalk(clock: clock)
        _ = talk.keyDown()
        clock.advance(seconds: 60)
        _ = talk.capCheck()
        _ = talk.keyUp()  // the stale release
        #expect(talk.keyDown() == .startBuffering)
        clock.advance(seconds: 0.1)
        #expect(talk.keyUp() == .openTypingBox)
    }
}
