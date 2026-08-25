import Foundation

/// Per-app ingest settings. Storage keys and the install-id keychain item are
/// namespaced by `appId` (`airbook` keeps existing AirBook keys).
public struct AnalyticsConfiguration: Sendable {
    public var appId: String
    public var ingestURL: URL?
    public var hmacSecret: String
    public var platform: String
    public var reportsCrashes: Bool
    public var environment: @Sendable () async -> String
    public var userID: @Sendable () async -> String?

    public init(
        appId: String,
        ingestURL: URL?,
        hmacSecret: String,
        platform: String = Self.currentPlatform,
        reportsCrashes: Bool = true,
        environment: @escaping @Sendable () async -> String = { await AnalyticsEnvironment.current() },
        userID: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.appId = appId
        self.ingestURL = ingestURL
        self.hmacSecret = hmacSecret
        self.platform = platform
        self.reportsCrashes = reportsCrashes
        self.environment = environment
        self.userID = userID
    }

    public static let defaultIngestURL = URL(string: "https://analytics.walshmedia.net.au/v1/ingest")

    public var isConfigured: Bool {
        ingestURL != nil && !hmacSecret.isEmpty && !appId.isEmpty
    }

    public static var currentPlatform: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }

    /// Maps StoreKit / Debug channel names onto ingest `env` (`dev` | `testflight` | `prod`).
    public static func ingestEnvironment(fromSignInTier tier: String) -> String {
        AnalyticsEnvironment.ingestValue(fromSignInTier: tier)
    }

    /// Reads `ANALYTICS_APPNAME` and `ANALYTICS_HMAC_SECRET` from Info.plist
    /// (xcconfig → Info.plist). Ingest URL is built into the package. An empty /
    /// `$(…)` secret disables flushing.
    public static func fromInfoPlist(
        appId: String? = nil,
        bundle: Bundle = .main,
        platform: String = currentPlatform,
        reportsCrashes: Bool = true,
        environment: (@Sendable () async -> String)? = nil,
        userID: @escaping @Sendable () async -> String? = { nil }
    ) -> AnalyticsConfiguration {
        AnalyticsConfiguration(
            appId: normalizedAppId(appId) ?? plistAppId(from: bundle) ?? "",
            ingestURL: defaultIngestURL,
            hmacSecret: hmacSecret(from: bundle),
            platform: platform,
            reportsCrashes: reportsCrashes,
            environment: environment ?? { await AnalyticsEnvironment.current() },
            userID: userID
        )
    }

    /// Ingest slug (`airbook`, `echomix`, …). Lowercased; ignores empty / `$(…)` placeholders.
    public static func normalizedAppId(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$(") else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func plistAppId(from bundle: Bundle) -> String? {
        normalizedAppId(bundle.object(forInfoDictionaryKey: "ANALYTICS_APPNAME") as? String)
    }

    private static func hmacSecret(from bundle: Bundle) -> String {
        (bundle.object(forInfoDictionaryKey: "ANALYTICS_HMAC_SECRET") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfPlaceholder ?? ""
    }
}

private extension String {
    var nilIfPlaceholder: String? {
        if isEmpty || hasPrefix("$(") { return nil }
        return self
    }
}
