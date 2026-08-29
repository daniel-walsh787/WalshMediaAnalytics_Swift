import Foundation
import Testing
@testable import WalshMediaAnalytics

struct AnalyticsPushTests {
    @Test func pushRegisterCodec_hexToken() {
        let data = Data([0x01, 0xAB, 0xFF])
        #expect(AnalyticsPushRegisterCodec.hexToken(data) == "01abff")
    }

    @Test func pushRegisterCodec_encodesSortedKeys() throws {
        let body = try AnalyticsPushRegisterCodec.encodeBody(
            platform: "ios",
            env: "prod",
            deviceID: "device-1",
            userID: "user-1",
            apnsTokenHex: "abc123"
        )
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["platform"] as? String == "ios")
        #expect(json?["env"] as? String == "prod")
        #expect(json?["device_id"] as? String == "device-1")
        #expect(json?["user_id"] as? String == "user-1")
        #expect(json?["apns_token"] as? String == "abc123")
    }

    @Test func pushRegisterCodec_omitsEmptyUserID() throws {
        let body = try AnalyticsPushRegisterCodec.encodeBody(
            platform: "ios",
            env: "dev",
            deviceID: "device-1",
            userID: nil,
            apnsTokenHex: "deadbeef"
        )
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["user_id"] == nil)
    }

    @Test func alertParser_bothButtonsEnabled() {
        let alert: [String: Any] = [
            "title": "Hello",
            "body": "World",
            "cancel": ["enabled": true, "text": "Cancel", "action": "dismiss"],
            "confirm": [
                "enabled": true,
                "text": "OK",
                "action": ["type": "deep_link", "value": "myapp://home"],
            ],
        ]
        let parsed = AnalyticsPushAlertParser.parse(alert)
        #expect(parsed?.cancel.enabled == true)
        #expect(parsed?.confirm.enabled == true)
        #expect(parsed?.confirm.action == .deepLink("myapp://home"))
    }

    @Test func alertParser_confirmOnly() {
        let alert: [String: Any] = [
            "title": "Update",
            "body": "Tap to continue",
            "cancel": ["enabled": false, "text": "Cancel", "action": "dismiss"],
            "confirm": [
                "enabled": true,
                "text": "Continue",
                "action": ["type": "open_url", "value": "https://example.com"],
            ],
        ]
        let parsed = AnalyticsPushAlertParser.parse(alert)
        #expect(parsed?.cancel.enabled == false)
        #expect(parsed?.confirm.enabled == true)
        #expect(parsed?.confirm.action == .openURL("https://example.com"))
    }

    @Test func alertParser_cancelOnly() {
        let alert: [String: Any] = [
            "title": "Notice",
            "body": "Please read",
            "cancel": ["enabled": true, "text": "Got it", "action": "dismiss"],
            "confirm": [
                "enabled": false,
                "text": "OK",
                "action": ["type": "deep_link", "value": "myapp://x"],
            ],
        ]
        let parsed = AnalyticsPushAlertParser.parse(alert)
        #expect(parsed?.cancel.enabled == true)
        #expect(parsed?.confirm.enabled == false)
    }

    @Test func alertParser_rejectsBothDisabled() {
        let alert: [String: Any] = [
            "title": "Hello",
            "body": "World",
            "cancel": ["enabled": false, "text": "Cancel", "action": "dismiss"],
            "confirm": [
                "enabled": false,
                "text": "OK",
                "action": ["type": "deep_link", "value": "myapp://home"],
            ],
        ]
        #expect(AnalyticsPushAlertParser.parse(alert) == nil)
    }

    @Test func alertParser_rejectsLegacyFlatKeys() {
        let alert: [String: Any] = [
            "title": "Hello",
            "body": "World",
            "cancel_text": "Cancel",
            "confirm_text": "OK",
            "confirm_action": ["type": "deep_link", "value": "myapp://home"],
        ]
        #expect(AnalyticsPushAlertParser.parse(alert) == nil)
    }
}
