import Foundation

/// Drop-in signed ingest client. Configure once at launch, then `track` events.
///
/// ```swift
/// Analytics.start(.fromInfoPlist())
/// Analytics.track("button_tapped", ["screen": "home"])
/// try await AnalyticsHTTP.data(for: request, endpoint: "api.login")
/// ```
public enum Analytics {
    public static func start(_ configuration: AnalyticsConfiguration) {
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
