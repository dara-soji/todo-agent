import AssistantCore
import EventKit

/// Reports today's remaining timed events from every calendar (EventKit, full access).
@MainActor
final class CalendarSensor: SignalSource {
    private let store = EKEventStore()
    private var deliver: ((Signal) -> Void)?
    private var refreshTimer: Timer?

    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func start(delivering deliver: @escaping (Signal) -> Void) {
        guard self.deliver == nil else { return }
        self.deliver = deliver
        store.requestFullAccessToEvents { [weak self] granted, _ in
            guard granted else { return }  // Without access the calendar simply never matches.
            // Qualified: AssistantCore.Task is the domain Task.
            _Concurrency.Task { @MainActor in self?.beginReporting() }
        }
    }

    private func beginReporting() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        // Events are sent ahead of time and the core checks which are under way, so a slow
        // refresh is enough to pick up edits the change notification misses.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }

    private func report() {
        let now = Date()
        guard let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return }
        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { CalendarEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate) }
        deliver?(.calendar(events: events))
    }
}
