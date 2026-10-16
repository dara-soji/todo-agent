import AppKit
import CryptoKit
import Foundation
import Network

/// Signs in to Dara's own Google OAuth desktop client (ADR 0003): the browser, a one-shot loopback
/// listener on 127.0.0.1 and PKCE. Asks only for gmail.readonly and spreadsheets.readonly. The client and the refresh token
/// live in the Keychain; the access token only in memory, refreshed as it runs out.
@MainActor
final class GoogleAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/spreadsheets.readonly"
    private static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    /// How long the browser sign-in may take.
    private static let signInTimeout: TimeInterval = 5 * 60

    struct Client: Codable {
        let id: String
        let secret: String
    }

    enum Failure: Error, CustomStringConvertible {
        case notConnected
        case cancelled
        case denied(String)
        case stateMismatch
        case token(Int, String)

        var description: String {
            switch self {
            case .notConnected: "Gmail isn't connected"
            case .cancelled: "Sign-in timed out or was cancelled"
            case let .denied(reason): "Google said no: \(reason)"
            case .stateMismatch: "The sign-in reply didn't match this request"
            case let .token(status, error): "Google token error \(status) \(error)"
            }
        }
    }

    private let clientItem = KeychainItem(account: "google-oauth-client")
    private let refreshItem = KeychainItem(account: "google-refresh-token")
    private var accessToken: (value: String, expires: Date)?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isConnected: Bool {
        ((try? refreshItem.read()) ?? nil)?.isEmpty == false && client != nil
    }

    var client: Client? {
        guard let json = (try? clientItem.read()) ?? nil else { return nil }
        return try? JSONDecoder().decode(Client.self, from: Data(json.utf8))
    }

    func saveClient(_ client: Client) throws {
        try clientItem.write(String(decoding: try JSONEncoder().encode(client), as: UTF8.self))
    }

    /// Forgets the refresh token; Gmail stays unread until Dara connects again.
    func disconnect() {
        refreshItem.delete()
        accessToken = nil
    }

    /// A valid access token, refreshed if it has run out.
    func token() async throws -> String {
        if let accessToken, accessToken.expires > Date().addingTimeInterval(60) { return accessToken.value }
        guard let client, let refresh = (try? refreshItem.read()) ?? nil, !refresh.isEmpty else { throw Failure.notConnected }
        do {
            return try keep(try await post([
                "client_id": client.id, "client_secret": client.secret, "refresh_token": refresh,
                "grant_type": "refresh_token",
            ]))
        } catch Failure.token(_, "invalid_grant") {
            // The grant was revoked or expired: Dara needs to connect again.
            disconnect()
            throw Failure.notConnected
        }
    }

    /// The browser sign-in. On success the refresh token is in the Keychain.
    func signIn() async throws {
        guard let client else { throw Failure.notConnected }
        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(bytes: 16)

        let listener = try LoopbackListener()
        defer { listener.stop() }
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)"
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: client.id), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state), .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(components.url!)

        let reply = try await listener.awaitRedirect(timeout: Self.signInTimeout)
        guard reply["state"] == state else { throw Failure.stateMismatch }
        if let error = reply["error"] { throw Failure.denied(error) }
        guard let code = reply["code"] else { throw Failure.cancelled }
        let json = try await post([
            "client_id": client.id, "client_secret": client.secret, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirect,
        ])
        guard let refresh = json["refresh_token"] as? String else { throw Failure.token(200, "no_refresh_token") }
        try refreshItem.write(refresh)
        _ = try keep(json)
    }

    private func keep(_ json: [String: Any]) throws -> String {
        guard let token = json["access_token"] as? String else { throw Failure.token(200, "no_access_token") }
        let lifetime = json["expires_in"] as? Double ?? 3600
        accessToken = (token, Date().addingTimeInterval(lifetime))
        return token
    }

    private func post(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let error = json["error"] as? String ?? "unknown"
            NSLog("TodoAgent: Google token \(status) \(error)")
            throw Failure.token(status, error)
        }
        return json
    }

    private static func randomURLSafe(bytes: Int) -> String {
        base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Listens on 127.0.0.1 only, for the one redirect the browser makes after sign-in.
@MainActor
private final class LoopbackListener {
    private let listener: NWListener
    private var redirect: CheckedContinuation<[String: String], Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak listener] state in
                MainActor.assumeIsolated {
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: listener?.port?.rawValue ?? 0)
                    case let .failed(error):
                        resumed = true
                        continuation.resume(throwing: error)
                    case .cancelled:
                        resumed = true
                        continuation.resume(throwing: GoogleAuth.Failure.cancelled)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.handle(connection) }
            }
            listener.start(queue: .main)
        }
    }

    func awaitRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            redirect = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(.failure(GoogleAuth.Failure.cancelled)) }
            }
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        finish(.failure(GoogleAuth.Failure.cancelled))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                // "GET /?code=…&state=… HTTP/1.1"
                let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let items = URLComponents(string: target)?.queryItems ?? []
                let page = "<html><body style=\"font-family:-apple-system\">You can close this tab and go back to TodoAgent.</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                // A favicon or stray request carries no state: keep waiting for the real one.
                guard items.contains(where: { $0.name == "state" }) else { return }
                self?.finish(.success(Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })))
            }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let redirect else { return }
        self.redirect = nil
        redirect.resume(with: result)
    }
}
