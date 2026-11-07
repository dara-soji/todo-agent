import Foundation

/// One ⌥Space press, from key-down until its Tasks are added (or it ends as a tap or in the typing box).
public struct VoicePress: Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        let value: Int
    }

    public let id: ID
    /// Whether this press can record, or why not.
    public let readiness: VoiceReadiness
    /// Now's confident Project at key-down: the palette's heading while listening, and where
    /// spoken Tasks go unless a Project is named out loud.
    public let project: Project.ID?

    public var records: Bool { readiness == .ready }
}

/// The voice presses in play: the one the key is on, and earlier ones still finishing (final
/// transcript or split in flight). A new press never drops an earlier recording, and each
/// press's completion touches the palette only while that press still owns it.
public struct VoicePresses: Sendable {
    public enum Held: Equatable, Sendable {
        /// Play the start sound and show Listening… under the press's Project.
        case showListening(VoicePress)
        /// Voice can't run: ask macOS for what's undecided, and open the typing box saying so.
        case askThenType(VoiceReadiness)
        case ignore
    }

    public enum Ended: Equatable, Sendable {
        /// A tap: drop the audio and open the typing box.
        case discardThenType
        /// A hold: stop recording and add what was heard, to this press's Project.
        case finish(VoicePress)
        /// Held without voice and released before the hold timer opened the typing box.
        case askThenType(VoiceReadiness)
        case ignore
    }

    public enum Transcribed: Equatable, Sendable {
        /// Split and add it; show "Adding…" only if this press owns the palette.
        case add(showAdding: Bool)
        /// Nothing heard: nothing added; close the palette only if this press owns it.
        case drop(closePalette: Bool)
    }

    /// The press the key is on; nil once it has ended.
    public private(set) var down: VoicePress?
    /// The press whose Listening… (then Adding…) the palette shows.
    public private(set) var palette: VoicePress.ID?
    /// Released presses still finishing.
    public private(set) var inFlight: Set<VoicePress.ID> = []
    private var holdHandled = false
    private var last = 0

    public init() {}

    public mutating func pressed(_ readiness: VoiceReadiness, project: Project.ID?) -> VoicePress {
        last += 1
        let press = VoicePress(id: VoicePress.ID(value: last), readiness: readiness, project: project)
        down = press
        holdHandled = false
        return press
    }

    /// The hold timer fired for `id`. Acts at most once per press, and never for a press already over.
    public mutating func held(_ id: VoicePress.ID) -> Held {
        guard let down, down.id == id, !holdHandled else { return .ignore }
        holdHandled = true
        guard down.records else {
            palette = nil
            return .askThenType(down.readiness)
        }
        palette = id
        return .showListening(down)
    }

    /// The press the key is on ended: `action` is `PushToTalk`'s release or cap (nil: nothing to end).
    public mutating func ended(_ action: PushToTalk.Action?) -> Ended {
        guard let press = down, let action else { return .ignore }
        switch action {
        case .openTypingBox:
            down = nil
            palette = nil
            return .discardThenType
        case .finishListening:
            down = nil
            if press.records {
                inFlight.insert(press.id)
                return .finish(press)
            }
            guard !holdHandled else { return .ignore }
            palette = nil
            return .askThenType(press.readiness)
        case .startBuffering, .startListening:
            return .ignore
        }
    }

    /// The final transcript for `id` arrived.
    public mutating func transcribed(_ id: VoicePress.ID, _ transcript: String) -> Transcribed {
        guard !VoiceSplitRunner.heardNothing(transcript) else {
            inFlight.remove(id)
            return .drop(closePalette: releasePalette(id))
        }
        return .add(showAdding: palette == id)
    }

    /// `id`'s Tasks were added (or adding failed). True when it still owned the palette, which closes.
    public mutating func added(_ id: VoicePress.ID) -> Bool {
        inFlight.remove(id)
        return releasePalette(id)
    }

    private mutating func releasePalette(_ id: VoicePress.ID) -> Bool {
        guard palette == id else { return false }
        palette = nil
        return true
    }
}

/// One recording's transcript as the recognizer reports it. The words heard so far are kept
/// whatever ends recognition: if it finalises or fails while the key is still held, the mic stops
/// at once and those words are what the release adds.
public struct VoiceTranscript: Sendable {
    public enum Effect: Equatable, Sendable {
        case showPartial(String)
        /// Stop the microphone and audio tap.
        case stopAudio
        /// The recording is over: this is what was heard ("" for nothing). Comes at most once.
        case deliver(String)
    }

    private enum Phase {
        /// Key held, mic on.
        case recording
        /// Released, waiting for the final result.
        case finishing
        /// Recognition ended while the key was held; waiting for the release.
        case ended
        /// Delivered or cancelled.
        case over
    }

    public private(set) var text = ""
    private var phase = Phase.recording

    public init() {}

    public mutating func received(_ text: String?, isFinal: Bool) -> [Effect] {
        var effects: [Effect] = []
        if let text, !text.isEmpty, phase == .recording || phase == .finishing {
            self.text = text
            if phase == .recording { effects.append(.showPartial(text)) }
        }
        guard isFinal else { return effects }
        switch phase {
        case .recording:
            phase = .ended
            effects.append(.stopAudio)
        case .finishing:
            phase = .over
            effects.append(.deliver(self.text))
        case .ended, .over:
            break
        }
        return effects
    }

    /// Released: stop the mic and wait for the final result, or deliver at once when recognition
    /// already ended. Nil when the recording is already over.
    public mutating func finish() -> Effect? {
        switch phase {
        case .recording:
            phase = .finishing
            return .stopAudio
        case .ended:
            phase = .over
            return .deliver(text)
        case .finishing, .over:
            return nil
        }
    }

    /// The final result didn't come in time: deliver what was heard.
    public mutating func timedOut() -> Effect? {
        guard phase == .finishing else { return nil }
        phase = .over
        return .deliver(text)
    }

    public mutating func cancel() {
        phase = .over
    }
}
