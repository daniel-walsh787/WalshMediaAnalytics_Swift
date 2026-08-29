import Foundation

enum AnalyticsPushAlertButtonAction: Equatable {
    case dismiss
    case deepLink(String)
    case openURL(String)
}

struct AnalyticsPushAlertButton: Equatable {
    let enabled: Bool
    let text: String
    let action: AnalyticsPushAlertButtonAction
}

struct AnalyticsPushAlertConfig: Equatable {
    let title: String
    let body: String
    let cancel: AnalyticsPushAlertButton
    let confirm: AnalyticsPushAlertButton
}

enum AnalyticsPushAlertParser {
    static func parse(_ alert: [String: Any]) -> AnalyticsPushAlertConfig? {
        let title = alert["title"] as? String ?? ""
        let body = alert["body"] as? String ?? ""
        guard !title.isEmpty || !body.isEmpty else { return nil }

        guard let cancel = parseButton(alert["cancel"], defaultText: "Cancel", allowDismiss: true),
              let confirm = parseButton(alert["confirm"], defaultText: "OK", allowDismiss: false) else {
            return nil
        }

        guard cancel.enabled || confirm.enabled else { return nil }
        if confirm.enabled, case .dismiss = confirm.action { return nil }

        return AnalyticsPushAlertConfig(title: title, body: body, cancel: cancel, confirm: confirm)
    }

    private static func parseButton(
        _ raw: Any?,
        defaultText: String,
        allowDismiss: Bool
    ) -> AnalyticsPushAlertButton? {
        guard let dict = raw as? [String: Any] else { return nil }

        let enabled = dict["enabled"] as? Bool ?? true
        let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (text?.isEmpty == false) ? text! : defaultText

        if dict["action"] as? String == "dismiss" {
            guard allowDismiss else { return nil }
            return AnalyticsPushAlertButton(enabled: enabled, text: label, action: .dismiss)
        }

        guard let actionDict = dict["action"] as? [String: Any] else { return nil }
        let type = actionDict["type"] as? String ?? ""
        let value = (actionDict["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }

        switch type {
        case "open_url":
            return AnalyticsPushAlertButton(enabled: enabled, text: label, action: .openURL(value))
        case "deep_link":
            return AnalyticsPushAlertButton(enabled: enabled, text: label, action: .deepLink(value))
        default:
            return nil
        }
    }
}
