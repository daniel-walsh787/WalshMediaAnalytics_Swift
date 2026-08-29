import Foundation

#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

extension Analytics {
    /// Optional push notification support. Apps that do not call these methods
    /// do not need the Push Notifications capability or any push setup.
    public enum Push {}
}

#if canImport(UIKit)
extension Analytics.Push {
    /// Request notification permission and register with APNs. No-op when analytics is not configured.
    public static func registerForRemoteNotifications() {
        guard AnalyticsRuntime.configuration()?.isConfigured == true else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else { return }
                UIApplication.shared.registerForRemoteNotifications()
            } catch {
                print("[WalshMediaAnalytics] push authorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// Forward from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public static func didRegister(deviceToken: Data) {
        Task {
            await AnalyticsPushClient.shared.upload(deviceToken: deviceToken)
        }
    }

    /// Forward from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    public static func didFailToRegister(error: Error) {
        print("[WalshMediaAnalytics] APNs registration failed: \(error.localizedDescription)")
    }

    /// Forward from `userNotificationCenter(_:didReceive:withCompletionHandler:)` for background delivery.
    public static func handleRemoteNotification(userInfo: [AnyHashable: Any]) {
        Task { @MainActor in
            AnalyticsPushHandler.shared.handleDelivery(userInfo: userInfo, performAction: false)
        }
    }

    /// Forward from `userNotificationCenter(_:didReceive:withCompletionHandler:)` when the user interacts.
    public static func handleNotificationResponse(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            AnalyticsPushHandler.shared.handleDelivery(userInfo: userInfo, performAction: true)
        }
    }
}
#endif
