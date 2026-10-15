import AppKit
import AssistantCore
import Foundation

/// Polls Gmail every few minutes, and on wake, and runs Triage over what is new. Only with Gmail
/// connected and a Claude API key: without the key nothing is read, so the cursor waits for it.
@MainActor
final class MailTriage {
    static let interval: TimeInterval = 5 * 60

    let auth = GoogleAuth()
    private let runner: TriageRunner
    private var timer: Timer?
    private var wake: NSObjectProtocol?
    var onChange: () -> Void = {}

    init(assistant: Assistant) {
        runner = TriageRunner(
            assistant: assistant, mail: GmailSource(auth: auth),
            triager: ClaudeClient(apiKey: { ClaudeAPIKey.load() }))
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.check() }
        }
        wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.check() }
        }
        check()
    }

    func check() {
        guard auth.isConnected, ClaudeAPIKey.load() != nil else { return }
        _Concurrency.Task {
            await runner.run()
            onChange()
        }
    }
}
