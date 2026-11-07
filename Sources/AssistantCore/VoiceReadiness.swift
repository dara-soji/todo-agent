import Foundation

/// One OS permission voice needs (microphone, speech recognition), as the helper reads it.
public enum VoicePermission: Equatable, Sendable {
    case authorized, notDetermined, denied, restricted
}

/// Why holding ⌥Space can't record: the typing box opens instead, with `message` as one line that
/// opens `settingsURL` when clicked.
public enum VoiceUnavailable: Equatable, Sendable {
    case microphoneDenied
    case speechRecognitionDenied
    /// No on-device recognizer for the system locale. Voice never uses the cloud recognizer instead.
    case onDeviceRecognitionUnavailable(locale: String)
    /// No audio input device, or it wouldn't start.
    case noMicrophone
    /// Run outside the bundled app, which alone carries the usage descriptions macOS needs to ask.
    case notBundled

    public var message: String {
        switch self {
        case .microphoneDenied: "Voice needs microphone access → Open Settings"
        case .speechRecognitionDenied: "Voice needs speech recognition access → Open Settings"
        case .onDeviceRecognitionUnavailable(let locale): "Voice needs on-device dictation for \(locale) → Open Settings"
        case .noMicrophone: "Voice needs a microphone → Open Settings"
        case .notBundled: "Voice needs the bundled app (scripts/build-app.sh)"
        }
    }

    /// The System Settings pane that fixes it; nil when no pane can.
    public var settingsURL: URL? {
        let pane = switch self {
        case .microphoneDenied: "com.apple.preference.security?Privacy_Microphone"
        case .speechRecognitionDenied: "com.apple.preference.security?Privacy_SpeechRecognition"
        // Keyboard › Dictation is where a language's on-device speech model is chosen and downloaded.
        case .onDeviceRecognitionUnavailable: "com.apple.Keyboard-Settings.extension"
        case .noMicrophone: "com.apple.Sound-Settings.extension?input"
        case .notBundled: String?.none
        }
        return pane.flatMap { URL(string: "x-apple.systempreferences:\($0)") }
    }
}

/// Whether a press can record. Denials are checked first (asking is pointless if the other one
/// already rules voice out); undecided permissions are asked for one at a time, and that press
/// falls back to typing; then the locale must have an on-device recognizer.
public enum VoiceReadiness: Equatable, Sendable {
    case ready
    case askForMicrophone
    case askForSpeechRecognition
    case unavailable(VoiceUnavailable)

    public init(
        microphone: VoicePermission, speechRecognition: VoicePermission, canAsk: Bool,
        onDeviceRecognition: Bool, locale: String
    ) {
        if microphone == .denied || microphone == .restricted {
            self = .unavailable(.microphoneDenied)
        } else if speechRecognition == .denied || speechRecognition == .restricted {
            self = .unavailable(.speechRecognitionDenied)
        } else if microphone == .notDetermined || speechRecognition == .notDetermined {
            self = !canAsk ? .unavailable(.notBundled) : microphone == .notDetermined ? .askForMicrophone : .askForSpeechRecognition
        } else if !onDeviceRecognition {
            self = .unavailable(.onDeviceRecognitionUnavailable(locale: locale))
        } else {
            self = .ready
        }
    }
}

/// The one line the typing box shows when a hold couldn't record; clicking it opens `settingsURL`.
public struct VoiceNotice: Equatable, Sendable {
    public let message: String
    public let settingsURL: URL?

    public init(message: String, settingsURL: URL? = nil) {
        self.message = message
        self.settingsURL = settingsURL
    }
}

extension VoiceReadiness {
    /// What the typing box says when this hold opened it instead of recording; nil when ready.
    public var notice: VoiceNotice? {
        switch self {
        case .ready: nil
        // macOS's prompt is up; this press types, the next hold records.
        case .askForMicrophone, .askForSpeechRecognition:
            VoiceNotice(message: "macOS is asking for access · the next hold will record")
        case .unavailable(let cause): VoiceNotice(message: cause.message, settingsURL: cause.settingsURL)
        }
    }
}
