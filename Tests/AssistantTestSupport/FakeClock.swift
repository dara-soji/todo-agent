import Foundation
import AssistantCore

/// A WallClock the test moves by hand. Never sleep in tests; advance this instead.
public final class FakeClock: WallClock {
    public private(set) var now: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_791_000_000)) {
        now = start
    }

    public func advance(minutes: Double) {
        now += minutes * 60
    }
}
