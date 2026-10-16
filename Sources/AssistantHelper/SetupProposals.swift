import AppKit
import AssistantCore

/// Proposes Projects from the repos under Dara's code folder and the registered Sheets, as one
/// checklist: Dara unticks what they don't want, once. Scans the folder with FileManager only.
@MainActor
enum SetupProposals {
    /// Where code folders usually are; the first that exists is scanned.
    static let codeFolders = ["code", "Developer", "Projects", "src", "repos"]

    /// Git repos directly under the code folder, or one level down (code/org/repo).
    static func repoPaths() -> [String] {
        let files = FileManager.default
        let home = NSHomeDirectory() as NSString
        guard let root = codeFolders.map(home.appendingPathComponent).first(where: { files.fileExists(atPath: $0) })
        else { return [] }
        func children(_ path: String) -> [String] {
            ((try? files.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }
                .map { (path as NSString).appendingPathComponent($0) }
                .filter { var isDir: ObjCBool = false; return files.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
                .sorted()
        }
        func isRepo(_ path: String) -> Bool { files.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) }
        return children(root).flatMap { path in isRepo(path) ? [path] : children(path).filter(isRepo) }
    }

    /// The checklist. Returns whether anything was added.
    @discardableResult
    static func offer(_ assistant: Assistant) -> Bool {
        let proposals = assistant.setupProposals(repoPaths: repoPaths())
        let alert = NSAlert()
        alert.messageText = proposals.isEmpty ? "No new Projects to propose" : "Projects from your repos and Sheets"
        alert.informativeText = proposals.isEmpty
            ? "Every repo under your code folder, and every registered Sheet, already has a Project."
            : "Untick any you don't want. Each becomes a Project that matches its repo or Sheet."
        guard !proposals.isEmpty else {
            alert.runModal()
            return false
        }
        alert.addButton(withTitle: "Add Projects")
        alert.addButton(withTitle: "Not now")
        let boxes = proposals.map { proposal in
            NSButton(checkboxWithTitle: "\(proposal.name)  ·  \(MatcherText.format(proposal.matcher))", target: nil, action: nil)
        }
        boxes.forEach { $0.state = .on }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: CGFloat(boxes.count) * 22)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: min(300, CGFloat(boxes.count) * 22 + 4)))
        scroll.documentView = stack
        scroll.hasVerticalScroller = boxes.count > 13
        alert.accessoryView = scroll
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let chosen = zip(proposals, boxes).filter { $0.1.state == .on }.map(\.0)
        Attempt.run("Couldn't add the Projects", then: {}) { try assistant.addProposedProjects(chosen) }
        return !chosen.isEmpty
    }
}
