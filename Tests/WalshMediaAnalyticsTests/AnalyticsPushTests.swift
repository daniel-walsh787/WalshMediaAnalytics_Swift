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
}
