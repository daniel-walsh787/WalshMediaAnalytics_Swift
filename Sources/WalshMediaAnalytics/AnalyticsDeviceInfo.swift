import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Hardware + OS snapshot captured once per `Analytics.start` and attached to every event.
struct AnalyticsDeviceInfo: Equatable, Sendable {
    var deviceModel: String
    var device: String
    var osName: String
    var osVersion: String

    var deviceLabel: String {
        "\(device) \(osName) \(osVersion)"
    }

    var props: [String: AnalyticsPropValue] {
        [
            "device_model": .string(deviceModel),
            "device": .string(device),
            "os_name": .string(osName),
            "os_version": .string(osVersion),
            "device_label": .string(deviceLabel),
        ]
    }

    static func current(bundle: Bundle = .main) -> AnalyticsDeviceInfo {
        let model = hardwareIdentifier()
        let marketing = AnalyticsDeviceNames.marketingName(for: model)
        return AnalyticsDeviceInfo(
            deviceModel: model,
            device: marketing ?? model,
            osName: operatingSystemName(),
            osVersion: operatingSystemVersionString()
        )
    }

    static func appBinaryName(bundle: Bundle = .main) -> String? {
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let name = bundle.executableURL?.deletingPathExtension().lastPathComponent {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func hardwareIdentifier() -> String {
        if let simulator = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !simulator.isEmpty {
            return simulator
        }
        #if os(macOS)
        if let model = sysctlString("hw.model"), !model.isEmpty {
            return model
        }
        #endif
        return utsnameMachine()
    }

    private static func operatingSystemName() -> String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        #if canImport(UIKit)
        let name = UIDevice.current.systemName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        #endif
        return "iOS"
        #else
        return "unknown"
        #endif
    }

    private static func operatingSystemVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion > 0 {
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    private static func utsnameMachine() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { cString in
                String(cString: cString)
            }
        }
    }

    #if os(macOS)
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
    #endif
}

/// Best-effort marketing names. Unknown identifiers keep the hardware string.
enum AnalyticsDeviceNames {
    static func marketingName(for identifier: String) -> String? {
        names[identifier]
    }

    private static let names: [String: String] = [
        // iPhone
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        // iPad Air
        "iPad13,16": "iPad Air (5th generation)",
        "iPad13,17": "iPad Air (5th generation)",
        "iPad14,8": "iPad Air 11-inch (M2)",
        "iPad14,9": "iPad Air 11-inch (M2)",
        "iPad14,10": "iPad Air 13-inch (M2)",
        "iPad14,11": "iPad Air 13-inch (M2)",
        "iPad15,3": "iPad Air 11-inch (M3)",
        "iPad15,4": "iPad Air 11-inch (M3)",
        "iPad15,5": "iPad Air 13-inch (M3)",
        "iPad15,6": "iPad Air 13-inch (M3)",
        // iPad Pro M4
        "iPad16,3": "iPad Pro 11-inch (M4)",
        "iPad16,4": "iPad Pro 11-inch (M4)",
        "iPad16,5": "iPad Pro 13-inch (M4)",
        "iPad16,6": "iPad Pro 13-inch (M4)",
        // iPad mini
        "iPad14,1": "iPad mini (6th generation)",
        "iPad14,2": "iPad mini (6th generation)",
        "iPad16,1": "iPad mini (A17 Pro)",
        "iPad16,2": "iPad mini (A17 Pro)",
    ]
}
