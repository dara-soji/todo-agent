import AVFoundation
import Foundation
import Speech
import AssistantCore

/// Push-to-talk speech-to-text: microphone audio into Apple's on-device recognizer in the system
/// locale. Audio goes from the tap straight to the recognizer in memory; it is never written to disk
/// and never sent to a cloud speech service.
@MainActor
final class VoiceCapture {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    /// What has been heard so far this press.
    private(set) var transcript = ""
    private var finished: ((String) -> Void)?
    private var finishTimeout: Timer?
    /// Tells this press's results from late ones of a press already cancelled.
    private var session = 0
    /// Called on the main thread with the transcript so far.
    var onPartial: (String) -> Void = { _ in }

    /// Starts capturing at once, so the first word survives the wait to tell a tap from a hold.
    /// Otherwise names why voice can't run; the caller falls back to the typing box.
    /// Nothing is asked for here, since a tap shouldn't prompt: see `askForPermission()`.
    func begin() -> VoiceReadiness {
        cancel()
        let recognizer = SFSpeechRecognizer(locale: .current)
        let readiness = VoiceReadiness(
            microphone: Self.permission(AVCaptureDevice.authorizationStatus(for: .audio)),
            speechRecognition: Self.permission(SFSpeechRecognizer.authorizationStatus()),
            canAsk: Self.canAsk,
            onDeviceRecognition: recognizer.map { $0.isAvailable && $0.supportsOnDeviceRecognition } ?? false,
            locale: Locale.current.identifier)
        guard readiness == .ready, let recognizer else { return readiness }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return .unavailable(.noMicrophone) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.feeding(request))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return .unavailable(.noMicrophone)
        }
        self.request = request
        transcript = ""
        session += 1
        recognition = recognizer.recognitionTask(with: request, resultHandler: Self.delivering(to: self, session: session))
        return .ready
    }

    /// Shows macOS's prompts for the permissions `begin()` found undecided, microphone then speech
    /// recognition. Called on a hold, so the first hold asks; that press types, the next one records.
    static func askForPermission(_ readiness: VoiceReadiness) {
        switch readiness {
        case .askForMicrophone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted, SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                    SFSpeechRecognizer.requestAuthorization { _ in }
                }
            }
        case .askForSpeechRecognition: SFSpeechRecognizer.requestAuthorization { _ in }
        default: break
        }
    }

    /// Stops listening and hands over the final transcript ("" if nothing was heard).
    func finish(_ completion: @escaping (String) -> Void) {
        guard request != nil else { return completion("") }
        stopAudio()
        request?.endAudio()
        finished = completion
        // The final result normally follows within a moment; don't wait on it forever.
        finishTimeout = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliver() }
        }
    }

    /// Drops whatever was captured, e.g. on a tap.
    func cancel() {
        stopAudio()
        recognition?.cancel()
        finished = nil
        reset()
    }

    private func stopAudio() {
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func received(_ text: String?, isFinal: Bool, session: Int) {
        guard request != nil, session == self.session else { return }
        if let text {
            transcript = text
            if finished == nil { onPartial(text) }
        }
        if isFinal { deliver() }
    }

    private func deliver() {
        let completion = finished
        let text = transcript
        recognition?.cancel()
        reset()
        completion?(text)
    }

    private func reset() {
        finishTimeout?.invalidate()
        finishTimeout = nil
        request = nil
        recognition = nil
        finished = nil
    }

    // Built outside the main actor: the tap runs on the audio thread and results arrive on a
    // background queue, so neither closure may inherit main-actor isolation.

    private nonisolated static func feeding(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func delivering(to capture: VoiceCapture, session: Int) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak capture] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? (error != nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { capture?.received(text, isFinal: isFinal, session: session) }
            }
        }
    }

    /// Without the usage descriptions (e.g. `swift run`) macOS would kill the process for asking.
    private static var canAsk: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["NSMicrophoneUsageDescription"] != nil && info["NSSpeechRecognitionUsageDescription"] != nil
    }

    private static func permission(_ status: AVAuthorizationStatus) -> VoicePermission {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
    }

    private static func permission(_ status: SFSpeechRecognizerAuthorizationStatus) -> VoicePermission {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
    }
}
