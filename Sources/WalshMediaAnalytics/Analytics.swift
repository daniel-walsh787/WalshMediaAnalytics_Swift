import Foundation

/// Drop-in signed ingest client. Configure once at launch, then `track` events.
///
/// ```swift
/// Analytics.start(.fromInfoPlist())
/// try await Analytics.OTA.sync()
/// Analytics.track("button_tapped", ["screen": "home"])
/// try await AnalyticsHTTP.data(for: request, endpoint: "api.login")
/// ```
enum AnalyticsRuntime {
    private static let lock = NSLock()
    private static var stored: AnalyticsConfiguration?
    private static var storedEnvironment: String?

    static func setConfiguration(_ configuration: AnalyticsConfiguration) {
        lock.lock()
        stored = configuration
        lock.unlock()
    }

    static func configuration() -> AnalyticsConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    static func setEnvironment(_ environment: String) {
        let normalized = AnalyticsEnvironment.ingestValue(fromSignInTier: environment)
        lock.lock()
        storedEnvironment = normalized
        lock.unlock()
    }

    static func environment() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedEnvironment
    }

    static func resetForTests() {
        lock.lock()
        stored = nil
        storedEnvironment = nil
        lock.unlock()
        AnalyticsOTAMemory.resetForTests()
    }
}

public enum Analytics {
    public static func start(_ configuration: AnalyticsConfiguration) {
        AnalyticsRuntime.setConfiguration(configuration)
        AnalyticsOTAMemory.preload(appId: configuration.appId)
        Task {
            let env = await configuration.environment()
            AnalyticsRuntime.setEnvironment(env)
        }
        Task { @MainActor in
            AnalyticsClient.shared.start(configuration)
        }
    }

    public static func track(_ name: String, _ props: [String: AnalyticsPropValue] = [:]) {
        Task { @MainActor in
            AnalyticsClient.shared.track(name: name, props: props)
        }
    }

    public static func flushNow() {
        Task { @MainActor in
            AnalyticsClient.shared.flushNow()
        }
    }
}
