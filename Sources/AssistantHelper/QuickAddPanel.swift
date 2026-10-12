import AppKit

/// The ⌥Space palette: type a Task, ↩ to add it to Now's Project, ⌘↩ to add and start it, esc to close.
@MainActor
final class QuickAddPanel: NSObject, NSTextFieldDelegate {
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let panel = KeyablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 92), styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: true)
    private let heading = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let hint = NSTextField(labelWithString: "↩ ADD   ⌘↩ ADD AND START   ESC CLOSE")
    /// Called with the title and whether to start it.
    var onSubmit: (String, Bool) -> Void = { _, _ in }

    override init() {
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = ChamferedView(fill: Theme.ink, stroke: Theme.olive)

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
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let start = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            panel.orderOut(nil)
            if !title.isEmpty { onSubmit(title, start) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            panel.orderOut(nil)
            return true
        default:
            return false
        }
    }
}

/// A panel background with cut corners, per the reference theme.
final class ChamferedView: NSView {
    private let fill: NSColor
    private let stroke: NSColor
    private let cut: CGFloat = 10

    init(fill: NSColor, stroke: NSColor) {
        self.fill = fill
        self.stroke = stroke
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX + cut, y: r.maxY))
        path.line(to: NSPoint(x: r.maxX, y: r.maxY))
        path.line(to: NSPoint(x: r.maxX, y: r.minY + cut))
        path.line(to: NSPoint(x: r.maxX - cut, y: r.minY))
        path.line(to: NSPoint(x: r.minX, y: r.minY))
        path.line(to: NSPoint(x: r.minX, y: r.maxY - cut))
        path.close()
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
