import AppKit

/// The confirmation after quick-add, above the Dock at bottom right: what was added, with
/// Start now and Undo. Disappears on its own after a few seconds.
@MainActor
final class AddedPanel: NSObject {
    private let panel = NSPanel.themed(size: NSSize(width: 360, height: 64))
    private let message = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "Start now", target: nil, action: nil)
    private var hideTimer: Timer?
    private var onStart: () -> Void = {}
    private var onUndo: () -> Void = {}

    override init() {
        super.init()
        message.font = Theme.display(13)
        message.textColor = Theme.paper
        message.lineBreakMode = .byTruncatingTail

        startButton.target = self
        startButton.action = #selector(start)
        let undoButton = NSButton(title: "Undo", target: self, action: #selector(undo))
        for button in [startButton, undoButton] {
            button.bezelStyle = .inline
            button.attributedTitle = Theme.label(button.title, color: Theme.accent)
        }
        let buttons = NSStackView(views: [startButton, undoButton])
        let stack = NSStackView(views: [message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.frame = panel.contentView!.bounds
        stack.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(stack)
    }

    /// `started` hides Start now when the Task was already started with ⌘↩.
    func show(_ text: String, started: Bool, onStart: @escaping () -> Void, onUndo: @escaping () -> Void) {
        self.onStart = onStart
        self.onUndo = onUndo
        message.stringValue = text
        startButton.isHidden = started
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.minY + 16))
        }
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        }
    }

    @objc private func start() {
        panel.orderOut(nil)
        onStart()
    }

    @objc private func undo() {
        panel.orderOut(nil)
        onUndo()
    }
}
