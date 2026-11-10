import Testing
import AssistantCore

@Suite struct BoxGrowthTests {
    let line = 22.0

    @Test func anEmptyBoxIsOneLine() {
        #expect(BoxGrowth(textHeight: 0, lineHeight: line) == BoxGrowth(lines: 1, overflows: false))
    }

    @Test func itGrowsALineAtATime() {
        #expect(BoxGrowth(textHeight: line, lineHeight: line).lines == 1)
        #expect(BoxGrowth(textHeight: line * 3, lineHeight: line).lines == 3)
        // Layout heights are rarely exact multiples.
        #expect(BoxGrowth(textHeight: line * 2 + 0.4, lineHeight: line).lines == 2)
    }

    @Test func itStopsAtSixLinesAndScrolls() {
        #expect(BoxGrowth(textHeight: line * 6, lineHeight: line) == BoxGrowth(lines: 6, overflows: false))
        #expect(BoxGrowth(textHeight: line * 9, lineHeight: line) == BoxGrowth(lines: 6, overflows: true))
        #expect(BoxGrowth.maxLines == 6)
    }

    @Test func itsHeightIsItsLines() {
        #expect(BoxGrowth(textHeight: line * 4, lineHeight: line).height(lineHeight: line) == line * 4)
    }
}
