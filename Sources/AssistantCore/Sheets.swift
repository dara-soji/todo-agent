import Foundation

/// A Google Sheet Dara chose as a Source.
public struct RegisteredSheet: Equatable, Sendable, Codable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
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
    /// Asked to run while running (a sheet just registered): run once more straight after.
    private var again = false

    public init(assistant: Assistant, sheets: SheetsSource) {
        self.assistant = assistant
        self.sheets = sheets
    }

    public func run() async {
        guard !running else { return again = true }
        running = true
        defer { running = false }
        repeat {
            again = false
            await readAll()
        } while again
    }

    private func readAll() async {
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

    /// Stops reading a sheet; its open Suggestions go with it.
    @discardableResult
    public func unregisterSheet(_ id: String, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard let sheet = registeredSheets.first(where: { $0.id == id }) else { throw Failure.unknownSheet(id) }
        var change = changingSettings { $0.sheets.removeAll { $0.id == id } }
        change.suggestions = suggestions(of: sheet).filter { $0.status == .open }.map { var gone = $0; gone.status = .expired; return gone }
        return try perform(.unregisterSheet, "Stopped reading the sheet “\(sheet.name)”", by: startedBy, writing: change)
    }

    /// Reads a sheet's rows below the header. The first read only notes what is there; after that a
    /// new row, or an edited one, becomes a Suggestion. A row that moved (an insert, delete or sort
    /// above it) is recognised by its cells, so moving is never an edit. An edited row updates its
    /// open Suggestion, or its accepted Task (never over a title Dara set); a row whose Task is done
    /// or dropped, or whose Suggestion expired, comes back as a new Suggestion; a dismissed row stays
    /// quiet. A row whose Suggestion or Task is waiting in an Ask is left until it is answered.
    func intake(_ rows: [SheetRow], from sheet: RegisteredSheet) {
        let current = rows.compactMap { row -> (row: SheetRow, title: String, fingerprint: String)? in
            guard row.number > 1, let text = row.cells.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) else { return nil }
            let title = text.count <= Self.suggestionTitleLimit ? text : text.prefix(Self.suggestionTitleLimit - 1) + "…"
            return (row, String(title), row.cells.joined(separator: "\u{1F}"))
        }
        let marker = "sheet:\(sheet.id):read"
        guard suggestionsByThread[marker] != nil else {
            // The first read: note the rows as they are, offer none.
            let seen = current.map { newRow($0.row, $0.title, $0.fingerprint, sheet, status: .seen) }
                + [newRow(SheetRow(number: 0, cells: []), "", "", sheet, status: .seen, key: marker)]
            return save(seen)
        }

        var known = suggestions(of: sheet).filter { $0.row != nil }
        var changed: [Suggestion] = []
        var unmatched: [(row: SheetRow, title: String, fingerprint: String)] = []
        // Rows whose cells are unchanged, wherever they are now.
        for item in current {
            let candidates = known.filter { $0.fingerprint == item.fingerprint }
            guard let match = candidates.first(where: { $0.row == item.row.number }) ?? candidates.first else {
                unmatched.append(item)
                continue
            }
            known.removeAll { $0.id == match.id }
            guard match.row != item.row.number else { continue }
            var moved = match
            moved.row = item.row.number
            moved.backLink = Self.rowLink(sheet, item.row.number)
            if let task = liveTask(of: match) {
                // Held in an Ask: the move is picked up once it is answered.
                guard !isHeld(task.id, match),
                      (try? sourceUpdate(task.id, title: nil, backLink: moved.backLink)) == true else { continue }
            }
            changed.append(moved)
        }
        // Rows edited in place, and new rows.
        for item in unmatched {
            guard let index = known.firstIndex(where: { $0.row == item.row.number }) else {
                changed.append(newRow(item.row, item.title, item.fingerprint, sheet, status: .open))
                continue
            }
            let existing = known.remove(at: index)
            if existing.status == .accepted, let task = liveTask(of: existing) {
                guard !isHeld(task.id, existing),
                      (try? sourceUpdate(task.id, title: item.title)) == true else { continue }
                var updated = existing
                updated.fingerprint = item.fingerprint
                changed.append(updated)
                continue
            }
            guard !isHeld(nil, existing) else { continue }
            var updated = existing
            updated.fingerprint = item.fingerprint
            switch existing.status {
            case .open:
                updated.title = item.title
                changed.append(updated)
            case .dismissed, .replied:
                changed.append(updated)
            case .accepted, .expired, .seen:
                // Its Task is closed, or it was never answered: a fresh Suggestion for the row.
                updated.row = nil
                changed += [updated, newRow(item.row, item.title, item.fingerprint, sheet, status: .open)]
            }
        }
        // Rows that are gone: their open Suggestions go too.
        for gone in known where !isHeld(liveTask(of: gone)?.id, gone) {
            var detached = gone
            detached.row = nil
            if detached.status == .open { detached.status = .expired }
            changed.append(detached)
        }
        save(changed)
    }

    private func suggestions(of sheet: RegisteredSheet) -> [Suggestion] {
        let prefix = "sheet:\(sheet.id):"
        return suggestionsByThread.values.filter { $0.threadID.hasPrefix(prefix) && $0.threadID != prefix + "read" }
    }

    /// Whether the row's Suggestion, or its Task, is waiting in an Ask.
    private func isHeld(_ task: Task.ID?, _ suggestion: Suggestion) -> Bool {
        asks.contains { ask in
            ask.touches.contains(suggestion.id.rawValue) || task.map { ask.touches.contains($0.rawValue) } == true
        }
    }

    private func save(_ suggestions: [Suggestion]) {
        guard !suggestions.isEmpty else { return }
        do {
            try writeUnlogged(Change(suggestions: suggestions))
        } catch {
            NSLog("TodoAgent: saving sheet rows failed: \(type(of: error))")
        }
    }

    static func rowLink(_ sheet: RegisteredSheet, _ row: Int) -> String {
        "https://docs.google.com/spreadsheets/d/\(sheet.id)/edit#range=A\(row)"
    }

    private func newRow(
        _ row: SheetRow, _ title: String, _ fingerprint: String, _ sheet: RegisteredSheet, status: Suggestion.Status,
        key: String? = nil
    ) -> Suggestion {
        Suggestion(
            id: Suggestion.ID(), threadID: key ?? "sheet:\(sheet.id):\(UUID().uuidString)", title: title,
            reason: "New row in \(sheet.name)", source: .sheet, backLink: Self.rowLink(sheet, row.number),
            guessedDeadline: nil, created: clock.now, status: status, fingerprint: fingerprint,
            row: key == nil ? row.number : nil)
    }
}
