import AssistantCore
import Foundation

/// The model port over the Messages API, by raw HTTP (there is no Swift SDK). It sends the
/// screenshot and the choices, and throws for anything that isn't an answer. Nothing it sends or
/// receives is logged; failures log only the HTTP status and error type.
@MainActor
final class ClaudeClient: ModelClient {
    static let guessModel = "claude-haiku-5-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    enum Failure: Error {
        case http(Int, String)
        /// A refusal, or an answer cut off by max_tokens: no answer to read.
        case noAnswer(String)
        case unreadable
    }

    private let apiKey: () -> String?
    private let session: URLSession

    init(apiKey: @escaping () -> String?, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func chooseProject(screenshot: Data, choices: [String], none: String) async throws -> ModelAnswer {
        guard let key = apiKey() else { throw Failure.http(401, "no_api_key") }
        let body: [String: Any] = [
            "model": Self.guessModel,
            "max_tokens": 2048,
            // Low effort: a quick look. The answer must be exactly one of the labels.
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": ["project": ["type": "string", "enum": choices + [none]]],
                        "required": ["project"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "system": "You place a screenshot of one window into one of the user's Projects. Answer \"\(none)\" unless the window clearly belongs to one.",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png", "data": screenshot.base64EncodedString()]],
                    ["type": "text", "text": "Projects: \(choices.joined(separator: "; ")). Which Project is this window part of?"],
                ],
            ]],
        ]

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let type = (json["error"] as? [String: Any])?["type"] as? String ?? "unknown"
            NSLog("TodoAgent: Claude API \(status) \(type)")
            throw Failure.http(status, type)
        }

        let usage = json["usage"] as? [String: Any] ?? [:]
        let call = APICall(
            at: Date(), purpose: .projectGuess, model: Self.guessModel,
            inputTokens: usage["input_tokens"] as? Int ?? 0, outputTokens: usage["output_tokens"] as? Int ?? 0,
            contentKind: .screenshotAndProjectNames)
        // Check the stop reason before reading content: Haiku has no server-side fallback.
        let stopReason = json["stop_reason"] as? String ?? ""
        guard stopReason == "end_turn" else { throw Failure.noAnswer(stopReason) }
        guard let text = (json["content"] as? [[String: Any]] ?? []).first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let choice = answer["project"] as? String
        else { throw Failure.unreadable }
        return ModelAnswer(choice: choice, call: call)
    }
}
