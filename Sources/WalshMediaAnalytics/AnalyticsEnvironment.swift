import Foundation
import StoreKit
import WalshMediaAnalyticsSec
import os

/// Resolves ingest `env` (`dev` | `testflight` | `prod`) the same way AirBook
/// distinguishes TestFlight from App Store — several signals, any TestFlight hit wins.
public enum AnalyticsEnvironment {
    private static let cache = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Cached after the first *conclusive* resolve so flushes do not re-hit StoreKit.
    public static func current(bundle: Bundle = .main) async -> String {
        if let cached = cache.withLock({ $0 }) {
            return cached
        }
        let (resolved, conclusive) = await resolve(bundle: bundle)
        if conclusive {
            cache.withLock { cache in
                if cache == nil { cache = resolved }
            }
        }
        return cache.withLock({ $0 }) ?? resolved
    }

    /// Last resolved `dev` / `testflight` / `prod`, if `current()` has already run.
    public static func cached() -> String? {
        cache.withLock { $0 }
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

    /// True when this binary is a TestFlight (or TestFlight-equivalent) distribution.
    /// Does not use StoreKit — an App Store subscriber on TestFlight still returns true.
    public static func isTestFlightDistribution(bundle: Bundle = .main) -> Bool {
        hasBetaReportsActiveEntitlement()
            || isTestFlightProvision(bundle)
            || hasSandboxReceiptFile(appStoreReceiptURL: bundle.appStoreReceiptURL)
    }

    static func hasSandboxReceipt(url: URL?) -> Bool {
        url?.lastPathComponent == "sandboxReceipt"
    }

    static func hasSandboxReceiptFile(appStoreReceiptURL: URL?) -> Bool {
        if hasSandboxReceipt(url: appStoreReceiptURL) { return true }
        guard let url = appStoreReceiptURL else { return false }
        let sandbox = url.deletingLastPathComponent().appendingPathComponent("sandboxReceipt")
        return FileManager.default.fileExists(atPath: sandbox.path)
    }

    static func hasTestFlightProvision(_ provision: String) -> Bool {
        provision.contains("<key>beta-reports-active</key>")
    }

    static func hasTestFlightEntitlementValue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func resolve(bundle: Bundle) async -> (String, conclusive: Bool) {
        if isDirectDistribution(bundle) {
            print("[WalshMediaAnalytics] env=prod (DISTRIBUTION_CHANNEL=direct)")
            return ("prod", true)
        }

        if let forced = override(fromPlistValue: bundle.object(forInfoDictionaryKey: "ANALYTICS_ENV") as? String)
            ?? override(fromPlistValue: bundle.object(forInfoDictionaryKey: "AIRBOOK_SIGN_IN_TIER") as? String)
        {
            print("[WalshMediaAnalytics] env=\(forced) (plist override)")
            return (forced, true)
        }

        #if DEBUG
        print("[WalshMediaAnalytics] env=dev (#if DEBUG)")
        return ("dev", true)
        #else
        let betaEntitlement = hasBetaReportsActiveEntitlement()
        let embeddedBeta = isTestFlightProvision(bundle)
        let receiptSandbox = hasSandboxReceiptFile(appStoreReceiptURL: bundle.appStoreReceiptURL)
        let binaryTestFlight = betaEntitlement || embeddedBeta || receiptSandbox
        if binaryTestFlight {
            print(
                "[WalshMediaAnalytics] env=testflight " +
                    "betaEntitlement=\(betaEntitlement) embeddedBeta=\(embeddedBeta) " +
                    "receiptSandbox=\(receiptSandbox)"
            )
            return ("testflight", true)
        }

        let appTransactionEnv = await readAppTransactionEnvironment()
        let entitlementSandbox = await anyEntitlementUsesSandbox()
        let appTransactionSandbox = appTransactionEnv == .sandbox || appTransactionEnv == .xcode
        let isTestFlight = appTransactionSandbox || entitlementSandbox

        print(
            "[WalshMediaAnalytics] env detection " +
                "betaEntitlement=\(betaEntitlement) embeddedBeta=\(embeddedBeta) " +
                "receiptSandbox=\(receiptSandbox) " +
                "appTransaction=\(appTransactionEnv.map { String(describing: $0) } ?? "nil") " +
                "entitlementSandbox=\(entitlementSandbox) → \(isTestFlight ? "testflight" : "prod")"
        )

        if isTestFlight {
            return ("testflight", true)
        }
        // StoreKit failure is not proof of App Store — retry next flush instead of pinning prod.
        let conclusive = appTransactionEnv != nil
        return ("prod", conclusive)
        #endif
    }

    private static func isDirectDistribution(_ bundle: Bundle) -> Bool {
        guard let raw = bundle.object(forInfoDictionaryKey: "DISTRIBUTION_CHANNEL") as? String else {
            return false
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "direct"
    }

    static func hasBetaReportsActiveEntitlement() -> Bool {
        guard let path = Bundle.main.executableURL?.path else { return false }
        return path.withCString { WalshMediaExecutableHasBetaReportsActive($0) }
    }

    private static func isTestFlightProvision(_ bundle: Bundle) -> Bool {
        var urls: [URL] = [
            bundle.bundleURL.appendingPathComponent("embedded.mobileprovision"),
            bundle.bundleURL.appendingPathComponent("embedded.provisionprofile"),
            bundle.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile"),
        ]
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") {
            urls.append(url)
        }
        if let url = bundle.url(forResource: "embedded", withExtension: "provisionprofile") {
            urls.append(url)
        }
        for url in urls {
            guard let data = try? Data(contentsOf: url),
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
