import Foundation
#if os(iOS)
import UIKit
#endif

/// Who a campaign targets relative to the host app’s premium / IAP status.
public enum AnalyticsAdAudience: String, Sendable, Equatable, Codable {
    /// Default — free / non‑subscribers only.
    case nonPremium = "non_premium"
    case premium
    case everyone
}

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
    public var audience: AnalyticsAdAudience
    public var ads: [AnalyticsAdCreative]

    enum CodingKeys: String, CodingKey {
        case id, name, ads, audience
        case sessionPercent = "session_percent"
        case delaySeconds = "delay_seconds"
    }

    public init(
        id: Int,
        name: String,
        sessionPercent: Int,
        delaySeconds: Int,
        audience: AnalyticsAdAudience = .nonPremium,
        ads: [AnalyticsAdCreative]
    ) {
        self.id = id
        self.name = name
        self.sessionPercent = sessionPercent
        self.delaySeconds = delaySeconds
        self.audience = audience
        self.ads = ads
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sessionPercent = try container.decode(Int.self, forKey: .sessionPercent)
        delaySeconds = try container.decode(Int.self, forKey: .delaySeconds)
        audience = (try? container.decode(AnalyticsAdAudience.self, forKey: .audience)) ?? .nonPremium
        ads = try container.decode([AnalyticsAdCreative].self, forKey: .ads)
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
    /// Explicit override from `Analytics.Ads.setPremium`. `nil` → use configuration callback.
    private static var premiumOverride: Bool?

    static func resetForTests() {
        lock.lock()
        presentedThisSession = false
        autoPresentDisabled = false
        premiumOverride = nil
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

    static func setPremiumOverride(_ value: Bool?) {
        lock.lock()
        premiumOverride = value
        lock.unlock()
    }

    static var premiumOverrideValue: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return premiumOverride
    }
}

extension Analytics {
    /// In-app promotional ads from the Analytics dashboard **Ads** tab.
    ///
    /// After `Analytics.start`, iOS automatically fetches active campaigns and may present
    /// one eligible ad as a sheet (WKWebView + close). Call `disableAutoPresent()` before
    /// `start` if the host app will call `presentIfEligible()` itself.
    ///
    /// Tell the SDK whether the user has an active premium / IAP entitlement via
    /// `setPremium(_:)` or `AnalyticsConfiguration.isPremium` so campaigns can target
    /// non‑premium (default), premium, or everyone.
    public enum Ads {
        /// Disable the automatic sheet that runs after `Analytics.start` (iOS).
        public static func disableAutoPresent() {
            AnalyticsAdsSessionGate.setAutoPresentDisabled(true)
        }

        /// Report the user’s premium / IAP status (call when it changes).
        /// Overrides `AnalyticsConfiguration.isPremium` while set.
        public static func setPremium(_ isPremium: Bool) {
            AnalyticsAdsSessionGate.setPremiumOverride(isPremium)
        }

        /// Fetch enabled campaigns for this app (no presentation).
        public static func refresh(
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> [AnalyticsAdCampaign] {
            let config = try resolvedConfiguration(configuration)
            return try await AnalyticsAdsClient.shared.fetchActive(configuration: config)
        }

        /// Pick one eligible ad (audience, session %, already-installed schemes filtered) without presenting.
        public static func selectEligible(
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> AnalyticsAdSelection? {
            let config = try resolvedConfiguration(configuration)
            let campaigns = try await AnalyticsAdsClient.shared.fetchActive(configuration: config)
            let premium = await resolvePremium(configuration: config)
            return AnalyticsAdsSelector.select(from: campaigns, isPremium: premium)
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
            let premium = await resolvePremium(configuration: config)
            guard let selection = AnalyticsAdsSelector.select(from: campaigns, isPremium: premium) else {
                return nil
            }

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

        fileprivate static func resolvePremium(configuration: AnalyticsConfiguration) async -> Bool {
            if let override = AnalyticsAdsSessionGate.premiumOverrideValue {
                return override
            }
            return await configuration.isPremium()
        }
    }
}

enum AnalyticsAdsSelector {
    static func select(
        from campaigns: [AnalyticsAdCampaign],
        isPremium: Bool
    ) -> AnalyticsAdSelection? {
        var pool: [(AnalyticsAdCampaign, AnalyticsAdCreative)] = []
        for campaign in campaigns {
            guard audienceAllows(campaign.audience, isPremium: isPremium) else { continue }
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

    static func audienceAllows(_ audience: AnalyticsAdAudience, isPremium: Bool) -> Bool {
        switch audience {
        case .everyone:
            return true
        case .premium:
            return isPremium
        case .nonPremium:
            return !isPremium
        }
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
