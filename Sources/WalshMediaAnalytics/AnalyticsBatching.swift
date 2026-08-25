import Foundation

enum AnalyticsBatching {
    static let maxEvents = 100
    static let maxBodyBytes = 256 * 1024

    /// Next smaller event count when the encoded batch exceeds the ingest body cap.
    /// `nil` means a single event is still too large and should be dropped.
    static func reducedCount(current: Int, bodyBytes: Int, maxBytes: Int = maxBodyBytes) -> Int? {
        guard bodyBytes > maxBytes else { return current }
        guard current > 1 else { return nil }
        return max(1, current / 2)
    }
}
