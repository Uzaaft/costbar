import BackgroundTasks
import CloudKit
import OSLog
import SwiftUI
import UserNotifications
import WidgetKit

@MainActor
final class MobileStore: ObservableObject {
    static let shared = MobileStore()
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var backgroundMessage: String?
    @Published private(set) var notificationFeedback: String?
    @Published private(set) var requestingNotificationPermission = false
    @Published private(set) var notificationsAllowed = false
    @Published private(set) var notificationsDenied = false
    private(set) var isPreview = false
    @Published private(set) var message: String?
    @Published private(set) var refreshing = false
    @Published var alertsEnabled = UserDefaults.standard.bool(forKey: "alertsEnabled") {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled") }
    }
    @Published var threshold = UserDefaults.standard.object(forKey: "alertThreshold") as? Int ?? 80 {
        didSet { UserDefaults.standard.set(threshold, forKey: "alertThreshold") }
    }
    private let cloud = UsageCloud()
    private var accountRevision = 0

    init() {
        snapshot = UsageCache.read()
        #if DEBUG
        if let json = ProcessInfo.processInfo.environment["COSTBAR_PREVIEW_JSON"],
           let data = json.data(using: .utf8),
           let sample = try? UsageSnapshot.decode(data) {
            snapshot = sample
            isPreview = true
        }
        #endif
    }

    func accountChanged() async {
        accountRevision += 1
        snapshot = nil
        do { try UsageCache.write(nil) } catch { message = error.localizedDescription }
        UserDefaults.standard.removeObject(forKey: "deliveredAlerts")
        WidgetCenter.shared.reloadAllTimelines()
        await connect()
    }

    func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        notificationsDenied = settings.authorizationStatus == .denied
    }

    func enableAlerts() async {
        guard !requestingNotificationPermission else { return }
        requestingNotificationPermission = true
        defer { requestingNotificationPermission = false }
        do {
            alertsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshNotificationStatus()
            notificationFeedback = alertsEnabled ? "Alerts are ready. Choose the usage level you want to hear about." : "Notifications are disabled in iPhone Settings."
        } catch { notificationFeedback = error.localizedDescription }
    }

    func sendTestNotification() async {
        await refreshNotificationStatus()
        guard notificationsAllowed else {
            notificationFeedback = "Allow notifications in iPhone Settings first."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Costbar notifications are ready"
        content.body = "You’ll hear from us when fresh usage reaches your selected limit."
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "costbar-test", content: content, trigger: nil))
            notificationFeedback = "Test sent. Check your notification banner or Notification Center."
        } catch { notificationFeedback = error.localizedDescription }
    }

    func refresh() async -> Bool {
        guard !isPreview else { return true }
        guard !refreshing else { return false }
        refreshing = true
        let revision = accountRevision
        defer {
            refreshing = false
            if revision != accountRevision { Task { _ = await refresh() } }
        }
        do {
            let latest = try await cloud.fetch()
            guard revision == accountRevision else { return false }
            try UsageCache.write(latest)
            snapshot = latest
            message = latest == nil ? "Enable iPhone sync in Costbar on your Mac, using the same Apple Account." : nil
            WidgetCenter.shared.reloadAllTimelines()
            if let latest, alertsEnabled { try await notify(latest) }
            return true
        } catch {
            guard revision == accountRevision else { return false }
            if let cloudError = error as? CKError, cloudError.code == .notAuthenticated {
                snapshot = nil
                try? UsageCache.write(nil)
                WidgetCenter.shared.reloadAllTimelines()
            }
            message = syncMessage(for: error)
            return false
        }
    }

    func connect() async {
        await refreshNotificationStatus()
        guard !isPreview else { return }
        if await refresh() {
            do {
                try await cloud.subscribe()
                backgroundMessage = nil
            } catch { backgroundMessage = syncMessage(for: error) }
        }
        scheduleRefresh()
    }

    private func syncMessage(for error: Error) -> String {
        guard let cloudError = error as? CKError else { return error.localizedDescription }
        switch cloudError.code {
        case .notAuthenticated:
            return "Sign in to your Apple Account in iPhone Settings, using the same account as your Mac."
        case .networkUnavailable, .networkFailure:
            return "Could not reach iCloud. Check your connection and pull to refresh."
        case .serviceUnavailable, .requestRateLimited:
            return "iCloud is temporarily unavailable. Try refreshing again shortly."
        default:
            return error.localizedDescription
        }
    }

    private func notify(_ snapshot: UsageSnapshot) async throws {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let defaults = UserDefaults.standard
        var delivered = Set(defaults.stringArray(forKey: "deliveredAlerts") ?? [])
        for alert in UsageAlerts.pending(snapshot: snapshot, threshold: threshold, delivered: delivered, now: .now) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
            delivered.insert(alert.id)
            defaults.set(Array(delivered).sorted(), forKey: "deliveredAlerts")
        }
    }

    func scheduleRefresh() {
        guard !isPreview else { return }
        let request = BGAppRefreshTaskRequest(identifier: "com.costbar.mobile.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 900)
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            backgroundMessage = "Background App Refresh is unavailable. Open Costbar to update usage and check alerts."
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated private static let logger = Logger(subsystem: "com.costbar.mobile", category: "notifications")
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Self.logger.info("App delegate started")
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.costbar.mobile.refresh", using: nil) { task in
            Task { @MainActor in
                let work = Task { await MobileStore.shared.refresh() }
                task.expirationHandler = { work.cancel() }
                let success = await work.value
                MobileStore.shared.scheduleRefresh()
                task.setTaskCompleted(success: success)
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.logger.info("Remote notification registration succeeded")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.logger.error("Remote notification registration failed: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        Self.logger.info("Remote usage update received")
        return await MobileStore.shared.refresh() ? .newData : .failed
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
