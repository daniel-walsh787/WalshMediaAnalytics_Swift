import Foundation

enum AnalyticsPushRegisterCodec {
    struct Body: Encodable {
        let platform: String
        let env: String
        let device_id: String
        let user_id: String?
        let apns_token: String

        enum CodingKeys: String, CodingKey {
            case platform, env, device_id, user_id, apns_token
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(platform, forKey: .platform)
            try container.encode(env, forKey: .env)
            try container.encode(device_id, forKey: .device_id)
            try container.encode(apns_token, forKey: .apns_token)
            if let user_id {
                try container.encode(user_id, forKey: .user_id)
            }
        }
    }

    static func encodeBody(
        platform: String,
        env: String,
        deviceID: String,
        userID: String?,
        apnsTokenHex: String
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            Body(
                platform: platform,
                env: env,
                device_id: deviceID,
                user_id: AnalyticsIngestCodec.normalizedUserID(userID),
                apns_token: apnsTokenHex
            )
        )
    }

    static func hexToken(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }
}

actor AnalyticsPushClient {
    static let shared = AnalyticsPushClient()

    private var lastUploadedTokenHex: String?

    func upload(deviceToken: Data) async {
        guard let configuration = AnalyticsRuntime.configuration(), configuration.isConfigured else { return }
        guard let base = configuration.baseURL else { return }
        let url = base.appendingPathComponent("v1/push/register")

        let tokenHex = AnalyticsPushRegisterCodec.hexToken(deviceToken)
        if tokenHex == lastUploadedTokenHex { return }

        let env = await resolvedEnvironment(configuration: configuration)
        let userID = await configuration.userID()
        let deviceID = AnalyticsInstallID.current(appId: configuration.appId)

        let body: Data
        do {
            body = try AnalyticsPushRegisterCodec.encodeBody(
                platform: configuration.platform,
                env: env,
                deviceID: deviceID,
                userID: userID,
                apnsTokenHex: tokenHex
            )
        } catch {
            print("[WalshMediaAnalytics] push register encode failed: \(error.localizedDescription)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.appId, forHTTPHeaderField: "X-App-Id")
        let timestamp = Int(Date().timeIntervalSince1970)
        let signed = AnalyticsIngestCodec.ingestSignedPayload(timestamp: timestamp, body: body)
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(
            AnalyticsIngestCodec.signatureHex(secret: configuration.hmacSecret, payload: signed),
            forHTTPHeaderField: "X-Signature"
        )
        request.httpBody = body
        request.timeoutInterval = 20

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if (200...299).contains(http.statusCode) {
                lastUploadedTokenHex = tokenHex
            } else {
                print("[WalshMediaAnalytics] push register HTTP \(http.statusCode)")
            }
        } catch {
            print("[WalshMediaAnalytics] push register failed: \(error.localizedDescription)")
        }
    }

    private func resolvedEnvironment(configuration: AnalyticsConfiguration) async -> String {
        if let stored = AnalyticsRuntime.environment() { return stored }
        let env = await configuration.environment()
        AnalyticsRuntime.setEnvironment(env)
        return env
    }
}
