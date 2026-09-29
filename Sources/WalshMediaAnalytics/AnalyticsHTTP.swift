import Foundation

/// Application-level outcome for an HTTP call, independent of the HTTP status code.
/// Use this when a 2xx body can still mean failure (`{"status":"error"}`).
public enum AnalyticsHTTPAppResult: String, Sendable {
    case success
    case error

    /// Reads a JSON object's `status` (or `ok` / `success`) when present.
    public static func fromJSONStatus(_ data: Data) -> AnalyticsHTTPAppResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let status = object["status"] as? String {
            switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "ok", "success", "succeeded":
                return .success
            case "error", "fail", "failed", "failure":
                return .error
            default:
                break
            }
        }
        if let ok = object["ok"] as? Bool {
            return ok ? .success : .error
        }
        if let success = object["success"] as? Bool {
            return success ? .success : .error
        }
        return nil
    }
}

/// Shared `http_call` event helpers. Host apps should not invent their own prop keys.
public enum AnalyticsHTTP {
    public static let eventName = "http_call"

    public enum Prop {
        public static let endpoint = "endpoint"
        public static let statusCode = "http_status"
        public static let durationMs = "duration_ms"
        public static let timedOut = "timed_out"
        public static let appResult = "app_result"
        public static let timeoutReason = "timeout_reason"
        public static let urlErrorCode = "url_error_code"
    }

    /// Default `timeout_reason` when `timed_out` is true and the host did not supply one.
    public static let defaultTimeoutReason = "url_timeout"

    public static func isTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    /// `URLError.code.rawValue` when the failure is a `URLError` / `NSURLErrorDomain`.
    public static func urlErrorCode(from error: Error) -> Int? {
        if let urlError = error as? URLError {
            return urlError.code.rawValue
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code
        }
        return nil
    }

    /// Runs a `URLSession.data` request and emits `http_call`.
    @discardableResult
    public static func data(
        for request: URLRequest,
        endpoint: String,
        session: URLSession = .shared,
        logOnlyOnError: Bool = false,
        extra: [String: AnalyticsPropValue] = [:],
        appResult: ((Data, HTTPURLResponse) -> AnalyticsHTTPAppResult?)? = nil
    ) async throws -> (Data, URLResponse) {
        try await measure(
            endpoint: endpoint,
            logOnlyOnError: logOnlyOnError,
            extra: extra,
            appResult: appResult
        ) {
            try await session.data(for: request)
        }
    }

    /// Runs a `URLSession.data(from:)` request and emits `http_call`.
    @discardableResult
    public static func data(
        from url: URL,
        endpoint: String,
        session: URLSession = .shared,
        logOnlyOnError: Bool = false,
        extra: [String: AnalyticsPropValue] = [:],
        appResult: ((Data, HTTPURLResponse) -> AnalyticsHTTPAppResult?)? = nil
    ) async throws -> (Data, URLResponse) {
        try await measure(
            endpoint: endpoint,
            logOnlyOnError: logOnlyOnError,
            extra: extra,
            appResult: appResult
        ) {
            try await session.data(from: url)
        }
    }

    /// Times `work`, classifies timeouts, and emits `http_call`.
    /// Set `logOnlyOnError` for high-volume assets (images) so 2xx successes are skipped.
    @discardableResult
    public static func measure(
        endpoint: String,
        logOnlyOnError: Bool = false,
        extra: [String: AnalyticsPropValue] = [:],
        appResult: ((Data, HTTPURLResponse) -> AnalyticsHTTPAppResult?)? = nil,
        work: () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        let clock = Stopwatch(logOnlyOnError: logOnlyOnError)
        do {
            let (data, response) = try await work()
            let http = response as? HTTPURLResponse
            clock.track(
                endpoint: endpoint,
                statusCode: http?.statusCode,
                timedOut: false,
                appResult: http.flatMap { appResult?(data, $0) },
                extra: extra
            )
            return (data, response)
        } catch {
            clock.track(endpoint: endpoint, error: error, extra: extra)
            throw error
        }
    }

    /// When `logOnlyOnError` is set, keep timeouts, transport failures, non-2xx statuses, and `app_result=error`.
    static func shouldLog(
        logOnlyOnError: Bool,
        statusCode: Int?,
        timedOut: Bool,
        appResult: AnalyticsHTTPAppResult?
    ) -> Bool {
        if !logOnlyOnError { return true }
        if timedOut { return true }
        if appResult == .error { return true }
        if let statusCode, !(200...299).contains(statusCode) { return true }
        return false
    }

    static func makeProps(
        endpoint: String,
        statusCode: Int?,
        durationMs: Int?,
        timedOut: Bool,
        appResult: AnalyticsHTTPAppResult?,
        timeoutReason: String? = nil,
        urlErrorCode: Int? = nil,
        extra: [String: AnalyticsPropValue]
    ) -> [String: AnalyticsPropValue] {
        var props = extra
        props[Prop.endpoint] = nil
        props[Prop.statusCode] = nil
        props[Prop.durationMs] = nil
        props[Prop.timedOut] = nil
        props[Prop.appResult] = nil
        props[Prop.timeoutReason] = nil
        props[Prop.urlErrorCode] = nil

        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            props[Prop.endpoint] = .string(String(trimmed.prefix(128)))
        }
        if let statusCode {
            props[Prop.statusCode] = .int(statusCode)
        }
        if let durationMs, durationMs >= 0 {
            props[Prop.durationMs] = .int(durationMs)
        }
        props[Prop.timedOut] = .bool(timedOut)
        if let appResult {
            props[Prop.appResult] = .string(appResult.rawValue)
        }
        if let timeoutReason {
            let reason = timeoutReason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty {
                props[Prop.timeoutReason] = .string(String(reason.prefix(64)))
            }
        }
        if let urlErrorCode {
            props[Prop.urlErrorCode] = .int(urlErrorCode)
        }
        return props
    }

    /// Prefer host-supplied `timeout_reason` / `url_error_code` in `extra`; otherwise fill from timeout / error.
    static func resolveHangProps(
        timedOut: Bool,
        error: Error?,
        extra: [String: AnalyticsPropValue]
    ) -> (timeoutReason: String?, urlErrorCode: Int?) {
        let timeoutReason: String?
        if case .string(let reason) = extra[Prop.timeoutReason] {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            timeoutReason = trimmed.isEmpty ? nil : trimmed
        } else if timedOut {
            timeoutReason = defaultTimeoutReason
        } else {
            timeoutReason = nil
        }

        let urlErrorCode: Int?
        if case .int(let code) = extra[Prop.urlErrorCode] {
            urlErrorCode = code
        } else if let error {
            urlErrorCode = Self.urlErrorCode(from: error)
        } else {
            urlErrorCode = nil
        }

        return (timeoutReason, urlErrorCode)
    }

    /// Call `track` once when an HTTP (or HTTP-like) operation finishes.
    public struct Stopwatch: Sendable {
        private let start: Date
        private let logOnlyOnError: Bool

        public init(logOnlyOnError: Bool = false) {
            start = Date()
            self.logOnlyOnError = logOnlyOnError
        }

        public var durationMs: Int {
            max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
        }

        public func track(
            endpoint: String,
            statusCode: Int? = nil,
            timedOut: Bool = false,
            appResult: AnalyticsHTTPAppResult? = nil,
            extra: [String: AnalyticsPropValue] = [:],
            logOnlyOnError: Bool? = nil
        ) {
            let hang = AnalyticsHTTP.resolveHangProps(timedOut: timedOut, error: nil, extra: extra)
            Analytics.trackHTTP(
                endpoint: endpoint,
                statusCode: statusCode,
                durationMs: durationMs,
                timedOut: timedOut,
                appResult: appResult,
                timeoutReason: hang.timeoutReason,
                urlErrorCode: hang.urlErrorCode,
                extra: extra,
                logOnlyOnError: logOnlyOnError ?? self.logOnlyOnError
            )
        }

        public func track(
            endpoint: String,
            error: Error,
            timedOut: Bool? = nil,
            appResult: AnalyticsHTTPAppResult? = .error,
            extra: [String: AnalyticsPropValue] = [:],
            logOnlyOnError: Bool? = nil
        ) {
            let resolvedTimedOut = timedOut ?? AnalyticsHTTP.isTimeout(error)
            let hang = AnalyticsHTTP.resolveHangProps(timedOut: resolvedTimedOut, error: error, extra: extra)
            Analytics.trackHTTP(
                endpoint: endpoint,
                statusCode: nil,
                durationMs: durationMs,
                timedOut: resolvedTimedOut,
                appResult: appResult,
                timeoutReason: hang.timeoutReason,
                urlErrorCode: hang.urlErrorCode,
                extra: extra,
                logOnlyOnError: logOnlyOnError ?? self.logOnlyOnError
            )
        }
    }
}

extension Analytics {
    /// Emits a shared `http_call` event. Always includes `duration_ms` when known.
    /// Pass `logOnlyOnError: true` for noisy endpoints (images) so only failures are stored.
    public static func trackHTTP(
        endpoint: String,
        statusCode: Int? = nil,
        durationMs: Int? = nil,
        timedOut: Bool = false,
        appResult: AnalyticsHTTPAppResult? = nil,
        timeoutReason: String? = nil,
        urlErrorCode: Int? = nil,
        extra: [String: AnalyticsPropValue] = [:],
        logOnlyOnError: Bool = false
    ) {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard AnalyticsHTTP.shouldLog(
            logOnlyOnError: logOnlyOnError,
            statusCode: statusCode,
            timedOut: timedOut,
            appResult: appResult
        ) else { return }
        track(
            AnalyticsHTTP.eventName,
            AnalyticsHTTP.makeProps(
                endpoint: trimmed,
                statusCode: statusCode,
                durationMs: durationMs,
                timedOut: timedOut,
                appResult: appResult,
                timeoutReason: timeoutReason,
                urlErrorCode: urlErrorCode,
                extra: extra
            )
        )
    }
}
