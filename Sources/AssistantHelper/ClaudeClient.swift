import AssistantCore
import Foundation

/// The Messages API over URLSession (there is no Swift SDK). Each call returns its answer, if any,
/// and the metadata the audit log keeps; no content is logged.
struct ClaudeClient {
    static let guessModel = "claude-haiku-5-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let apiKey: String
    var session: URLSession = .shared

    /// Which Project the screenshot shows, or nil for none, a refusal or any failure.
    func guessProject(screenshot: Data, request: GuessRequest, at now: Date) async -> (Project.ID?, APICall?) {
        let names = request.projects.map(\.name)
        let body: [String: Any] = [
            "model": Self.guessModel,
            "max_tokens": 2048,
            // Low effort: a quick look, not a deep think. The answer must be one name or "none".
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": ["project": ["type": "string", "enum": names + ["none"]]],
                        "required": ["project"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "system": """
                You place a screenshot of one window into one of the user's Projects, or none. Answer \
                "none" unless the window clearly belongs to a Project.
                """,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png", "data": screenshot.base64EncodedString()]],
                    ["type": "text", "text": "Projects: \(names.joined(separator: "; ")). Which Project is this window part of?"],
                ],
            ]],
        ]

        guard let response = await send(body) else { return (nil, nil) }
        let call = APICall(
            at: now, purpose: .projectGuess, model: Self.guessModel, inputTokens: response.inputTokens,
            outputTokens: response.outputTokens, contentKind: .screenshotAndProjectNames)
        // A refusal has no answer to read; Haiku has no server-side fallback.
        guard response.stopReason != "refusal",
              let answer = response.text.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }),
              let name = answer["project"] as? String
        else { return (nil, call) }
        return (request.projects.first { $0.name == name }?.id, call)
    }

    private struct Response {
        let stopReason: String?
        let text: String?
        let inputTokens: Int
        let outputTokens: Int
    }

    /// Nil on any transport or API error, logged by status and error type only.
    private func send(_ body: [String: Any]) async -> Response? {
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: urlRequest)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // 429 / 529 / 5xx are worth trying later; the guess simply isn't made this time.
                let type = (json["error"] as? [String: Any])?["type"] as? String ?? "unknown"
                NSLog("TodoAgent: Claude API \(status) \(type)")
                return nil
            }
            let usage = json["usage"] as? [String: Any] ?? [:]
            let text = (json["content"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "text" }?["text"] as? String
            return Response(
                stopReason: json["stop_reason"] as? String, text: text,
                inputTokens: usage["input_tokens"] as? Int ?? 0, outputTokens: usage["output_tokens"] as? Int ?? 0)
        } catch {
            NSLog("TodoAgent: Claude API unreachable (\((error as NSError).code))")
            return nil
        }
    }
}
