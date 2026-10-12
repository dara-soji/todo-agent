import AppKit

/// The ⌥Space palette: type a Task, ↩ to add it to Now's Project, ⌘↩ to add and start it, esc to close.
@MainActor
final class QuickAddPanel: NSObject, NSTextFieldDelegate {
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        /// ⌘↩ is a key equivalent, so it never reaches the text field as a newline.
        var onCommandReturn: () -> Void = {}

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                onCommandReturn()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    private let panel = NSPanel.themed(KeyablePanel.self, size: NSSize(width: 520, height: 92))
    /// The app Dara was in, given focus back when the palette closes.
    private var previousApp: NSRunningApplication?
    private let heading = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let hint = NSTextField(labelWithString: "↩ ADD   ⌘↩ ADD AND START   ESC CLOSE")
    /// Called with the title and whether to start it.
    var onSubmit: (String, Bool) -> Void = { _, _ in }

    override init() {
        super.init()
        panel.onCommandReturn = { [weak self] in self?.submit(start: true) }

        heading.font = Theme.mono(10, weight: .bold)
        heading.textColor = Theme.accent
        field.font = Theme.display(18)
        field.textColor = Theme.paper
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderAttributedString = NSAttributedString(
            string: "What needs doing?", attributes: [.foregroundColor: Theme.steel, .font: Theme.display(18)])
        field.delegate = self
        hint.font = Theme.mono(9)
        hint.textColor = Theme.steel

        let stack = NSStackView(views: [heading, field, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            ])
        }
    }

    /// `destination` names where ↩ will put the Task, e.g. "TODO-AGENT" or "NO PROJECT".
    func show(destination: String) {
        heading.attributedStringValue = Theme.label("Add task → \(destination)", color: Theme.accent)
        field.stringValue = ""
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.maxY - screen.height / 3))
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit(start: false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func submit(start: Bool) {
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        if !title.isEmpty { onSubmit(title, start) }
    }

    private func close() {
        panel.orderOut(nil)
        previousApp?.activate()
        previousApp = nil
    }
}
