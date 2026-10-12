import Foundation
import AssistantCore

/// A WallClock the test moves by hand. Never sleep in tests; advance this instead.
final class FakeClock: WallClock {
    private(set) var now: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_791_000_000)) {
        now = start
    }

    func advance(minutes: Double) {
        now += minutes * 60
    }
}
