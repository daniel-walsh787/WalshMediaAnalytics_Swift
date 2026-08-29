import Foundation

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AnalyticsPushHandler {
    static let shared = AnalyticsPushHandler()

    private var recordedPushIDs: Set<Int> = []
    private let defaultsKeyPrefix = "push.received.ids."

    private init() {}

    func handleDelivery(userInfo: [AnyHashable: Any], performAction: Bool) {
        if let pushID = extractPushID(userInfo) {
            recordPushReceived(pushID)
        }
        if performAction {
            runPayloadAction(from: userInfo)
        }
    }

    private func extractPushID(_ userInfo: [AnyHashable: Any]) -> Int? {
        guard let raw = userInfo["wm_push_id"] else { return nil }
        if let value = raw as? Int, value > 0 { return value }
        if let value = raw as? NSNumber { return value.intValue > 0 ? value.intValue : nil }
        if let value = raw as? String, let parsed = Int(value), parsed > 0 { return parsed }
        return nil
    }

    private func recordPushReceived(_ pushID: Int) {
        guard !recordedPushIDs.contains(pushID) else { return }
        let appId = AnalyticsRuntime.configuration()?.appId ?? "app"
        let key = defaultsKeyPrefix + appId
        var stored = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
        if stored.contains(pushID) {
            recordedPushIDs.insert(pushID)
            return
        }
        recordedPushIDs.insert(pushID)
        stored.insert(pushID)
        if stored.count > 200 {
            stored = Set(stored.sorted().suffix(200))
        }
        UserDefaults.standard.set(Array(stored), forKey: key)
        Analytics.track("push_received", ["push_id": .int(pushID)])
    }

    private func runPayloadAction(from userInfo: [AnyHashable: Any]) {
        guard let action = userInfo["wm_action"] as? [String: Any] else { return }
        let type = action["type"] as? String ?? ""

        switch type {
        case "deep_link":
            if let link = action["deep_link"] as? String {
                openDeepLink(link)
            }
        case "show_alert":
            guard let alert = action["alert"] as? [String: Any] else { return }
            presentAlert(alert)
        default:
            break
        }
    }

    #if canImport(UIKit)
    private func openDeepLink(_ link: String) {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        UIApplication.shared.open(url)
    }

    private func openURL(_ link: String) {
        openDeepLink(link)
    }

    private func presentAlert(_ alert: [String: Any]) {
        guard let config = AnalyticsPushAlertParser.parse(alert) else { return }
        guard let presenter = topViewController() else { return }

        let controller = UIAlertController(
            title: config.title,
            message: config.body,
            preferredStyle: .alert
        )

        if config.cancel.enabled {
            controller.addAction(
                UIAlertAction(title: config.cancel.text, style: .cancel)
            )
        }

        if config.confirm.enabled {
            controller.addAction(
                UIAlertAction(title: config.confirm.text, style: .default) { _ in
                    switch config.confirm.action {
                    case .dismiss:
                        break
                    case .deepLink(let link):
                        self.openDeepLink(link)
                    case .openURL(let link):
                        self.openURL(link)
                    }
                }
            )
        }

        presenter.present(controller, animated: true)
    }

    private func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
    #else
    private func openDeepLink(_ link: String) {}
    private func openURL(_ link: String) {}
    private func presentAlert(_ alert: [String: Any]) {}
    #endif
}
