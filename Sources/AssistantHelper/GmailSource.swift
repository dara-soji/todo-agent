import AssistantCore
import Foundation

/// The mailbox port over the Gmail REST API, read-only. The first run starts from the profile's
/// history id and reads the last three days of inbox mail; after that, history.list from the stored
/// cursor. Listing reads headers only; a body is read, into memory, only for mail Triage sends, and
/// never kept.
@MainActor
final class GmailSource: MailSource {
    private static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    /// How far back the very first run looks.
    static let firstRunQuery = "in:inbox newer_than:3d"
    /// The most messages the first run reads.
    static let firstRunLimit = 200
    /// More plain text than Triage sends; the core cuts it down.
    static let textLimit = 8_192

    enum Failure: Error {
        case http(Int)
    }

    private let auth: GoogleAuth
    private let session: URLSession

    init(auth: GoogleAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func fetchNew(after cursor: String?) async throws -> MailBatch {
        if let cursor {
            do {
                return try await sinceHistory(cursor)
            } catch Failure.http(404) {
                // The cursor is older than Gmail keeps history for: start again from three days back.
                NSLog("TodoAgent: Gmail history cursor expired; starting from three days back")
            }
        }
        return try await firstRun()
    }

    private func firstRun() async throws -> MailBatch {
        // The cursor comes first, so mail arriving while this runs is read next time.
        let profile = try await get("profile")
        guard let history = profile["historyId"] as? String else { throw Failure.http(0) }
        var ids: [String] = []
        var page: String?
        repeat {
            var query = [URLQueryItem(name: "q", value: Self.firstRunQuery), URLQueryItem(name: "maxResults", value: "100")]
            if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
            let json = try await get("messages", query)
            ids += (json["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            page = json["nextPageToken"] as? String
        } while page != nil && ids.count < Self.firstRunLimit
        if page != nil || ids.count > Self.firstRunLimit {
            NSLog("TodoAgent: first Gmail run read the newest \(Self.firstRunLimit) inbox messages only")
        }
        return MailBatch(messages: try await messages(Array(ids.prefix(Self.firstRunLimit))), cursor: history)
    }

    private func sinceHistory(_ cursor: String) async throws -> MailBatch {
        var ids: [String] = []
        var latest = cursor
        var page: String?
        repeat {
            var query = [
                URLQueryItem(name: "startHistoryId", value: cursor), URLQueryItem(name: "historyTypes", value: "messageAdded"),
                URLQueryItem(name: "labelId", value: "INBOX"),
            ]
            if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
            let json = try await get("history", query)
            for record in json["history"] as? [[String: Any]] ?? [] {
                for added in record["messagesAdded"] as? [[String: Any]] ?? [] {
                    if let id = (added["message"] as? [String: Any])?["id"] as? String, !ids.contains(id) { ids.append(id) }
                }
            }
            if let history = json["historyId"] as? String { latest = history }
            page = json["nextPageToken"] as? String
        } while page != nil
        return MailBatch(messages: try await messages(ids), cursor: latest)
    }

    func plainText(of message: EmailMessage) async throws -> String {
        let json = try await get("messages/\(message.messageID)", [URLQueryItem(name: "format", value: "full")])
        return String(Self.text(in: json["payload"] as? [String: Any] ?? [:]).prefix(Self.textLimit))
    }

    /// Each message's headers and labels, oldest first. One deleted since it was listed is skipped.
    private func messages(_ ids: [String]) async throws -> [EmailMessage] {
        let metadata = [URLQueryItem(name: "format", value: "metadata")]
            + ["From", "Subject", "List-Unsubscribe"].map { URLQueryItem(name: "metadataHeaders", value: $0) }
        var messages: [EmailMessage] = []
        for id in ids {
            do {
                messages.append(Self.message(try await get("messages/\(id)", metadata)))
            } catch Failure.http(404) {
                continue
            }
        }
        return messages.sorted { $0.receivedAt < $1.receivedAt }
    }

    static func message(_ json: [String: Any]) -> EmailMessage {
        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = (payload["headers"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) { headers, header in
            if let name = header["name"] as? String, let value = header["value"] as? String { headers[name.lowercased()] = value }
        }
        let received = (json["internalDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        return EmailMessage(
            threadID: json["threadId"] as? String ?? "", messageID: json["id"] as? String ?? "",
            from: headers["from"] ?? "", subject: headers["subject"] ?? "",
            labels: json["labelIds"] as? [String] ?? [], hasListUnsubscribe: headers["list-unsubscribe"] != nil,
            receivedAt: received)
    }

    /// The plain-text body, or the HTML one with its tags stripped. Attachments are skipped.
    static func text(in payload: [String: Any]) -> String {
        if let plain = part(in: payload, mimeType: "text/plain") { return plain }
        guard let html = part(in: payload, mimeType: "text/html") else { return "" }
        return html
            .replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func part(in payload: [String: Any], mimeType: String) -> String? {
        let filename = payload["filename"] as? String ?? ""
        if filename.isEmpty, payload["mimeType"] as? String == mimeType,
           let data = (payload["body"] as? [String: Any])?["data"] as? String, let decoded = base64URL(data) {
            return String(decoding: decoded, as: UTF8.self)
        }
        for child in payload["parts"] as? [[String: Any]] ?? [] {
            if let found = part(in: child, mimeType: mimeType) { return found }
        }
        return nil
    }

    private static func base64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    private func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            NSLog("TodoAgent: Gmail \(status) on \(path.hasPrefix("messages/") ? "messages.get" : path)")
            throw Failure.http(status)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
