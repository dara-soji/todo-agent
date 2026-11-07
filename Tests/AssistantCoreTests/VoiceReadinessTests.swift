import Foundation
import Testing
import AssistantCore

@Suite struct VoiceReadinessTests {
    private func readiness(
        microphone: VoicePermission = .authorized, speechRecognition: VoicePermission = .authorized,
        canAsk: Bool = true, onDevice: Bool = true
    ) -> VoiceReadiness {
        VoiceReadiness(
            microphone: microphone, speechRecognition: speechRecognition, canAsk: canAsk,
            onDeviceRecognition: onDevice, locale: "en_GB")
    }

    @Test func bothPermissionsAndAnOnDeviceRecognizerMeanReady() {
        #expect(readiness() == .ready)
    }

    @Test func undecidedPermissionsAreAskedForOneAtATime() {
        #expect(readiness(microphone: .notDetermined, speechRecognition: .notDetermined) == .askForMicrophone)
        #expect(readiness(speechRecognition: .notDetermined) == .askForSpeechRecognition)
    }

    @Test func aDeniedOrRestrictedPermissionNamesItsCause() {
        #expect(readiness(microphone: .denied) == .unavailable(.microphoneDenied))
        #expect(readiness(microphone: .restricted) == .unavailable(.microphoneDenied))
        #expect(readiness(speechRecognition: .denied) == .unavailable(.speechRecognitionDenied))
        #expect(readiness(speechRecognition: .restricted) == .unavailable(.speechRecognitionDenied))
    }

    @Test func aDenialWinsOverAnUndecidedPermission() {
        // No point asking for one when the other already rules voice out.
        #expect(readiness(microphone: .notDetermined, speechRecognition: .denied) == .unavailable(.speechRecognitionDenied))
    }

    @Test func withoutOnDeviceRecognitionThereIsNoVoice() {
        // Never the cloud recognizer instead.
        #expect(readiness(onDevice: false) == .unavailable(.onDeviceRecognitionUnavailable(locale: "en_GB")))
    }

    @Test func outsideTheBundledAppNothingIsAsked() {
        #expect(readiness(microphone: .notDetermined, canAsk: false) == .unavailable(.notBundled))
    }

    @Test func eachCauseHasAOneLineMessageAndASettingsPane() {
        #expect(VoiceUnavailable.microphoneDenied.message == "Voice needs microphone access → Open Settings")
        #expect(VoiceUnavailable.microphoneDenied.settingsURL
            == URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
        #expect(VoiceUnavailable.speechRecognitionDenied.message == "Voice needs speech recognition access → Open Settings")
        #expect(VoiceUnavailable.speechRecognitionDenied.settingsURL
            == URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"))
        let locale = VoiceUnavailable.onDeviceRecognitionUnavailable(locale: "en_GB")
        #expect(locale.message == "Voice needs on-device dictation for en_GB → Open Settings")
        #expect(locale.settingsURL == URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"))
        #expect(VoiceUnavailable.noMicrophone.message == "Voice needs a microphone → Open Settings")
        #expect(VoiceUnavailable.noMicrophone.settingsURL
            == URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input"))
        #expect(VoiceUnavailable.notBundled.settingsURL == nil)
        #expect(!VoiceUnavailable.notBundled.message.contains("Settings"))
    }

    @Test func silenceIsNothingHeard() {
        #expect(VoiceSplitRunner.heardNothing(""))
        #expect(VoiceSplitRunner.heardNothing(" \n\t "))
        #expect(!VoiceSplitRunner.heardNothing(" email Sam "))
    }
}

@Suite struct VoiceNoticeTests {
    @Test func anUndecidedHoldSaysMacOSIsAskingAndTheNextHoldRecords() throws {
        for readiness in [VoiceReadiness.askForMicrophone, .askForSpeechRecognition] {
            let notice = try #require(readiness.notice)
            #expect(notice.message == "macOS is asking for access · the next hold will record")
            #expect(notice.settingsURL == nil)
        }
    }

    @Test func anUnavailableHoldSaysWhyAndLinksToSettings() {
        let notice = VoiceReadiness.unavailable(.microphoneDenied).notice
        #expect(notice == VoiceNotice(message: VoiceUnavailable.microphoneDenied.message,
                                      settingsURL: VoiceUnavailable.microphoneDenied.settingsURL))
    }

    @Test func aReadyHoldHasNoNotice() {
        #expect(VoiceReadiness.ready.notice == nil)
    }
}
