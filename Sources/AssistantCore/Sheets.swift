import Foundation

/// A Google Sheet Dara chose as a Source.
public struct RegisteredSheet: Equatable, Sendable, Codable {
    public let id: String
    public let name: String
}

/// One row of a sheet as read, numbered from 1 like the sheet itself.
public struct SheetRow: Equatable, Sendable {
    public let number: Int
    public let cells: [String]

    public init(number: Int, cells: [String]) {
        self.number = number
        self.cells = cells
    }
}

/// Port: a registered sheet's rows, read-only (`spreadsheets.readonly`). Asked only for registered sheets.
@MainActor
public protocol SheetsSource: AnyObject {
    func rows(of sheetID: String) async throws -> [SheetRow]
}

/// Polls each registered sheet and turns its rows into Suggestions. Nothing from a sheet goes to
/// the Claude API. What was read is kept on each row's Suggestion, so polling picks up where it
/// left off after sleep or a restart.
@MainActor
public final class SheetsRunner {
    private let assistant: Assistant
    private let sheets: SheetsSource
    private var running = false

    public init(assistant: Assistant, sheets: SheetsSource) {
        self.assistant = assistant
        self.sheets = sheets
    }

    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        for sheet in assistant.registeredSheets {
            do {
                let rows = try await sheets.rows(of: sheet.id)
                // It may have been unregistered while it was read.
                guard assistant.registeredSheets.contains(sheet) else { continue }
                assistant.intake(rows, from: sheet)
            } catch {
                NSLog("TodoAgent: reading a sheet failed: \(type(of: error))")
            }
        }
    }
}

extension Assistant {
    public var registeredSheets: [RegisteredSheet] { settings.sheets }

    /// Registers a Google Sheet, by id or URL, as a Source.
    @discardableResult
    public func registerSheet(_ idOrURL: String, name: String, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard let id = MatcherFitting.sheetID(in: idOrURL) else { throw Failure.malformedSheet(idOrURL) }
        guard !registeredSheets.contains(where: { $0.id == id }) else { throw Failure.alreadyRegisteredSheet(id) }
        let name = name.trimmingCharacters(in: .whitespaces).isEmpty ? id : name.trimmingCharacters(in: .whitespaces)
        return try perform(.registerSheet, "Registered the sheet “\(name)”", by: startedBy,
                           writing: changingSettings { $0.sheets.append(RegisteredSheet(id: id, name: name)) })
    }

    @discardableResult
    public func unregisterSheet(_ id: String, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard let sheet = registeredSheets.first(where: { $0.id == id }) else { throw Failure.unknownSheet(id) }
        return try perform(.unregisterSheet, "Stopped reading the sheet “\(sheet.name)”", by: startedBy,
                           writing: changingSettings { $0.sheets.removeAll { $0.id == id } })
    }

    /// Rows below the header become Suggestions, one per row. An edited row updates its open
    /// Suggestion, or its accepted Task (never over a title Dara set); a row whose Task is done or
    /// dropped comes back as a new Suggestion when edited; a dismissed row stays quiet.
    func intake(_ rows: [SheetRow], from sheet: RegisteredSheet) {
        for row in rows where row.number > 1 {
            guard let text = row.cells.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty })
            else { continue }
            let key = "sheet:\(sheet.id):\(row.number)"
            let fingerprint = row.cells.joined(separator: "\u{1F}")
            let title = text.count <= Self.suggestionTitleLimit ? text : text.prefix(Self.suggestionTitleLimit - 1) + "…"
            guard let existing = suggestionsByThread[key] else {
                try? writeUnlogged(Change(suggestions: [newRowSuggestion(key, title, fingerprint, sheet, row)]))
                continue
            }
            guard existing.fingerprint != fingerprint, !asks.contains(where: { $0.touches.contains(existing.id.rawValue) })
            else { continue }
            var updated = existing
            updated.fingerprint = fingerprint
            switch existing.status {
            case .open:
                updated.title = title
                try? writeUnlogged(Change(suggestions: [updated]))
            case .accepted:
                if let task = liveTask(of: existing) {
                    try? writeUnlogged(Change(suggestions: [updated]))
                    _ = try? updateFromSource(task.id, title: title, deadline: nil)
                } else {
                    try? writeUnlogged(Change(suggestions: [newRowSuggestion(key, title, fingerprint, sheet, row)]))
                }
            case .dismissed, .expired, .replied:
                try? writeUnlogged(Change(suggestions: [updated]))
            }
        }
    }

    private func newRowSuggestion(
        _ key: String, _ title: String, _ fingerprint: String, _ sheet: RegisteredSheet, _ row: SheetRow
    ) -> Suggestion {
        Suggestion(
            id: Suggestion.ID(), threadID: key, title: title, reason: "New row in \(sheet.name)", source: .sheet,
            backLink: "https://docs.google.com/spreadsheets/d/\(sheet.id)/edit#range=A\(row.number)",
            guessedDeadline: nil, created: clock.now, status: .open, fingerprint: fingerprint)
    }
}
