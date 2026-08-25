import Foundation

/// Flattens MetricKit diagnostic fields into ingest events. MetricKit types stay
/// in the subscriber so this mapper can be unit-tested with fixtures.
public enum AnalyticsCrashMapper {
    public static let maxReasonLength = 256
    public static let maxStackLength = 1536
    public static let maxStackFrames = 24

    public struct MappedEvent: Equatable, Sendable {
        public var name: String
        public var props: [String: AnalyticsPropValue]
    }

    public static func crash(
        exceptionType: Int? = nil,
        exceptionCode: Int? = nil,
        signal: Int? = nil,
        reason: String? = nil,
        version: String? = nil,
        callStackJSON: Data? = nil
    ) -> MappedEvent {
        makeEvent(
            name: "app_crash",
            exceptionType: exceptionType,
            exceptionCode: exceptionCode,
            signal: signal,
            reason: reason,
            version: version,
            hangMilliseconds: nil,
            callStackJSON: callStackJSON
        )
    }

    public static func hang(
        hangMilliseconds: Int? = nil,
        version: String? = nil,
        callStackJSON: Data? = nil
    ) -> MappedEvent {
        makeEvent(
            name: "app_hang",
            exceptionType: nil,
            exceptionCode: nil,
            signal: nil,
            reason: nil,
            version: version,
            hangMilliseconds: hangMilliseconds,
            callStackJSON: callStackJSON
        )
    }

    public static func flattenStack(_ json: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return nil
        }
        let threads = root["callStacks"] as? [[String: Any]] ?? []
        let attributed = threads.first(where: { ($0["threadAttributed"] as? Bool) == true })
        let thread = attributed ?? threads.first
        let roots = thread?["callStackRootFrames"] as? [[String: Any]] ?? []

        var frames: [String] = []
        for frame in roots {
            collectFrames(frame, into: &frames)
        }
        // Roots are typically the thread start; the crashing frame is the deepest leaf.
        let ordered = Array(frames.reversed().prefix(maxStackFrames))
        guard !ordered.isEmpty else { return nil }
        return truncate(ordered.joined(separator: "; "), maxLength: maxStackLength)
    }

    private static func makeEvent(
        name: String,
        exceptionType: Int?,
        exceptionCode: Int?,
        signal: Int?,
        reason: String?,
        version: String?,
        hangMilliseconds: Int?,
        callStackJSON: Data?
    ) -> MappedEvent {
        var props: [String: AnalyticsPropValue] = [:]
        if let exceptionType {
            props["exception_type"] = .int(exceptionType)
        }
        if let exceptionCode {
            props["exception_code"] = .int(exceptionCode)
        }
        if let signal {
            props["signal"] = .int(signal)
        }
        if let reason = nonempty(reason) {
            props["reason"] = .string(truncate(reason, maxLength: maxReasonLength))
        }
        if let version = nonempty(version) {
            props["version"] = .string(version)
        }
        if let hangMilliseconds {
            props["hang_ms"] = .int(hangMilliseconds)
        }
        if let callStackJSON, let stack = flattenStack(callStackJSON), !stack.isEmpty {
            props["stack"] = .string(stack)
        }
        return MappedEvent(name: name, props: props)
    }

    private static func collectFrames(_ frame: [String: Any], into result: inout [String]) {
        if let line = frameLine(frame) {
            result.append(line)
        }
        let children = frame["subFrames"] as? [[String: Any]] ?? []
        for child in children {
            collectFrames(child, into: &result)
        }
    }

    private static func frameLine(_ frame: [String: Any]) -> String? {
        guard let name = nonempty(frame["binaryName"] as? String) else { return nil }
        let offset = intValue(frame["offsetIntoBinaryTextSegment"]) ?? 0
        return "\(name)+0x\(String(offset, radix: 16))"
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        return nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength))
    }
}
