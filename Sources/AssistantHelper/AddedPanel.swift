import AppKit

/// The confirmation after quick-add, above the Dock at bottom right: what was added (every Task, when
/// one recording made several), with Start now and one Undo. Disappears on its own after a few seconds.
@MainActor
final class AddedPanel: NSObject {
    private let panel = NSPanel.themed(size: NSSize(width: 360, height: 64))
    private let message = NSTextField(labelWithString: "")
    /// The Tasks one by one, when there are several.
    private let items = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "Start now", target: nil, action: nil)
    private var hideTimer: Timer?
    private var onStart: () -> Void = {}
    private var onUndo: () -> Void = {}

    override init() {
        super.init()
        message.font = Theme.display(13)
        message.textColor = Theme.paper
        message.lineBreakMode = .byTruncatingTail
        items.font = Theme.display(12)
        items.textColor = Theme.paper
        items.maximumNumberOfLines = 0
        items.lineBreakMode = .byTruncatingTail

        startButton.target = self
        startButton.action = #selector(start)
        let undoButton = NSButton(title: "Undo", target: self, action: #selector(undo))
        for button in [startButton, undoButton] {
            button.bezelStyle = .inline
            button.attributedTitle = Theme.label(button.title, color: Theme.accent)
        }
        let buttons = NSStackView(views: [startButton, undoButton])
        let stack = NSStackView(views: [message, items, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.frame = panel.contentView!.bounds
        stack.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(stack)
    }

    /// `items` lists the Tasks when one Operation added several; Start now then starts the first.
    /// `started` hides Start now when the Task was already started with ⌘↩.
    func show(_ text: String, items titles: [String] = [], started: Bool, onStart: @escaping () -> Void, onUndo: @escaping () -> Void) {
        self.onStart = onStart
        self.onUndo = onUndo
        message.stringValue = text
        items.stringValue = titles.map { "· \($0)" }.joined(separator: "\n")
        items.isHidden = titles.isEmpty
        startButton.isHidden = started
        startButton.attributedTitle = Theme.label(titles.isEmpty ? "Start now" : "Start first", color: Theme.accent)
        panel.setContentSize(NSSize(width: 360, height: 64 + CGFloat(titles.count) * 17))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.minY + 16))
        }
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        // A longer list takes longer to read.
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6 + Double(titles.count), repeats: false) { [weak self] _ in
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
