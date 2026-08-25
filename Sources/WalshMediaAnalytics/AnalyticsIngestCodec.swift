import CryptoKit
import Foundation

public struct AnalyticsQueuedEvent: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var ts: Int
    public var props: [String: AnalyticsPropValue]

    public init(id: String, name: String, ts: Int, props: [String: AnalyticsPropValue]) {
        self.id = id
        self.name = name
        self.ts = ts
        self.props = props
    }
}

public enum AnalyticsIngestCodec {
    public static func encodeBody(
        platform: String,
        env: String,
        deviceID: String,
        userID: String? = nil,
        events: [AnalyticsQueuedEvent]
    ) throws -> Data {
        let payload = IngestBody(
            device_id: deviceID,
            env: env,
            events: events.map { event in
                IngestEvent(
                    id: event.id,
                    name: event.name,
                    props: event.props.isEmpty ? nil : event.props,
                    ts: event.ts
                )
            },
            platform: platform,
            user_id: Self.normalizedUserID(userID)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    public static func normalizedUserID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...128).contains(trimmed.count) else {
            return nil
        }
        return trimmed
    }

    public static func signatureHex(secret: String, body: Data) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private struct IngestBody: Encodable {
        let device_id: String
        let env: String
        let events: [IngestEvent]
        let platform: String
        let user_id: String?

        enum CodingKeys: String, CodingKey {
            case device_id, env, events, platform, user_id
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(device_id, forKey: .device_id)
            try container.encode(env, forKey: .env)
            try container.encode(events, forKey: .events)
            try container.encode(platform, forKey: .platform)
            if let user_id {
                try container.encode(user_id, forKey: .user_id)
            }
        }
    }

    private struct IngestEvent: Encodable {
        let id: String
        let name: String
        let props: [String: AnalyticsPropValue]?
        let ts: Int

        enum CodingKeys: String, CodingKey {
            case id, name, props, ts
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            if let props, !props.isEmpty {
                try container.encode(props, forKey: .props)
            }
            try container.encode(ts, forKey: .ts)
        }
    }
}
