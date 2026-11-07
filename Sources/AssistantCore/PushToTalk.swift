import Foundation

/// Tells a tap of the quick-add shortcut from a hold. Audio buffers from the press, so a hold
/// keeps its first word; a release within `holdThreshold` is a tap and opens the typing box.
/// The helper feeds it key presses, releases and a timer's `holdCheck`; time comes from the clock.
public struct PushToTalk {
    public static let holdThreshold: TimeInterval = 0.3
    /// Longest recording, from the press. At the cap the press ends as if the key had been released.
    public static let recordingCap: TimeInterval = 60

    public enum Action: Equatable, Sendable {
        /// Key pressed: start capturing audio, but don't show or sound anything yet.
        case startBuffering
        /// Held past the threshold: play the start sound and show "Listening…".
        case startListening
        /// Released as a tap: discard the audio and open the typing box.
        case openTypingBox
        /// Released after a hold: stop recording and add what was heard.
        case finishListening
    }

    private let clock: WallClock
    /// When the current press becomes a hold; nil while the key is up.
    private var holdsAt: Date?
    private var listening = false

    public init(clock: WallClock) {
        self.clock = clock
    }

    public var isDown: Bool { holdsAt != nil }

    /// Nil for a repeated press while the key is already down.
    public mutating func keyDown() -> Action? {
        guard holdsAt == nil else { return nil }
        holdsAt = clock.now + Self.holdThreshold
        listening = false
        return .startBuffering
    }

    /// Call once the threshold may have passed (e.g. from a timer). `.startListening` comes at most once per press.
    public mutating func holdCheck() -> Action? {
        guard !listening, isHeld else { return nil }
        listening = true
        return .startListening
    }

    /// Call once the cap may have passed (e.g. from a timer). At the cap the press ends with
    /// `.finishListening`, and the real release that follows is ignored.
    public mutating func capCheck() -> Action? {
        guard let holdsAt, clock.now >= holdsAt - Self.holdThreshold + Self.recordingCap else { return nil }
        self.holdsAt = nil
        listening = false
        return .finishListening
    }

    /// Nil for a release with no press, or the one after the cap ended its press.
    public mutating func keyUp() -> Action? {
        guard holdsAt != nil else { return nil }
        let hold = listening || isHeld
        holdsAt = nil
        listening = false
        return hold ? .finishListening : .openTypingBox
    }

    private var isHeld: Bool {
        guard let holdsAt else { return false }
        return clock.now >= holdsAt
    }
}
