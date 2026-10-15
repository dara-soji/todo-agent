import AppKit
import AssistantCore
import Carbon.HIToolbox

/// Makes the screenshot guesses the core asks for: checks the window is still the one in front and
/// safe to capture, takes one shot, asks Haiku, and hands the answer back. The shot lives in memory
/// for that one request.
@MainActor
final class GuessMaker {
    private let assistant: Assistant
    private let deliver: (Signal) -> Void

    init(assistant: Assistant, deliver: @escaping (Signal) -> Void) {
        self.assistant = assistant
        self.deliver = deliver
    }

    /// Called after every Signal. Without an API key nothing is asked, so rules alone run Now.
    func check() {
        guard let apiKey = ClaudeAPIKey.load(), let request = assistant.takeGuessRequest() else { return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == request.key.bundleID,
              !assistant.excludesApp(request.key.bundleID), !IsSecureEventInputEnabled()
        else {
            deliver(.projectGuess(key: request.key, project: nil))
            return
        }
        let pid = front.processIdentifier
        let now = Date()
        _Concurrency.Task {
            var project: Project.ID?
            if let shot = try? await WindowCapture.png(pid: pid, title: request.key.title) {
                let (answer, call) = await ClaudeClient(apiKey: apiKey).guessProject(screenshot: shot, request: request, at: now)
                project = answer
                if let call { assistant.recordAPICall(call) }
            }
            deliver(.projectGuess(key: request.key, project: project))
        }
    }
}
