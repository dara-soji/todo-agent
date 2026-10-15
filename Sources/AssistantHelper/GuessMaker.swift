import AssistantCore
import Foundation

/// Runs the core's GuessRunner after each Signal, with the real screenshot and model adapters.
/// Without an API key nothing is asked, so rules alone run Now.
@MainActor
final class GuessMaker {
    private let runner: GuessRunner
    private var running = false
    var onChange: () -> Void = {}

    init(assistant: Assistant) {
        runner = GuessRunner(
            assistant: assistant, capturer: WindowCapture(excludesApp: { assistant.excludesApp($0) }),
            model: ClaudeClient(apiKey: { ClaudeAPIKey.load() }))
    }

    func check() {
        guard !running, ClaudeAPIKey.load() != nil else { return }
        running = true
        _Concurrency.Task {
            await runner.run()
            running = false
            onChange()
        }
    }
}
