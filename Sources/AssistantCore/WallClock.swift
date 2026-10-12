import Foundation

/// Port for the current time. The helper passes the system clock; tests pass a fake they advance by hand.
public protocol WallClock: AnyObject {
    var now: Date { get }
}

public final class SystemClock: WallClock {
    public init() {}
    public var now: Date { Date() }
}
