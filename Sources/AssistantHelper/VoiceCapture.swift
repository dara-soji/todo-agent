import AVFoundation
import Foundation
import Speech
import AssistantCore

/// Push-to-talk speech-to-text: microphone audio into Apple's on-device recognizer in the system
/// locale. Audio goes from the tap straight to the recognizer in memory; it is never written to disk
/// and never sent to a cloud speech service.
///
/// Each press gets its own `Recording`. Only the live one has the microphone; a released one keeps
/// waiting for its final result while a new press records, so an earlier recording is never dropped.
@MainActor
final class VoiceCapture {
    private let engine = AVAudioEngine()
    /// The recording that has the microphone, from `begin()` until `finish` or `cancel`.
    private var live: Recording?
    /// Released recordings still waiting for their final result, kept alive until they deliver.
    private var finishing: [Recording] = []
    /// Called on the main thread with the live recording's transcript so far.
    var onPartial: (String) -> Void = { _ in }

    /// What has been heard so far by the live recording.
    var transcript: String { live?.state.text ?? "" }

    /// Starts capturing at once, so the first word survives the wait to tell a tap from a hold.
    /// Otherwise names why voice can't run; the caller falls back to the typing box.
    /// Nothing is asked for here, since a tap shouldn't prompt: see `askForPermission()`.
    func begin() -> VoiceReadiness {
        // A press always ends in `finish` or `cancel`; this is only a safety net.
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
        let recording = Recording(recognizer: recognizer, request: request)
        recording.capture = self
        live = recording
        recording.task = recognizer.recognitionTask(with: request, resultHandler: Self.delivering(to: recording))
        return .ready
    }

    /// Shows macOS's prompts for the permissions `begin()` found undecided, microphone then speech
    /// recognition. Called on a hold, so the first hold asks; that press types, the next one records.
    /// Nonisolated: macOS calls back on its own queue, so no callback may inherit main-actor isolation.
    nonisolated static func askForPermission(_ readiness: VoiceReadiness) {
        switch readiness {
        case .askForMicrophone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                guard granted else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { askForSpeechRecognitionIfUndecided() }
                }
            }
        case .askForSpeechRecognition: askForSpeechRecognitionIfUndecided()
        default: break
        }
    }

    private nonisolated static func askForSpeechRecognitionIfUndecided() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    /// Stops listening and hands over the live recording's transcript ("" if nothing was heard).
    /// It finishes on its own: a new `begin()` doesn't drop it.
    func finish(_ completion: @escaping (String) -> Void) {
        guard let recording = live else { return completion("") }
        live = nil
        recording.completion = completion
        finishing.append(recording)
        recording.apply(recording.state.finish().map { [$0] } ?? [.deliver(recording.state.text)])
    }

    /// Drops whatever the live recording captured, e.g. on a tap.
    func cancel() {
        guard let recording = live else { return }
        live = nil
        stopAudio()
        recording.state.cancel()
        recording.end()
    }

    fileprivate func stopAudio(for recording: Recording) {
        // A finishing recording has already given up the mic, perhaps to a newer press.
        guard live === recording || live == nil else { return }
        stopAudio()
    }

    private func stopAudio() {
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    fileprivate func ended(_ recording: Recording) {
        finishing.removeAll { $0 === recording }
        if live === recording { live = nil }
    }

    /// One press's recognition. Holds its recognizer for as long as its task runs.
    @MainActor
    fileprivate final class Recording {
        private var recognizer: SFSpeechRecognizer?
        private var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var state = VoiceTranscript()
        var completion: ((String) -> Void)?
        weak var capture: VoiceCapture?
        private var timeout: Timer?

        init(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest) {
            self.recognizer = recognizer
            self.request = request
        }

        func received(_ text: String?, isFinal: Bool) {
            apply(state.received(text, isFinal: isFinal))
        }

        func apply(_ effects: [VoiceTranscript.Effect]) {
            for effect in effects {
                switch effect {
                case .showPartial(let text):
                    if capture?.live === self { capture?.onPartial(text) }
                case .stopAudio:
                    capture?.stopAudio(for: self)
                    request?.endAudio()
                    if completion != nil { startTimeout() }
                case .deliver(let text):
                    let completion = self.completion
                    end()
                    completion?(text)
                }
            }
        }

        /// The final result normally follows within a moment; don't wait on it forever.
        private func startTimeout() {
            timeout = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let effect = self.state.timedOut() else { return }
                    self.apply([effect])
                }
            }
        }

        func end() {
            timeout?.invalidate()
            timeout = nil
            task?.cancel()
            task = nil
            request = nil
            recognizer = nil
            completion = nil
            capture?.ended(self)
        }
    }

    // Built outside the main actor: the tap runs on the audio thread and results arrive on a
    // background queue, so neither closure may inherit main-actor isolation.

    private nonisolated static func feeding(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func delivering(to recording: Recording) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak recording] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? (error != nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { recording?.received(text, isFinal: isFinal) }
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
