import Foundation

/// The assistant's domain. Feed it Signals; read Now.
public final class Assistant {
    private let clock: WallClock
    public private(set) var now: Now = .unknown

    public init(clock: WallClock) {
        self.clock = clock
    }

    public func receive(_ signal: Signal) {
        switch signal {
        case let .activeWindow(app, title):
            if case let .window(currentApp, currentTitle, _) = now, currentApp == app, currentTitle == title {
                return
            }
            now = .window(app: app, title: title, since: clock.now)
        }
    }
}
