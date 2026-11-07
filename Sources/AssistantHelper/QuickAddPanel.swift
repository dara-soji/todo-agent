import AppKit
import AssistantCore

/// The ⌥Space palette: type a Task, ↩ to add it to Now's Project, ⌘↩ to add and start it, esc to close.
/// While ⌥Space is held it shows "Listening…" and the live transcript instead.
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
    private static let typingHint = "↩ ADD   ⌘↩ ADD AND START   ESC CLOSE"
    private let hint = NSTextField(labelWithString: typingHint)
    /// "Voice needs … → Open Settings", shown in the typing box when a hold couldn't record.
    private let notice = NSButton(title: "", target: nil, action: nil)
    private var noticeURL: URL?
    /// True from Listening… until the recording's Tasks are added (or the typing box opens).
    private(set) var isListening = false
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
        restorePlaceholder()
        field.delegate = self
        hint.font = Theme.mono(9)
        hint.textColor = Theme.steel

        notice.isBordered = false
        notice.alignment = .left
        notice.target = self
        notice.action = #selector(openNoticeSettings)
        notice.isHidden = true

        let stack = NSStackView(views: [heading, field, hint, notice])
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
    /// `voiceNotice`: why the hold that opened it couldn't record, as one clickable line.
    func show(destination: String, voiceNotice: VoiceUnavailable? = nil) {
        isListening = false
        showNotice(voiceNotice)
        heading.attributedStringValue = Theme.label("Add task → \(destination)", color: Theme.accent)
        field.stringValue = ""
        field.isEditable = true
        field.lineBreakMode = .byClipping
        restorePlaceholder()
        hint.stringValue = Self.typingHint
        position()
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Push-to-talk: shown without taking focus, so the app Dara is in keeps it.
    func showListening(destination: String) {
        heading.attributedStringValue = Theme.label("Add task → \(destination)", color: Theme.accent)
        field.stringValue = ""
        field.placeholderAttributedString = NSAttributedString(
            string: "Listening…", attributes: [.foregroundColor: Theme.steel, .font: Theme.display(18)])
        field.isEditable = false
        // Keep the latest words in view as the transcript grows.
        field.lineBreakMode = .byTruncatingHead
        hint.stringValue = "RELEASE ⌥SPACE TO ADD"
        isListening = true
        showNotice(nil)
        position()
        previousApp = nil
        panel.orderFrontRegardless()
    }

    /// The live transcript while listening.
    func showTranscript(_ text: String) {
        field.stringValue = text
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

    private func showNotice(_ cause: VoiceUnavailable?) {
        notice.isHidden = cause == nil
        noticeURL = cause?.settingsURL
        notice.attributedTitle = NSAttributedString(
            string: cause?.message ?? "",
            attributes: [.foregroundColor: noticeURL == nil ? Theme.steel : Theme.accent, .font: Theme.mono(9)])
        notice.isEnabled = noticeURL != nil
        panel.setContentSize(NSSize(width: panel.frame.width, height: cause == nil ? 92 : 112))
    }

    @objc private func openNoticeSettings() {
        guard let noticeURL else { return }
        close()
        NSWorkspace.shared.open(noticeURL)
    }

    private func restorePlaceholder() {
        field.placeholderAttributedString = NSAttributedString(
            string: "What needs doing?", attributes: [.foregroundColor: Theme.steel, .font: Theme.display(18)])
    }

    private func position() {
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.maxY - screen.height / 3))
        }
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
