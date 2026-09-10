import Foundation
import UserNotifications

@MainActor
final class QuotaNotificationController {
    private let defaults: UserDefaults
    private let deliveredKey = "mac-delivered-quota-alerts-v1"
    private var asked = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func publish(_ dashboard: Dashboard) {
        let snapshot = UsageSnapshot(dashboard: dashboard)
        let delivered = Set(defaults.stringArray(forKey: deliveredKey) ?? [])
        let muted = Set(defaults.stringArray(forKey: NotchSettingsStore.muteKey) ?? [])
        var pending: [UsageAlerts.Alert] = []
        pending.append(contentsOf: UsageAlerts.pending(
            snapshot: snapshot, threshold: 80, delivered: delivered, now: .now
        ))
        pending.append(contentsOf: UsageAlerts.pending(
            snapshot: snapshot, threshold: 100, delivered: delivered, now: .now
        ))
        pending = pending.filter { alert in
            !muted.contains { alert.id.hasPrefix($0 + "/") }
        }
        guard !pending.isEmpty else { return }
        Task { await deliver(pending, delivered: delivered) }
    }

    private func deliver(_ alerts: [UsageAlerts.Alert], delivered: Set<String>) async {
        var delivered = delivered
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard !asked else { return }
            asked = true
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
        } else if settings.authorizationStatus != .authorized,
                  settings.authorizationStatus != .provisional {
            return
        }
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            try? await center.add(
                UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
            )
            delivered.insert(alert.id)
        }
        defaults.set(Array(delivered).sorted(), forKey: deliveredKey)
    }
}
