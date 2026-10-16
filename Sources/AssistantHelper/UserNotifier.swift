import AssistantCore
import Foundation
import UserNotifications

/// The Notifier port over UserNotifications. Asks for permission the first time it is needed. Needs
/// the bundled app: without a bundle id there is no notification centre, so it only logs.
@MainActor
final class UserNotifier: Notifier {
    private var authorised: Bool?

    func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return NSLog("TodoAgent: no bundle, notification skipped") }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        _Concurrency.Task {
            if authorised == nil {
                authorised = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorised == true else { return }
            try? await center.add(request)
        }
    }
}
