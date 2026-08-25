import Foundation
import StoreKit
import os

/// Resolves ingest `env` (`dev` | `testflight` | `prod`) the same way AirBook
/// distinguishes TestFlight from App Store — several signals, any sandbox hit wins.
public enum AnalyticsEnvironment {
    private static let cache = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Cached after the first resolve so flushes do not re-hit StoreKit.
    public static func current(bundle: Bundle = .main) async -> String {
        if let cached = cache.withLock({ $0 }) {
            return cached
        }
        let resolved = await resolve(bundle: bundle)
        cache.withLock { cache in
            if cache == nil { cache = resolved }
        }
        return cache.withLock({ $0 }) ?? resolved
    }

    /// Maps StoreKit / Debug channel names onto ingest `env`.
    public static func ingestValue(fromSignInTier tier: String) -> String {
        switch tier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development", "dev":
            return "dev"
        case "testflight":
            return "testflight"
        default:
            return "prod"
        }
    }

    /// Parses `ANALYTICS_ENV` / `AIRBOOK_SIGN_IN_TIER` style overrides.
    public static func override(fromPlistValue raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$(") else {
            return nil
        }
        return ingestValue(fromSignInTier: trimmed)
    }

    static func hasSandboxReceipt(url: URL?) -> Bool {
        url?.lastPathComponent == "sandboxReceipt"
    }

    static func hasTestFlightProvision(_ provision: String) -> Bool {
        provision.contains("<key>beta-reports-active</key>")
    }

    private static func resolve(bundle: Bundle) async -> String {
        if isDirectDistribution(bundle) {
            print("[WalshMediaAnalytics] env=prod (DISTRIBUTION_CHANNEL=direct)")
            return "prod"
        }

        if let forced = override(fromPlistValue: bundle.object(forInfoDictionaryKey: "ANALYTICS_ENV") as? String)
            ?? override(fromPlistValue: bundle.object(forInfoDictionaryKey: "AIRBOOK_SIGN_IN_TIER") as? String)
        {
            print("[WalshMediaAnalytics] env=\(forced) (plist override)")
            return forced
        }

        #if DEBUG
        print("[WalshMediaAnalytics] env=dev (#if DEBUG)")
        return "dev"
        #else
        let embeddedBeta = isTestFlightProvision(bundle)
        let receiptSandbox = hasSandboxReceipt(url: bundle.appStoreReceiptURL)
        let appTransactionEnv = await readAppTransactionEnvironment()
        let entitlementSandbox = await anyEntitlementUsesSandbox()
        let appTransactionSandbox = appTransactionEnv == .sandbox || appTransactionEnv == .xcode
        let isTestFlight = embeddedBeta || receiptSandbox || appTransactionSandbox || entitlementSandbox

        print(
            "[WalshMediaAnalytics] env detection " +
                "embeddedBeta=\(embeddedBeta) receiptSandbox=\(receiptSandbox) " +
                "appTransaction=\(appTransactionEnv.map { String(describing: $0) } ?? "nil") " +
                "entitlementSandbox=\(entitlementSandbox) → \(isTestFlight ? "testflight" : "prod")"
        )
        return isTestFlight ? "testflight" : "prod"
        #endif
    }

    private static func isDirectDistribution(_ bundle: Bundle) -> Bool {
        guard let raw = bundle.object(forInfoDictionaryKey: "DISTRIBUTION_CHANNEL") as? String else {
            return false
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "direct"
    }

    private static func isTestFlightProvision(_ bundle: Bundle) -> Bool {
        let urls = [
            bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
            bundle.url(forResource: "embedded", withExtension: "provisionprofile"),
        ]
        for url in urls {
            guard let url, let data = try? Data(contentsOf: url),
                  let provision = String(data: data, encoding: .isoLatin1) else {
                continue
            }
            if hasTestFlightProvision(provision) { return true }
        }
        return false
    }

    private static func readAppTransactionEnvironment() async -> StoreKit.AppStore.Environment? {
        if let env = await readVerifiedAppTransactionEnvironment() {
            return env
        }
        do {
            _ = try await AppTransaction.refresh()
        } catch {
            print("[WalshMediaAnalytics] AppTransaction.refresh failed: \(error.localizedDescription)")
        }
        return await readVerifiedAppTransactionEnvironment()
    }

    private static func readVerifiedAppTransactionEnvironment() async -> StoreKit.AppStore.Environment? {
        do {
            let result = try await AppTransaction.shared
            guard case .verified(let appTransaction) = result else {
                print("[WalshMediaAnalytics] AppTransaction.shared unverified")
                return nil
            }
            return appTransaction.environment
        } catch {
            print("[WalshMediaAnalytics] AppTransaction.shared failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func anyEntitlementUsesSandbox() async -> Bool {
        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification else { continue }
            switch transaction.environment {
            case .sandbox, .xcode:
                return true
            default:
                continue
            }
        }
        return false
    }
}
