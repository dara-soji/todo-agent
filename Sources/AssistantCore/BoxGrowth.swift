import Foundation

/// How tall the ⌥Space box is for its text: one line when empty, a line more for each wrapped
/// line, up to `maxLines`. Past that the text scrolls inside it, newest line in view.
public struct BoxGrowth: Equatable, Sendable {
    public static let maxLines = 6

    /// Lines shown, 1…`maxLines`.
    public let lines: Int
    /// More text than fits: it scrolls, and the top edge fades.
    public let overflows: Bool

    public init(lines: Int, overflows: Bool) {
        self.lines = lines
        self.overflows = overflows
    }

    /// `textHeight`: the laid-out text's height, which is rarely an exact multiple of `lineHeight`.
    public init(textHeight: Double, lineHeight: Double) {
        let wrapped = max(1, Int((textHeight / lineHeight).rounded()))
        self.init(lines: min(wrapped, Self.maxLines), overflows: wrapped > Self.maxLines)
    }

    public func height(lineHeight: Double) -> Double {
        Double(lines) * lineHeight
    }
}
