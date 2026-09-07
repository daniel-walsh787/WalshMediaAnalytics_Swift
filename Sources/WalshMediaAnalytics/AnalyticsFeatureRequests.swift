import Foundation

/// Lifecycle status for a feature request (API snake_case strings).
public enum FeatureRequestStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case pending
    case voting
    case backlog
    case inProgress = "in_progress"
    case comingSoon = "coming_soon"
    case complete
    case rejected
}

/// Ranking for `Analytics.FeatureRequests.list`.
public enum FeatureRequestSort: String, Sendable, Equatable {
    /// `star_count` descending, then newest.
    case stars
    /// Newest first.
    case recent
    /// Custom status priority (`status_order`), then stars.
    case status
}

/// Payload for submitting a new feature request.
public struct FeatureRequestDraft: Sendable, Equatable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// A feature request returned by submit / list.
public struct FeatureRequest: Sendable, Equatable, Codable {
    public var id: String
    public var title: String
    public var body: String
    public var status: FeatureRequestStatus
    public var responseComment: String?
    public var starCount: Int
    public var viewerStarred: Bool
    public var createdAt: Int
    public var updatedAt: Int?

    public init(
        id: String,
        title: String,
        body: String,
        status: FeatureRequestStatus,
        responseComment: String? = nil,
        starCount: Int = 0,
        viewerStarred: Bool = false,
        createdAt: Int,
        updatedAt: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.status = status
        self.responseComment = responseComment
        self.starCount = starCount
        self.viewerStarred = viewerStarred
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, status
        case responseComment = "response_comment"
        case starCount = "star_count"
        case viewerStarred = "viewer_starred"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            id = String(intID)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Expected String or Int id"
            )
        }
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        status = try container.decode(FeatureRequestStatus.self, forKey: .status)
        responseComment = try container.decodeIfPresent(String.self, forKey: .responseComment)
        starCount = try container.decodeIfPresent(Int.self, forKey: .starCount) ?? 0
        viewerStarred = try container.decodeIfPresent(Bool.self, forKey: .viewerStarred) ?? false
        createdAt = try container.decode(Int.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(responseComment, forKey: .responseComment)
        try container.encode(starCount, forKey: .starCount)
        try container.encode(viewerStarred, forKey: .viewerStarred)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

/// Result of `Analytics.FeatureRequests.list` — published rows plus ids to drop from a local cache.
public struct FeatureRequestListResult: Sendable, Equatable {
    public var requests: [FeatureRequest]
    /// Ids demoted to pending after a first inappropriate report (still live, not soft-deleted).
    public var removedIds: [String]

    public init(requests: [FeatureRequest], removedIds: [String] = []) {
        self.requests = requests
        self.removedIds = removedIds
    }
}

/// Result of `Analytics.FeatureRequests.report`.
public struct FeatureRequestReportResult: Sendable, Equatable {
    /// True when this device/user already reported the request (no-op).
    public var alreadyReported: Bool
    /// True when this was the first unique report and the request was demoted to pending.
    public var demoted: Bool
    public var reportCount: Int
    public var request: FeatureRequest?

    public init(
        alreadyReported: Bool,
        demoted: Bool = false,
        reportCount: Int = 0,
        request: FeatureRequest? = nil
    ) {
        self.alreadyReported = alreadyReported
        self.demoted = demoted
        self.reportCount = reportCount
        self.request = request
    }
}

public enum AnalyticsFeatureRequestsError: Error, Equatable, LocalizedError {
    case notConfigured
    case unauthorized
    case quotaExceeded
    case notFound
    case invalidResponse
    case httpStatus(Int, message: String?)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Analytics Feature Requests is not configured (missing app id or HMAC secret)."
        case .unauthorized:
            return "Feature request request was rejected (401/403). Check ANALYTICS_APPNAME and ANALYTICS_HMAC_SECRET."
        case .quotaExceeded:
            return "Feature request quota exceeded (402). Add credits or wait for the free-tier reset."
        case .notFound:
            return "Feature request was not found (404)."
        case .invalidResponse:
            return "Feature request response could not be parsed."
        case .httpStatus(let code, let message):
            if let message, !message.isEmpty {
                return "Feature request HTTP \(code): \(message)"
            }
            return "Feature request HTTP \(code)"
        case .transport(let message):
            return "Feature request transport error: \(message)"
        }
    }
}

extension Analytics {
    /// Client feature-request API. Same `ANALYTICS_APPNAME` + HMAC secret as ingest / OTA / push.
    ///
    /// ```swift
    /// Analytics.start(.fromInfoPlist(userID: { await myAccountId() }))
    /// let created = try await Analytics.FeatureRequests.submit(
    ///     FeatureRequestDraft(title: "Dark mode", body: "Please add a dark theme.")
    /// )
    /// let page = try await Analytics.FeatureRequests.list(sort: .stars)
    /// try await Analytics.FeatureRequests.star(id: page.requests[0].id)
    /// try await Analytics.FeatureRequests.report(id: page.requests[0].id, message: "Spam")
    /// ```
    public enum FeatureRequests {
        /// Create a request (`pending` until moderated).
        @discardableResult
        public static func submit(
            _ draft: FeatureRequestDraft,
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> FeatureRequest {
            let configuration = try resolved(configuration)
            await cacheEnvironment(configuration)
            return try await AnalyticsFeatureRequestsClient.shared.submit(
                draft: draft,
                configuration: configuration
            )
        }

        /// Published requests (excludes `pending` and soft-deleted). Pass `device_id` / `user_id`
        /// automatically so `viewer_starred` is accurate. Use `removedIds` to drop demoted rows
        /// from a local cache.
        public static func list(
            sort: FeatureRequestSort = .stars,
            statusOrder: [FeatureRequestStatus]? = nil,
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> FeatureRequestListResult {
            let configuration = try resolved(configuration)
            await cacheEnvironment(configuration)
            return try await AnalyticsFeatureRequestsClient.shared.list(
                sort: sort,
                statusOrder: statusOrder,
                configuration: configuration
            )
        }

        public static func star(
            id: String,
            using configuration: AnalyticsConfiguration? = nil
        ) async throws {
            let configuration = try resolved(configuration)
            await cacheEnvironment(configuration)
            try await AnalyticsFeatureRequestsClient.shared.star(
                id: id,
                configuration: configuration
            )
        }

        public static func unstar(
            id: String,
            using configuration: AnalyticsConfiguration? = nil
        ) async throws {
            let configuration = try resolved(configuration)
            await cacheEnvironment(configuration)
            try await AnalyticsFeatureRequestsClient.shared.unstar(
                id: id,
                configuration: configuration
            )
        }

        /// Report an inappropriate published request. Does **not** emit analytics track events —
        /// the Worker records the report and bumps alert matches server-side.
        @discardableResult
        public static func report(
            id: String,
            message: String? = nil,
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> FeatureRequestReportResult {
            let configuration = try resolved(configuration)
            await cacheEnvironment(configuration)
            return try await AnalyticsFeatureRequestsClient.shared.report(
                id: id,
                message: message,
                configuration: configuration
            )
        }

        private static func resolved(_ configuration: AnalyticsConfiguration?) throws -> AnalyticsConfiguration {
            if let configuration { return configuration }
            if let stored = AnalyticsRuntime.configuration() { return stored }
            throw AnalyticsFeatureRequestsError.notConfigured
        }

        private static func cacheEnvironment(_ configuration: AnalyticsConfiguration) async {
            let env = await configuration.environment()
            AnalyticsRuntime.setEnvironment(env)
        }
    }
}
