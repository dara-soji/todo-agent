import AVFoundation
import Foundation
import Speech

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
    /// False when voice can't run (no permission yet, or no on-device recognizer for the locale);
    /// the caller falls back to the typing box.
    func begin() -> Bool {
        cancel()
        guard Self.isPermitted, let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return false }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return false }  // no microphone
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.feeding(request))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        self.request = request
        transcript = ""
        session += 1
        recognition = recognizer.recognitionTask(with: request, resultHandler: Self.delivering(to: self, session: session))
        return true
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

    /// Both permissions granted. Undecided ones are asked for here (only from the bundled app,
    /// whose Info.plist explains why), and this press falls back to typing.
    private static var isPermitted: Bool {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if microphone == .authorized && speech == .authorized { return true }
        // Without the usage descriptions macOS would kill the process for asking.
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["NSMicrophoneUsageDescription"] != nil, info["NSSpeechRecognitionUsageDescription"] != nil else {
            return false
        }
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if speech == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
        return false
    }
}
