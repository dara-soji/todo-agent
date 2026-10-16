import AssistantCore
import Foundation
@preconcurrency import UserNotifications

/// The Notifier port over UserNotifications. Asks for permission the first time, and checks the
/// current setting every time, so turning notifications on in System Settings takes effect at once.
/// Needs the bundled app: without a bundle id there is no notification centre, so it only logs.
@MainActor
final class UserNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    private var asking: _Concurrency.Task<Void, Never>?

    func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return NSLog("TodoAgent: no bundle, notification skipped") }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        _Concurrency.Task {
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                // One permission prompt, however many notifications arrive together.
                if asking == nil {
                    asking = _Concurrency.Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
                }
                await asking?.value
            }
            guard await center.notificationSettings().authorizationStatus == .authorized else { return }
            try? await center.add(request)
        }
    }

    /// Shown as a banner even while a TodoAgent alert has the app active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
