import AppKit
import AssistantCore
import QuartzCore

/// The ⌥Space palette: type a Task, ↩ to add it to Now's Project, ⌘↩ to add and start it, esc to close.
/// While ⌥Space is held it shows "Listening…" and the live transcript instead.
/// Long text wraps: the box grows downward a line at a time, top edge fixed, up to
/// `BoxGrowth.maxLines`; past that it scrolls, newest line in view, with the top edge faded.
@MainActor
final class QuickAddPanel: NSObject, NSTextViewDelegate {
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        /// ⌘↩ is a key equivalent, so it never reaches the text view as a newline.
        var onCommandReturn: () -> Void = {}

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                onCommandReturn()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Each new line eases the box down over this long.
    private static let growth: TimeInterval = 0.2
    /// How much of the box's top fades when earlier lines have scrolled out.
    private static let fade: CGFloat = 0.22
    private static let insets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
    private static let width: CGFloat = 520
    /// The text's width: fixed, so wrapping is measured right even before the panel first lays out.
    private static let textWidth = width - insets.left - insets.right

    private let panel = NSPanel.themed(KeyablePanel.self, size: NSSize(width: QuickAddPanel.width, height: 92))
    /// The app Dara was in, given focus back when the palette closes.
    private var previousApp: NSRunningApplication?
    private let heading = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let text = NSTextView()
    /// NSTextView has no placeholder of its own: "What needs doing?" or "Listening…", shown while empty.
    private let placeholder = NSTextField(labelWithString: "")
    private var boxHeight: NSLayoutConstraint!
    private let stack: NSStackView
    private static let typingHint = "↩ ADD   ⌘↩ ADD AND START   ESC CLOSE"
    private let hint = NSTextField(labelWithString: typingHint)
    /// "Voice needs … → Open Settings" (or that macOS is asking), shown in the typing box when a hold couldn't record.
    private let notice = NSButton(title: "", target: nil, action: nil)
    private var noticeURL: URL?
    /// The fade over the top edge, set as the scroll view's mask while text overflows.
    private let fadeMask = CAGradientLayer()
    /// True from Listening… until the recording's Tasks are added (or the typing box opens).
    private(set) var isListening = false
    /// Called with the title and whether to start it.
    var onSubmit: (String, Bool) -> Void = { _, _ in }

    private var font: NSFont { Theme.display(18) }
    private var lineHeight: CGFloat { text.layoutManager?.defaultLineHeight(for: font) ?? 22 }

    override init() {
        stack = NSStackView(views: [heading, scroll, hint, notice])
        super.init()
        panel.onCommandReturn = { [weak self] in self?.submit(start: true) }

        heading.font = Theme.mono(10, weight: .bold)
        heading.textColor = Theme.accent

        text.font = font
        text.textColor = Theme.paper
        text.insertionPointColor = Theme.accent
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = .width
        text.delegate = self

        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        // The scroll view's layer is flipped (y runs top-down), so y 0 is the top edge: clear there.
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.locations = [0, NSNumber(value: Double(Self.fade)), 1]

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(placeholder)
        restorePlaceholder()

        hint.font = Theme.mono(9)
        hint.textColor = Theme.steel

        notice.isBordered = false
        notice.alignment = .left
        notice.target = self
        notice.action = #selector(openNoticeSettings)
        notice.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = Self.insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        boxHeight = scroll.heightAnchor.constraint(equalToConstant: lineHeight)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                scroll.widthAnchor.constraint(equalToConstant: Self.textWidth),
                boxHeight,
                placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
                placeholder.topAnchor.constraint(equalTo: scroll.topAnchor),
            ])
        }
    }

    /// `destination` names where ↩ will put the Task, e.g. "TODO-AGENT" or "NO PROJECT".
    /// `voiceNotice`: why the hold that opened it couldn't record, as one line (clickable when it names a pane).
    func show(destination: String, voiceNotice: VoiceNotice? = nil) {
        isListening = false
        showNotice(voiceNotice)
        heading.attributedStringValue = Theme.label("Add task → \(destination)", color: Theme.accent)
        text.isEditable = true
        text.isSelectable = true
        setText("")
        restorePlaceholder()
        hint.stringValue = Self.typingHint
        position()
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(text)
    }

    /// Push-to-talk: shown without taking focus, so the app Dara is in keeps it.
    func showListening(destination: String) {
        heading.attributedStringValue = Theme.label("Add task → \(destination)", color: Theme.accent)
        text.isEditable = false
        text.isSelectable = false
        setText("")
        showPlaceholder("Listening…")
        hint.stringValue = "RELEASE ⌥SPACE TO ADD"
        isListening = true
        showNotice(nil)
        position()
        previousApp = nil
        panel.orderFrontRegardless()
    }

    /// The live transcript while listening. The box grows with it, newest words in view.
    func showTranscript(_ transcript: String) {
        guard text.string != transcript else { return }
        text.string = transcript
        textChanged(animated: panel.isVisible)
    }

    /// Released: the transcript stays in view while it is split into Tasks.
    func showAdding() {
        guard isListening else { return }
        hint.stringValue = "ADDING…"
    }

    /// Closes the Listening state once the recording's Tasks are added. Leaves a typing box alone.
    func hideListening() {
        guard isListening else { return }
        isListening = false
        panel.orderOut(nil)
        restorePlaceholder()
    }

    // MARK: Growing

    /// Replaces the text and snaps the box to fit, as when the palette opens: one line when empty.
    private func setText(_ string: String) {
        text.string = string
        textChanged(animated: false)
    }

    func textDidChange(_ notification: Notification) {
        textChanged(animated: true)
    }

    private func textChanged(animated: Bool) {
        placeholder.isHidden = !text.string.isEmpty
        resize(animated: animated)
        // While typing, keep the caret in view; while listening, the newest words.
        if text.isEditable {
            text.scrollRangeToVisible(text.selectedRange())
        } else {
            text.scrollToEndOfDocument(nil)
        }
    }

    /// Fits the box to its wrapped text, growing or shrinking from the bottom; the top edge stays put.
    private func resize(animated: Bool) {
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        container.containerSize = NSSize(width: Self.textWidth, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = self.lineHeight
        let growth = BoxGrowth(textHeight: layout.usedRect(for: container).height, lineHeight: lineHeight)
        let box = CGFloat(growth.height(lineHeight: lineHeight))
        let chrome = Self.insets.top + Self.insets.bottom + stack.views.filter { !$0.isHidden && $0 !== scroll }
            .reduce(0) { $0 + $1.fittingSize.height + stack.spacing }
        let size = NSSize(width: Self.width, height: (chrome + box).rounded(.up))
        setFade(growth.overflows, height: box)
        guard box != boxHeight.constant || size.height != panel.frame.height else { return }

        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        guard animated else {
            boxHeight.constant = box
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.growth
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            boxHeight.animator().constant = box
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func setFade(_ on: Bool, height: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = CGRect(x: 0, y: 0, width: Self.textWidth, height: height)
        CATransaction.commit()
        scroll.layer?.mask = on ? fadeMask : nil
    }

    // MARK: Notice, placeholder, position

    private func showNotice(_ voiceNotice: VoiceNotice?) {
        notice.isHidden = voiceNotice == nil
        noticeURL = voiceNotice?.settingsURL
        notice.attributedTitle = NSAttributedString(
            string: voiceNotice?.message ?? "",
            attributes: [.foregroundColor: noticeURL == nil ? Theme.steel : Theme.accent, .font: Theme.mono(9)])
        notice.isEnabled = noticeURL != nil
        resize(animated: false)
    }

    @objc private func openNoticeSettings() {
        guard let noticeURL else { return }
        close()
        NSWorkspace.shared.open(noticeURL)
    }

    private func restorePlaceholder() {
        showPlaceholder("What needs doing?")
    }

    private func showPlaceholder(_ string: String) {
        placeholder.attributedStringValue = NSAttributedString(
            string: string, attributes: [.foregroundColor: Theme.steel, .font: font])
        placeholder.isHidden = !text.string.isEmpty
    }

    /// The top edge sits a fixed distance down the screen, so growing only ever extends downward.
    private func position() {
        if let screen = NSScreen.main?.visibleFrame {
            let top = screen.maxY - screen.height / 3 + 92
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: top - panel.frame.height))
        }
    }

    // MARK: Keys

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit(start: false)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertParagraphSeparator(_:)), #selector(NSResponder.insertTab(_:)):
            // A Task title is one line that wraps for display: no line breaks.
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    /// Pasted line breaks become spaces, so the title stays one line.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard let replacementString, replacementString.rangeOfCharacter(from: .newlines) != nil else { return true }
        let flat = replacementString.components(separatedBy: .newlines).joined(separator: " ")
        textView.insertText(flat, replacementRange: range)
        return false
    }

    private func submit(start: Bool) {
        let title = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        if !title.isEmpty { onSubmit(title, start) }
    }

    private func close() {
        panel.orderOut(nil)
        previousApp?.activate()
        previousApp = nil
    }
}
