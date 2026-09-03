import Foundation

enum AnalyticsFeatureRequestsCodec {
    struct SubmitBody: Encodable {
        let title: String
        let body: String
        let device_id: String
        let env: String
        let user_id: String?

        enum CodingKeys: String, CodingKey {
            case title, body, device_id, env, user_id
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(body, forKey: .body)
            try container.encode(device_id, forKey: .device_id)
            try container.encode(env, forKey: .env)
            if let user_id {
                try container.encode(user_id, forKey: .user_id)
            }
        }
    }

    struct VoterBody: Encodable {
        let device_id: String
        let user_id: String?

        enum CodingKeys: String, CodingKey {
            case device_id, user_id
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(device_id, forKey: .device_id)
            if let user_id {
                try container.encode(user_id, forKey: .user_id)
            }
        }
    }

    struct ListResponse: Decodable {
        let requests: [FeatureRequest]?
        let items: [FeatureRequest]?
        let feature_requests: [FeatureRequest]?

        var all: [FeatureRequest]? {
            requests ?? items ?? feature_requests
        }
    }

    struct SubmitResponse: Decodable {
        let request: FeatureRequest?
    }

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func jsonDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    static func encodeSubmit(
        title: String,
        body: String,
        deviceID: String,
        env: String,
        userID: String?
    ) throws -> Data {
        try jsonEncoder().encode(
            SubmitBody(
                title: title,
                body: body,
                device_id: deviceID,
                env: env,
                user_id: AnalyticsIngestCodec.normalizedUserID(userID)
            )
        )
    }

    static func encodeVoter(deviceID: String, userID: String?) throws -> Data {
        try jsonEncoder().encode(
            VoterBody(
                device_id: deviceID,
                user_id: AnalyticsIngestCodec.normalizedUserID(userID)
            )
        )
    }

    static func decodeSubmit(_ data: Data) throws -> FeatureRequest {
        if let wrapped = try? jsonDecoder().decode(SubmitResponse.self, from: data),
           let request = wrapped.request {
            return request
        }
        if let request = try? jsonDecoder().decode(FeatureRequest.self, from: data) {
            return request
        }
        throw AnalyticsFeatureRequestsError.invalidResponse
    }

    static func decodeList(_ data: Data) throws -> [FeatureRequest] {
        if let array = try? jsonDecoder().decode([FeatureRequest].self, from: data) {
            return array
        }
        if let wrapped = try? jsonDecoder().decode(ListResponse.self, from: data),
           let requests = wrapped.all {
            return requests
        }
        throw AnalyticsFeatureRequestsError.invalidResponse
    }

    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        return nil
    }
}

actor AnalyticsFeatureRequestsClient {
    static let shared = AnalyticsFeatureRequestsClient()

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func submit(
        draft: FeatureRequestDraft,
        configuration: AnalyticsConfiguration
    ) async throws -> FeatureRequest {
        let credentials = try credentials(from: configuration)
        let context = try await requestContext(configuration: configuration)
        let body = try AnalyticsFeatureRequestsCodec.encodeSubmit(
            title: draft.title,
            body: draft.body,
            deviceID: context.deviceID,
            env: context.env,
            userID: context.userID
        )
        let url = credentials.baseURL.appendingPathComponent("v1/feature-requests")
        let data = try await signedBodyRequest(
            method: "POST",
            url: url,
            body: body,
            credentials: credentials
        )
        return try AnalyticsFeatureRequestsCodec.decodeSubmit(data)
    }

    func list(
        sort: FeatureRequestSort,
        statusOrder: [FeatureRequestStatus]?,
        configuration: AnalyticsConfiguration
    ) async throws -> [FeatureRequest] {
        let credentials = try credentials(from: configuration)
        let context = try await requestContext(configuration: configuration)
        let url = try listURL(
            baseURL: credentials.baseURL,
            sort: sort,
            statusOrder: statusOrder,
            deviceID: context.deviceID,
            userID: context.userID
        )
        // Empty-body ingest HMAC (same `{timestamp}.` form as push/ingest). Query is not signed.
        let data = try await signedBodyRequest(
            method: "GET",
            url: url,
            body: Data(),
            credentials: credentials,
            sendContentType: false
        )
        return try AnalyticsFeatureRequestsCodec.decodeList(data)
    }

    func star(id: String, configuration: AnalyticsConfiguration) async throws {
        try await vote(id: id, method: "POST", configuration: configuration)
    }

    func unstar(id: String, configuration: AnalyticsConfiguration) async throws {
        try await vote(id: id, method: "DELETE", configuration: configuration)
    }

    private func vote(
        id: String,
        method: String,
        configuration: AnalyticsConfiguration
    ) async throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AnalyticsFeatureRequestsError.invalidResponse
        }
        let credentials = try credentials(from: configuration)
        let context = try await requestContext(configuration: configuration)
        let body = try AnalyticsFeatureRequestsCodec.encodeVoter(
            deviceID: context.deviceID,
            userID: context.userID
        )
        let url = credentials.baseURL
            .appendingPathComponent("v1/feature-requests")
            .appendingPathComponent(trimmed)
            .appendingPathComponent("star")
        _ = try await signedBodyRequest(
            method: method,
            url: url,
            body: body,
            credentials: credentials
        )
    }

    private struct Credentials {
        var appId: String
        var hmacSecret: String
        var baseURL: URL
    }

    private struct RequestContext {
        var deviceID: String
        var env: String
        var userID: String?
    }

    private func credentials(from configuration: AnalyticsConfiguration) throws -> Credentials {
        guard configuration.isConfigured, let baseURL = configuration.baseURL else {
            throw AnalyticsFeatureRequestsError.notConfigured
        }
        return Credentials(
            appId: configuration.appId,
            hmacSecret: configuration.hmacSecret,
            baseURL: baseURL
        )
    }

    private func requestContext(configuration: AnalyticsConfiguration) async throws -> RequestContext {
        let env: String
        if let stored = AnalyticsRuntime.environment() {
            env = stored
        } else {
            env = await configuration.environment()
            AnalyticsRuntime.setEnvironment(env)
        }
        return RequestContext(
            deviceID: AnalyticsInstallID.current(appId: configuration.appId),
            env: env,
            userID: await configuration.userID()
        )
    }

    private func listURL(
        baseURL: URL,
        sort: FeatureRequestSort,
        statusOrder: [FeatureRequestStatus]?,
        deviceID: String,
        userID: String?
    ) throws -> URL {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/feature-requests"),
            resolvingAgainstBaseURL: false
        ) else {
            throw AnalyticsFeatureRequestsError.invalidResponse
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "device_id", value: deviceID),
        ]
        if let order = statusOrder, !order.isEmpty {
            items.append(
                URLQueryItem(
                    name: "status_order",
                    value: order.map(\.rawValue).joined(separator: ",")
                )
            )
        }
        if let userID = AnalyticsIngestCodec.normalizedUserID(userID) {
            items.append(URLQueryItem(name: "user_id", value: userID))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw AnalyticsFeatureRequestsError.invalidResponse
        }
        return url
    }

    /// HMAC like push/ingest: `X-Timestamp` + signature of `{timestamp}.{rawBody}`.
    private func signedBodyRequest(
        method: String,
        url: URL,
        body: Data,
        credentials: Credentials,
        sendContentType: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(credentials.appId, forHTTPHeaderField: "X-App-Id")
        if sendContentType {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let signed = AnalyticsIngestCodec.ingestSignedPayload(timestamp: timestamp, body: body)
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(
            AnalyticsIngestCodec.signatureHex(secret: credentials.hmacSecret, payload: signed),
            forHTTPHeaderField: "X-Signature"
        )
        if method != "GET" || !body.isEmpty {
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AnalyticsFeatureRequestsError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AnalyticsFeatureRequestsError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw AnalyticsFeatureRequestsError.unauthorized
        case 402:
            throw AnalyticsFeatureRequestsError.quotaExceeded
        case 404:
            throw AnalyticsFeatureRequestsError.notFound
        default:
            throw AnalyticsFeatureRequestsError.httpStatus(
                http.statusCode,
                message: AnalyticsFeatureRequestsCodec.errorMessage(from: data)
            )
        }
    }
}
