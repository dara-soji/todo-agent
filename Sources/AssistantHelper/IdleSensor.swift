import AssistantCore
import CoreGraphics
import Foundation

/// Reports seconds since the last keyboard or mouse input (no permission needed). The steady
/// report is also how the core notices time passing.
@MainActor
final class IdleSensor: SignalSource {
    private var timer: Timer?
    private var deliver: ((Signal) -> Void)?

    func start(delivering deliver: @escaping (Signal) -> Void) {
        guard timer == nil else { return }
        self.deliver = deliver
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
    }

    private func report() {
        // ~0 is kCGAnyInputEventType.
        let anyInput = CGEventType(rawValue: ~0)!
        deliver?(.userIdle(seconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)))
    }
}
