import AppKit

/// Dara's reference theme: dark/olive/steel palette, #FFA500 accent,
/// Tektur for display and titles, JetBrains Mono for uppercase labels and metadata.
enum Theme {
    static let ink = NSColor(hex: 0x0D0F10)
    static let olive = NSColor(hex: 0x303B35)
    static let steel = NSColor(hex: 0x6B706D)
    static let paper = NSColor(hex: 0xE8ECE9)
    static let accent = NSColor(hex: 0xFFA500)

    /// Uppercase, wide-tracked labels and metadata. Falls back to the system monospaced font
    /// when JetBrains Mono isn't installed.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name = weight == .regular ? "JetBrainsMono-Regular" : "JetBrainsMono-Bold"
        return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Display and titles. Falls back to the system font when Tektur isn't installed.
    static func display(_ size: CGFloat) -> NSFont {
        NSFont(name: "Tektur-Medium", size: size) ?? .systemFont(ofSize: size, weight: .medium)
    }

    static func label(_ text: String, size: CGFloat = 10, color: NSColor = steel) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: mono(size, weight: .bold), .foregroundColor: color, .kern: 1.6,
        ])
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension NSPanel {
    /// A borderless floating panel with a chamfered background, as the reference theme draws them.
    static func themed<Panel: NSPanel>(_ type: Panel.Type = NSPanel.self, size: NSSize) -> Panel {
        let panel = Panel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = ChamferedView(fill: Theme.ink, stroke: Theme.olive)
        return panel
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

/// Runs a change Dara asked for from the menu or a panel; a refusal is shown, never swallowed.
@MainActor
enum Attempt {
    static func run(_ title: String, explaining explain: (Error) -> String = { "\($0)" }, then changed: () -> Void, _ change: () throws -> Void) {
        do {
            try change()
        } catch {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = explain(error)
            NSApp.activate()
            alert.runModal()
        }
        changed()
    }
}
