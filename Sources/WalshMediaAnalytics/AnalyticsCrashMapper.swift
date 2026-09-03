import Foundation

/// Flattens MetricKit diagnostic fields into ingest events. MetricKit types stay
/// in the subscriber so this mapper can be unit-tested with fixtures.
public enum AnalyticsCrashMapper {
    public static let maxReasonLength = 512
    public static let maxStackLength = 4096
    public static let maxStackFrames = 48
    public static let maxAppStackLength = 1024
    public static let maxAppStackFrames = 16

    public struct MappedEvent: Equatable, Sendable {
        public var name: String
        public var props: [String: AnalyticsPropValue]
    }

    public struct StackFrame: Equatable, Sendable {
        public var binaryName: String
        public var offset: Int
        public var uuid: String?
    }

    public struct FlattenedStack: Equatable, Sendable {
        public var frames: [StackFrame]
        public var stack: String
        public var stackApp: String?
        public var binaryUUID: String?
        public var truncated: Bool
    }

    public static func crash(
        exceptionType: Int? = nil,
        exceptionCode: Int? = nil,
        signal: Int? = nil,
        reason: String? = nil,
        exceptionMessage: String? = nil,
        version: String? = nil,
        build: String? = nil,
        callStackJSON: Data? = nil,
        appBinaryName: String? = nil
    ) -> MappedEvent {
        makeEvent(
            name: "app_crash",
            exceptionType: exceptionType,
            exceptionCode: exceptionCode,
            signal: signal,
            reason: reason,
            exceptionMessage: exceptionMessage,
            version: version,
            build: build,
            hangMilliseconds: nil,
            callStackJSON: callStackJSON,
            appBinaryName: appBinaryName
        )
    }

    public static func hang(
        hangMilliseconds: Int? = nil,
        version: String? = nil,
        build: String? = nil,
        callStackJSON: Data? = nil,
        appBinaryName: String? = nil
    ) -> MappedEvent {
        makeEvent(
            name: "app_hang",
            exceptionType: nil,
            exceptionCode: nil,
            signal: nil,
            reason: nil,
            exceptionMessage: nil,
            version: version,
            build: build,
            hangMilliseconds: hangMilliseconds,
            callStackJSON: callStackJSON,
            appBinaryName: appBinaryName
        )
    }

    public static func flattenStack(_ json: Data) -> String? {
        flattenStackDetails(json, appBinaryName: nil)?.stack
    }

    public static func flattenStackDetails(
        _ json: Data,
        appBinaryName: String? = nil
    ) -> FlattenedStack? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return nil
        }
        let threads = root["callStacks"] as? [[String: Any]] ?? []
        let attributed = threads.first(where: { ($0["threadAttributed"] as? Bool) == true })
        let thread = attributed ?? threads.first
        let roots = thread?["callStackRootFrames"] as? [[String: Any]] ?? []

        var collected: [StackFrame] = []
        for frame in roots {
            collectFrames(frame, into: &collected)
        }
        // Roots are typically the thread start; the crashing frame is the deepest leaf.
        let ordered = Array(collected.reversed())
        guard !ordered.isEmpty else { return nil }

        let limited = Array(ordered.prefix(maxStackFrames))
        let droppedFrames = limited.count < ordered.count
        let (stack, stackCut) = truncateAtSeparator(
            limited.map(compactFrameLine).joined(separator: "; "),
            maxLength: maxStackLength
        )

        let appName = nonempty(appBinaryName)
        let appFrames = ordered.filter { frame in
            guard let appName else { return false }
            return frame.binaryName.caseInsensitiveCompare(appName) == .orderedSame
        }
        let limitedApp = Array(appFrames.prefix(maxAppStackFrames))
        var stackApp: String?
        var appCut = limitedApp.count < appFrames.count
        if !limitedApp.isEmpty {
            let joined = limitedApp.map(appFrameLine).joined(separator: "; ")
            let truncatedApp = truncateAtSeparator(joined, maxLength: maxAppStackLength)
            stackApp = truncatedApp.value
            appCut = appCut || truncatedApp.truncated
        }

        return FlattenedStack(
            frames: limited,
            stack: stack,
            stackApp: stackApp,
            binaryUUID: appFrames.first?.uuid ?? limited.first(where: { $0.uuid != nil })?.uuid,
            truncated: droppedFrames || stackCut || appCut
        )
    }

    public static func exceptionName(for type: Int) -> String? {
        switch type {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 4: return "EXC_EMULATION"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT"
        case 7: return "EXC_SYSCALL"
        case 8: return "EXC_MACH_SYSCALL"
        case 9: return "EXC_RPC_ALERT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        default: return nil
        }
    }

    public static func signalName(for signal: Int) -> String? {
        switch signal {
        case 1: return "SIGHUP"
        case 2: return "SIGINT"
        case 3: return "SIGQUIT"
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 7: return "SIGEMT"
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 12: return "SIGSYS"
        case 13: return "SIGPIPE"
        case 14: return "SIGALRM"
        case 15: return "SIGTERM"
        default: return nil
        }
    }

    private static func makeEvent(
        name: String,
        exceptionType: Int?,
        exceptionCode: Int?,
        signal: Int?,
        reason: String?,
        exceptionMessage: String?,
        version: String?,
        build: String?,
        hangMilliseconds: Int?,
        callStackJSON: Data?,
        appBinaryName: String?
    ) -> MappedEvent {
        var props: [String: AnalyticsPropValue] = [:]
        if let exceptionType {
            props["exception_type"] = .int(exceptionType)
            if let label = exceptionName(for: exceptionType) {
                props["exception_name"] = .string(label)
            }
        }
        if let exceptionCode {
            props["exception_code"] = .int(exceptionCode)
        }
        if let signal {
            props["signal"] = .int(signal)
            if let label = signalName(for: signal) {
                props["signal_name"] = .string(label)
            }
        }
        let resolvedReason = nonempty(reason) ?? nonempty(exceptionMessage)
        if let resolvedReason {
            props["reason"] = .string(truncate(resolvedReason, maxLength: maxReasonLength))
        }
        if let exceptionMessage = nonempty(exceptionMessage) {
            props["exception_message"] = .string(truncate(exceptionMessage, maxLength: maxReasonLength))
        }
        if let version = nonempty(version) {
            props["version"] = .string(version)
        }
        if let build = nonempty(build) {
            props["build"] = .string(build)
        }
        if let hangMilliseconds {
            props["hang_ms"] = .int(hangMilliseconds)
        }
        if let callStackJSON, let flattened = flattenStackDetails(callStackJSON, appBinaryName: appBinaryName) {
            if !flattened.stack.isEmpty {
                props["stack"] = .string(flattened.stack)
            }
            if let stackApp = flattened.stackApp, !stackApp.isEmpty {
                props["stack_app"] = .string(stackApp)
            }
            if let uuid = flattened.binaryUUID, !uuid.isEmpty {
                props["binary_uuid"] = .string(uuid)
            }
            props["stack_truncated"] = .bool(flattened.truncated)
        }
        return MappedEvent(name: name, props: props)
    }

    private static func collectFrames(_ frame: [String: Any], into result: inout [StackFrame]) {
        if let parsed = parseFrame(frame) {
            result.append(parsed)
        }
        let children = frame["subFrames"] as? [[String: Any]] ?? []
        for child in children {
            collectFrames(child, into: &result)
        }
    }

    private static func parseFrame(_ frame: [String: Any]) -> StackFrame? {
        guard let name = nonempty(frame["binaryName"] as? String) else { return nil }
        let offset = intValue(frame["offsetIntoBinaryTextSegment"]) ?? 0
        let uuid = nonempty(frame["binaryUUID"] as? String)
            ?? nonempty(frame["binaryUuid"] as? String)
        return StackFrame(binaryName: name, offset: offset, uuid: uuid)
    }

    private static func compactFrameLine(_ frame: StackFrame) -> String {
        "\(frame.binaryName)+0x\(String(frame.offset, radix: 16))"
    }

    private static func appFrameLine(_ frame: StackFrame) -> String {
        let base = compactFrameLine(frame)
        guard let uuid = frame.uuid, !uuid.isEmpty else { return base }
        return "\(base)@\(uuid)"
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

    private static func truncateAtSeparator(
        _ value: String,
        maxLength: Int,
        separator: String = "; "
    ) -> (value: String, truncated: Bool) {
        guard value.count > maxLength else { return (value, false) }
        let prefix = String(value.prefix(maxLength))
        if let range = prefix.range(of: separator, options: .backwards) {
            return (String(prefix[..<range.lowerBound]), true)
        }
        return (prefix, true)
    }
}
