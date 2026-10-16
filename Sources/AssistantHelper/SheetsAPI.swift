import AppKit
import AssistantCore
import Foundation

/// The Sheets port over the Google Sheets API, read-only (`spreadsheets.readonly`), asked only for
/// registered sheets. Reads the first tab. Cell values stay on the Mac.
@MainActor
final class SheetsAPI: SheetsSource {
    private static let base = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/")!
    /// The cells read from each sheet's first tab: every row, columns A to Z.
    static let range = "A:Z"

    enum Failure: Error {
        case http(Int)
    }

    private let auth: GoogleAuth
    private let session: URLSession
    /// Google said the token doesn't cover Sheets: the account was connected before Sheets were asked for.
    private(set) var needsReconnect = false
    /// Sheets that couldn't be read last time, and why, for the menu.
    private(set) var problems: [String: String] = [:]

    init(auth: GoogleAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func rows(of sheetID: String) async throws -> [SheetRow] {
        let json: [String: Any]
        do {
            json = try await get("\(sheetID)/values/\(Self.range)")
            problems[sheetID] = nil
        } catch Failure.http(let status) {
            problems[sheetID] = status == 403 || status == 404 ? "No access" : "Couldn't read (\(status))"
            throw Failure.http(status)
        }
        return (json["values"] as? [[Any]] ?? []).enumerated().map { index, cells in
            SheetRow(number: index + 1, cells: cells.map { "\($0)" })
        }
    }

    /// The spreadsheet's title, for naming it when it is registered.
    func title(of sheetID: String) async throws -> String {
        let json = try await get(sheetID, [URLQueryItem(name: "fields", value: "properties.title")])
        return (json["properties"] as? [String: Any])?["title"] as? String ?? sheetID
    }

    private func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let reasons = ((error?["error"] as? [String: Any])?["details"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
            NSLog("TodoAgent: Sheets \(status) \(reasons.joined(separator: ","))")
            // Only a token without the Sheets scope is fixed by reconnecting; a sheet not shared isn't.
            if status == 401 || reasons.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") { needsReconnect = true }
            throw Failure.http(status)
        }
        needsReconnect = false
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Polls the registered sheets every 15 minutes, and on wake.
@MainActor
final class SheetsPolling {
    static let interval: TimeInterval = 15 * 60

    let api: SheetsAPI
    private let auth: GoogleAuth
    private let runner: SheetsRunner
    private var timer: Timer?
    private var wake: NSObjectProtocol?
    var onChange: () -> Void = {}

    init(assistant: Assistant, auth: GoogleAuth) {
        self.auth = auth
        api = SheetsAPI(auth: auth)
        runner = SheetsRunner(assistant: assistant, sheets: api)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    func stop() {
        timer?.invalidate()
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
    }

    func check() {
        guard auth.isConnected else { return }
        _Concurrency.Task {
            await runner.run()
            onChange()
        }
    }
}
