import AssistantCore
import Foundation

/// The model port over the Messages API, by raw HTTP (there is no Swift SDK). It sends the
/// screenshot and the choices, and throws for anything that isn't an answer. Nothing it sends or
/// receives is logged; failures log only the HTTP status and error type.
@MainActor
final class ClaudeClient: ModelClient, TieBreaker {
    static let guessModel = "claude-haiku-5-5"
    static let tieBreakModel = "claude-sonnet-5-5"
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

        let json = try await post(body, apiKey: key)
        let call = Self.call(json, purpose: .projectGuess, model: Self.guessModel, kind: .screenshotAndProjectNames)
        // Check the stop reason before reading content: Haiku has no server-side fallback.
        let answer = try Self.answer(json)
        guard let choice = answer["project"] as? String else { throw Failure.unreadable }
        return ModelAnswer(choice: choice, call: call)
    }

    /// Picks one of the tied Tasks with a one-line reason. Sonnet 5.5 at low effort, with the
    /// server-side refusal fallback on, as the API recommends for this model.
    func breakTie(_ request: TieBreakRequest) async throws -> TieBreakAnswer {
        guard let key = apiKey() else { throw Failure.http(401, "no_api_key") }
        let iso = ISO8601DateFormatter()
        let lines = request.candidates.map { candidate in
            var parts = ["\"\(candidate.label)\""]
            if let deadline = candidate.deadline { parts.append("due \(iso.string(from: deadline))") }
            if let effort = candidate.effort { parts.append("effort \(effort.rawValue)") }
            if let kind = candidate.kind { parts.append("\(kind.rawValue) work") }
            return "- " + parts.joined(separator: ", ")
        }
        let body: [String: Any] = [
            "model": Self.tieBreakModel,
            "max_tokens": 4096,
            "fallbacks": "default",
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": [
                            "task": ["type": "string", "enum": request.candidates.map(\.label)],
                            "reason": ["type": "string"],
                        ],
                        "required": ["task", "reason"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "system": """
                You choose which of a few equally ranked tasks the user should do next, and give one short \
                reason (under 10 words) they will read in a menu.
                """,
            "messages": [[
                "role": "user",
                "content": "It is \(request.timeOfDay). These tasks are tied:\n\(lines.joined(separator: "\n"))\nWhich one next?",
            ]],
        ]
        let json = try await post(body, apiKey: key, betas: ["server-side-fallback-2026-07-01"])
        let call = Self.call(json, purpose: .nextTieBreak, model: Self.tieBreakModel, kind: .taskTitles)
        let answer = try Self.answer(json)
        guard let task = answer["task"] as? String, let reason = answer["reason"] as? String else { throw Failure.unreadable }
        return TieBreakAnswer(choice: task, reason: reason, call: call)
    }

    // MARK: HTTP

    private func post(_ body: [String: Any], apiKey: String, betas: [String] = []) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty { request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let type = (json["error"] as? [String: Any])?["type"] as? String ?? "unknown"
            NSLog("TodoAgent: Claude API \(status) \(type)")
            throw Failure.http(status, type)
        }
        return json
    }

    /// The audit-log line for a response: metadata only.
    private static func call(_ json: [String: Any], purpose: APICall.Purpose, model: String, kind: APICall.ContentKind) -> APICall {
        let usage = json["usage"] as? [String: Any] ?? [:]
        return APICall(
            at: Date(), purpose: purpose, model: model,
            inputTokens: usage["input_tokens"] as? Int ?? 0, outputTokens: usage["output_tokens"] as? Int ?? 0,
            contentKind: kind)
    }

    /// The structured answer, once the stop reason says there is one: a refusal or a cut-off is not.
    private static func answer(_ json: [String: Any]) throws -> [String: Any] {
        let stopReason = json["stop_reason"] as? String ?? ""
        guard stopReason == "end_turn" else { throw Failure.noAnswer(stopReason) }
        guard let text = (json["content"] as? [[String: Any]] ?? []).first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw Failure.unreadable }
        return answer
    }
}
