import Foundation
#if os(iOS)
import UIKit
#endif

/// An ad creative returned by `GET /v1/ads/active`.
public struct AnalyticsAdCreative: Sendable, Equatable, Codable {
    public var id: Int
    public var htmlURL: String
    public var iosURLScheme: String?
    public var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case htmlURL = "html_url"
        case iosURLScheme = "ios_url_scheme"
        case sortOrder = "sort_order"
    }

    public init(id: Int, htmlURL: String, iosURLScheme: String? = nil, sortOrder: Int = 0) {
        self.id = id
        self.htmlURL = htmlURL
        self.iosURLScheme = iosURLScheme
        self.sortOrder = sortOrder
    }
}

/// A campaign returned by `GET /v1/ads/active`.
public struct AnalyticsAdCampaign: Sendable, Equatable, Codable {
    public var id: Int
    public var name: String
    public var sessionPercent: Int
    public var delaySeconds: Int
    public var ads: [AnalyticsAdCreative]

    enum CodingKeys: String, CodingKey {
        case id, name, ads
        case sessionPercent = "session_percent"
        case delaySeconds = "delay_seconds"
    }

    public init(
        id: Int,
        name: String,
        sessionPercent: Int,
        delaySeconds: Int,
        ads: [AnalyticsAdCreative]
    ) {
        self.id = id
        self.name = name
        self.sessionPercent = sessionPercent
        self.delaySeconds = delaySeconds
        self.ads = ads
    }
}

/// Selected creative plus its parent campaign (after session % + install filtering).
public struct AnalyticsAdSelection: Sendable, Equatable {
    public var campaign: AnalyticsAdCampaign
    public var ad: AnalyticsAdCreative

    public init(campaign: AnalyticsAdCampaign, ad: AnalyticsAdCreative) {
        self.campaign = campaign
        self.ad = ad
    }
}

public enum AnalyticsAdsError: Error, Equatable, LocalizedError {
    case notConfigured
    case unauthorized
    case invalidResponse
    case httpStatus(Int, message: String?)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Analytics Ads is not configured (missing app id or HMAC secret)."
        case .unauthorized:
            return "Ads request was rejected (401/403). Check ANALYTICS_APPNAME and ANALYTICS_HMAC_SECRET."
        case .invalidResponse:
            return "Ads response could not be parsed."
        case .httpStatus(let code, let message):
            if let message, !message.isEmpty {
                return "Ads HTTP \(code): \(message)"
            }
            return "Ads HTTP \(code)"
        case .transport(let message):
            return "Ads transport error: \(message)"
        }
    }
}

enum AnalyticsAdsSessionGate {
    private static let lock = NSLock()
    private static var presentedThisSession = false
    private static var autoPresentDisabled = false

    static func resetForTests() {
        lock.lock()
        presentedThisSession = false
        autoPresentDisabled = false
        lock.unlock()
    }

    static var hasPresentedThisSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return presentedThisSession
    }

    static func markPresented() {
        lock.lock()
        presentedThisSession = true
        lock.unlock()
    }

    static var isAutoPresentDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return autoPresentDisabled
    }

    static func setAutoPresentDisabled(_ value: Bool) {
        lock.lock()
        autoPresentDisabled = value
        lock.unlock()
    }
}

extension Analytics {
    /// In-app promotional ads from the Analytics dashboard **Ads** tab.
    ///
    /// After `Analytics.start`, iOS automatically fetches active campaigns and may present
    /// one eligible ad as a sheet (WKWebView + close). Call `disableAutoPresent()` before
    /// `start` if the host app will call `presentIfEligible()` itself.
    public enum Ads {
        /// Disable the automatic sheet that runs after `Analytics.start` (iOS).
        public static func disableAutoPresent() {
            AnalyticsAdsSessionGate.setAutoPresentDisabled(true)
        }

        /// Fetch enabled campaigns for this app (no presentation).
        public static func refresh(
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> [AnalyticsAdCampaign] {
            let config = try resolvedConfiguration(configuration)
            return try await AnalyticsAdsClient.shared.fetchActive(configuration: config)
        }

        /// Pick one eligible ad (session %, already-installed schemes filtered) without presenting.
        public static func selectEligible(
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> AnalyticsAdSelection? {
            let campaigns = try await refresh(using: configuration)
            return AnalyticsAdsSelector.select(from: campaigns)
        }

        /// Fetch, select, wait for campaign delay, then present (iOS sheet). No-op if already shown this session.
        @discardableResult
        public static func presentIfEligible(
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> AnalyticsAdSelection? {
            guard !AnalyticsAdsSessionGate.hasPresentedThisSession else { return nil }
            let config = try resolvedConfiguration(configuration)
            let campaigns = try await AnalyticsAdsClient.shared.fetchActive(configuration: config)
            await AnalyticsAdsSelector.reportMissingSchemes(
                campaigns: campaigns,
                configuration: config
            )
            guard let selection = AnalyticsAdsSelector.select(from: campaigns) else { return nil }

            let delay = max(0, selection.campaign.delaySeconds)
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
            guard !AnalyticsAdsSessionGate.hasPresentedThisSession else { return nil }

            #if os(iOS)
            let presented = await MainActor.run {
                AnalyticsAdsPresenter.shared.present(selection: selection, configuration: config)
            }
            if presented {
                AnalyticsAdsSessionGate.markPresented()
                return selection
            }
            return nil
            #else
            return selection
            #endif
        }

        fileprivate static func resolvedConfiguration(
            _ configuration: AnalyticsConfiguration?
        ) throws -> AnalyticsConfiguration {
            if let configuration { return configuration }
            if let stored = AnalyticsRuntime.configuration() { return stored }
            throw AnalyticsAdsError.notConfigured
        }
    }
}

enum AnalyticsAdsSelector {
    static func select(from campaigns: [AnalyticsAdCampaign]) -> AnalyticsAdSelection? {
        var pool: [(AnalyticsAdCampaign, AnalyticsAdCreative)] = []
        for campaign in campaigns {
            let percent = max(0, min(100, campaign.sessionPercent))
            guard percent > 0 else { continue }
            if percent < 100 {
                let roll = Int.random(in: 1...100)
                if roll > percent { continue }
            }
            for ad in campaign.ads {
                if let scheme = normalizedScheme(ad.iosURLScheme), canOpenScheme(scheme) {
                    continue
                }
                pool.append((campaign, ad))
            }
        }
        guard let pick = pool.randomElement() else { return nil }
        return AnalyticsAdSelection(campaign: pick.0, ad: pick.1)
    }

    static func reportMissingSchemes(
        campaigns: [AnalyticsAdCampaign],
        configuration: AnalyticsConfiguration
    ) async {
        let declared = declaredQuerySchemes()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        for campaign in campaigns {
            for ad in campaign.ads {
                guard let scheme = normalizedScheme(ad.iosURLScheme) else { continue }
                if declared.contains(scheme) { continue }
                try? await AnalyticsAdsClient.shared.reportWarning(
                    configuration: configuration,
                    campaignId: campaign.id,
                    scheme: scheme,
                    appVersion: version
                )
                Analytics.track(
                    "ad_scheme_warning",
                    [
                        "campaign_id": .int(campaign.id),
                        "ad_id": .int(ad.id),
                        "scheme": .string(scheme),
                        "version": .string(version),
                    ]
                )
            }
        }
    }

    static func normalizedScheme(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else {
            return nil
        }
        if let range = s.range(of: "://") {
            s = String(s[..<range.lowerBound])
        }
        if s.hasSuffix(":") {
            s.removeLast()
        }
        guard s.first?.isLetter == true else { return nil }
        return s
    }

    static func declaredQuerySchemes() -> Set<String> {
        let raw = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        return Set(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    static func canOpenScheme(_ scheme: String) -> Bool {
        #if os(iOS)
        guard let url = URL(string: "\(scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
        #else
        return false
        #endif
    }
}
