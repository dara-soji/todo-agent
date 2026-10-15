import AppKit
import AssistantCore

/// The Nudge: a calm panel above the Dock at bottom right, only on Drift, once per episode.
/// "<where you are> ≠ <committed Project>", the window, the Committed Task, and four ways out.
@MainActor
final class NudgePanel: NSObject {
    private let assistant: Assistant
    private let panel = NSPanel.themed(size: NSSize(width: 380, height: 112))
    private let heading = NSTextField(labelWithString: "")
    private let window = NSTextField(labelWithString: "")
    private let task = NSTextField(labelWithString: "")
    private var shown: Nudge?
    var onChange: () -> Void = {}
    /// Switch task: opens quick-add so Dara can name what they're on now.
    var onSwitchTask: () -> Void = {}

    init(assistant: Assistant) {
        self.assistant = assistant
        super.init()
        heading.font = Theme.mono(11, weight: .bold)
        heading.textColor = Theme.accent
        for field in [window, task] {
            field.font = Theme.display(12)
            field.textColor = Theme.paper
            field.lineBreakMode = .byTruncatingTail
        }
        window.textColor = Theme.steel
        let buttons = NSStackView(views: [
            button("Back to it", #selector(backToIt)), button("Switch task", #selector(switchTask)),
            button("It's related", #selector(related)), button("Quiet 30m", #selector(quiet)),
        ])
        let stack = NSStackView(views: [heading, window, task, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.frame = panel.contentView!.bounds
        stack.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(stack)
    }

    /// Shows or hides the panel to match the core's Nudge.
    func update() {
        guard let nudge = assistant.nudge else {
            shown = nil
            panel.orderOut(nil)
            return
        }
        guard nudge != shown else { return }
        shown = nudge
        let committed = assistant.project(nudge.committedProject)?.shortName.uppercased() ?? "?"
        let here = nudge.nowProject.flatMap(assistant.project)?.shortName.uppercased() ?? "NO PROJECT"
        heading.attributedStringValue = Theme.label("\(here) ≠ \(committed)", color: Theme.accent)
        window.stringValue = assistant.menuBar.window ?? ""
        task.stringValue = assistant.task(nudge.task).map { "Committed: \($0.title)" } ?? ""
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.minY + 16))
        }
        panel.orderFrontRegardless()
    }

    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .inline
        button.attributedTitle = Theme.label(title, color: Theme.accent)
        return button
    }

    @objc private func backToIt() {
        assistant.dismissNudge()
        onChange()
    }

    @objc private func switchTask() {
        assistant.dismissNudge()
        onChange()
        onSwitchTask()
    }

    @objc private func related() {
        Attempt.run("Couldn't correct Now", then: onChange) { try assistant.nudgeIsRelated() }
    }

    @objc private func quiet() {
        assistant.quietNudges()
        onChange()
    }
}
