import Foundation

/// Process-lifetime session id plus device/OS props merged into every tracked event.
enum AnalyticsSession {
    private static let lock = NSLock()
    private static var sessionID: String?
    private static var device: AnalyticsDeviceInfo?

    static func beginIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if sessionID == nil {
            sessionID = UUID().uuidString.lowercased()
        }
        if device == nil {
            device = AnalyticsDeviceInfo.current()
        }
    }

    static func currentID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    /// Fills `session_id` / device fields. Caller keys win when both set the same name.
    static func enrich(_ props: [String: AnalyticsPropValue]) -> [String: AnalyticsPropValue] {
        beginIfNeeded()
        lock.lock()
        let id = sessionID
        let info = device
        lock.unlock()

        var merged: [String: AnalyticsPropValue] = [:]
        if let id {
            merged["session_id"] = .string(id)
        }
        if let info {
            for (key, value) in info.props {
                merged[key] = value
            }
        }
        for (key, value) in props {
            merged[key] = value
        }
        return merged
    }

    static func resetForTests() {
        lock.lock()
        sessionID = nil
        device = nil
        lock.unlock()
    }
}
