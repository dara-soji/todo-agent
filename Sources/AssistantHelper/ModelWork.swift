import AssistantCore
import Foundation

/// Runs the core's model-backed work after each Signal (screenshot guesses and Next tie-breaks)
/// with the real adapters, one at a time. Without an API key nothing is asked, so rules alone run.
@MainActor
final class ModelWork {
    private let guesses: GuessRunner
    private let tieBreaks: TieBreakRunner
    private var running = false
    var onChange: () -> Void = {}

    init(assistant: Assistant) {
        let client = ClaudeClient(apiKey: { ClaudeAPIKey.load() })
        guesses = GuessRunner(
            assistant: assistant, capturer: WindowCapture(excludesApp: { assistant.excludesApp($0) }), model: client)
        tieBreaks = TieBreakRunner(assistant: assistant, tieBreaker: client)
    }

    func check() {
        guard !running, ClaudeAPIKey.load() != nil else { return }
        running = true
        _Concurrency.Task {
            await guesses.run()
            await tieBreaks.run()
            running = false
            onChange()
        }
    }
}
