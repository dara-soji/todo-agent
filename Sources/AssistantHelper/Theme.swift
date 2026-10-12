import AppKit

/// Dara's reference theme: dark/olive/steel palette, #FFA500 accent,
/// Tektur for display and titles, JetBrains Mono for uppercase labels and metadata.
enum Theme {
    static let ink = NSColor(hex: 0x0D0F10)
    static let olive = NSColor(hex: 0x303B35)
    static let steel = NSColor(hex: 0x6B706D)
    static let mist = NSColor(hex: 0xA8ADAA)
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
