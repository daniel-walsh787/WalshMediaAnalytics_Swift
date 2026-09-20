import Foundation

final class AnalyticsAdsClient: @unchecked Sendable {
    static let shared = AnalyticsAdsClient()

    private let urlSession: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    private struct Credentials {
        var appId: String
        var hmacSecret: String
        var baseURL: URL
    }

    private struct ActiveResponse: Decodable {
        let campaigns: [AnalyticsAdCampaign]?
    }

    private struct WarningBody: Encodable {
        let campaign_id: Int
        let scheme: String
        let app_version: String
        let message: String?
    }

    private struct EventBody: Encodable {
        let type: String
        let campaign_id: Int
        let ad_id: Int
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let message: String?
    }

    func fetchActive(configuration: AnalyticsConfiguration) async throws -> [AnalyticsAdCampaign] {
        let credentials = try credentials(from: configuration)
        let url = credentials.baseURL.appendingPathComponent("v1/ads/active")
        let data = try await signedBodyRequest(
            method: "GET",
            url: url,
            body: Data(),
            credentials: credentials,
            sendContentType: false
        )
        let decoded = try decoder.decode(ActiveResponse.self, from: data)
        return decoded.campaigns ?? []
    }

    func reportWarning(
        configuration: AnalyticsConfiguration,
        campaignId: Int,
        scheme: String,
        appVersion: String,
        message: String? = nil
    ) async throws {
        let credentials = try credentials(from: configuration)
        let body = try encoder.encode(
            WarningBody(
                campaign_id: campaignId,
                scheme: scheme,
                app_version: appVersion,
                message: message
            )
        )
        let url = credentials.baseURL.appendingPathComponent("v1/ads/warnings")
        _ = try await signedBodyRequest(
            method: "POST",
            url: url,
            body: body,
            credentials: credentials
        )
    }

    func reportEvent(
        configuration: AnalyticsConfiguration,
        type: String,
        campaignId: Int,
        adId: Int
    ) async throws {
        let credentials = try credentials(from: configuration)
        let body = try encoder.encode(
            EventBody(type: type, campaign_id: campaignId, ad_id: adId)
        )
        let url = credentials.baseURL.appendingPathComponent("v1/ads/events")
        _ = try await signedBodyRequest(
            method: "POST",
            url: url,
            body: body,
            credentials: credentials
        )
    }

    private func credentials(from configuration: AnalyticsConfiguration) throws -> Credentials {
        guard configuration.isConfigured, let baseURL = configuration.baseURL else {
            throw AnalyticsAdsError.notConfigured
        }
        return Credentials(
            appId: configuration.appId,
            hmacSecret: configuration.hmacSecret,
            baseURL: baseURL
        )
    }

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
            throw AnalyticsAdsError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AnalyticsAdsError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw AnalyticsAdsError.unauthorized
        default:
            let message = (try? decoder.decode(ErrorBody.self, from: data))?.message
                ?? (try? decoder.decode(ErrorBody.self, from: data))?.error
            throw AnalyticsAdsError.httpStatus(http.statusCode, message: message)
        }
    }
}
