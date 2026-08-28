import Foundation
import os

/// JSON value for an OTA feature flag. Dashboard values are JSON (`true`, `42`, `"text"`, objects).
public enum AnalyticsOTAValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnalyticsOTAValue])
    case object([String: AnalyticsOTAValue])

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value) where value.rounded(.towardZero) == value:
            return Int(value)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Coerces common dashboard shapes into an on/off switch.
    public var isEnabled: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .int(let value):
            return value != 0
        case .double(let value):
            return value != 0
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1", "on":
                return true
            case "false", "no", "0", "off":
                return false
            default:
                return nil
            }
        case .object(let object):
            return object["enabled"]?.isEnabled
        default:
            return nil
        }
    }
}

public struct AnalyticsOTAFlags: Sendable, Equatable {
    public static let empty = AnalyticsOTAFlags(values: [:])

    public var values: [String: AnalyticsOTAValue]

    public init(values: [String: AnalyticsOTAValue] = [:]) {
        self.values = values
    }

    public subscript(_ key: String) -> AnalyticsOTAValue? {
        values[key]
    }

    public func bool(_ key: String) -> Bool? { values[key]?.boolValue }
    public func int(_ key: String) -> Int? { values[key]?.intValue }
    public func double(_ key: String) -> Double? { values[key]?.doubleValue }
    public func string(_ key: String) -> String? { values[key]?.stringValue }

    public func isEnabled(_ key: String, default fallback: Bool = false) -> Bool {
        values[key]?.isEnabled ?? fallback
    }

    /// JSON object / array flags, re-encoded. `nil` when the key is missing or a scalar.
    public func json(_ key: String) -> Data? {
        guard let value = values[key] else { return nil }
        switch value {
        case .array, .object:
            return try? AnalyticsOTACodec.jsonEncoder().encode(value)
        default:
            return nil
        }
    }
}

public struct AnalyticsOTAFile: Sendable, Equatable {
    public var path: String
    public var etag: String
    public var url: URL
    public var isProtected: Bool
    public var contentType: String?
    public var size: Int?

    public init(
        path: String,
        etag: String,
        url: URL,
        isProtected: Bool,
        contentType: String? = nil,
        size: Int? = nil
    ) {
        self.path = path
        self.etag = etag
        self.url = url
        self.isProtected = isProtected
        self.contentType = contentType
        self.size = size
    }
}

public struct AnalyticsOTASnapshot: Sendable, Equatable {
    public var tenantSlug: String?
    public var flags: AnalyticsOTAFlags
    public var files: [AnalyticsOTAFile]
    public var manifestEtag: String?
    public var flagsEtag: String?
    /// `true` when the worker returned 304 and the local snapshot was reused.
    public var notModified: Bool

    public init(
        tenantSlug: String? = nil,
        flags: AnalyticsOTAFlags = .empty,
        files: [AnalyticsOTAFile] = [],
        manifestEtag: String? = nil,
        flagsEtag: String? = nil,
        notModified: Bool = false
    ) {
        self.tenantSlug = tenantSlug
        self.flags = flags
        self.files = files
        self.manifestEtag = manifestEtag
        self.flagsEtag = flagsEtag
        self.notModified = notModified
    }

    public func file(at path: String) -> AnalyticsOTAFile? {
        let normalized = AnalyticsOTACodec.normalizedFilePath(path)
        return files.first { $0.path == normalized }
    }
}

public struct AnalyticsOTACachedFile: Sendable, Equatable {
    public var path: String
    public var etag: String
    public var localURL: URL
    public var data: Data
    public var contentType: String?
    public var notModified: Bool
}

public enum AnalyticsOTAError: Error, Equatable, LocalizedError {
    case notConfigured
    case invalidPath(String)
    case fileNotInManifest(String)
    case unauthorized
    case quotaExceeded
    case notFound
    case invalidResponse
    case httpStatus(Int, message: String?)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Analytics OTA is not configured (missing app id or HMAC secret)."
        case .invalidPath(let path):
            return "Invalid OTA file path: \(path)"
        case .fileNotInManifest(let path):
            return "OTA file is not in the manifest: \(path)"
        case .unauthorized:
            return "OTA request was rejected (401/403). Check ANALYTICS_APPNAME and ANALYTICS_HMAC_SECRET."
        case .quotaExceeded:
            return "OTA quota exceeded (402). Pause config reads until credits are available."
        case .notFound:
            return "OTA resource was not found (404)."
        case .invalidResponse:
            return "OTA response could not be parsed."
        case .httpStatus(let code, let message):
            if let message, !message.isEmpty {
                return "OTA HTTP \(code): \(message)"
            }
            return "OTA HTTP \(code)"
        case .transport(let message):
            return "OTA transport error: \(message)"
        }
    }
}

enum AnalyticsOTAMemory {
    private static let flags = OSAllocatedUnfairLock(initialState: AnalyticsOTAFlags.empty)
    private static let snapshot = OSAllocatedUnfairLock<AnalyticsOTASnapshot?>(initialState: nil)

    static func preload(appId: String, defaults: UserDefaults = .standard) {
        let store = AnalyticsOTADiskStore(appId: appId, defaults: defaults)
        guard let snapshot = store.loadSnapshot() else { return }
        publish(snapshot)
    }

    static func publish(_ snapshot: AnalyticsOTASnapshot) {
        flags.withLock { $0 = snapshot.flags }
        self.snapshot.withLock { $0 = snapshot }
    }

    static func currentFlags() -> AnalyticsOTAFlags {
        flags.withLock { $0 }
    }

    static func currentSnapshot() -> AnalyticsOTASnapshot? {
        snapshot.withLock { $0 }
    }

    static func resetForTests() {
        flags.withLock { $0 = .empty }
        snapshot.withLock { $0 = nil }
    }
}

extension Analytics {
    /// OTA feature flags and files. Uses the same `ANALYTICS_APPNAME` + HMAC secret as ingest.
    ///
    /// ```swift
    /// Analytics.start(.fromInfoPlist())
    /// try await Analytics.OTA.sync()
    /// if Analytics.OTA.isEnabled("new_onboarding") { … }
    /// let csv = try await Analytics.OTA.data(for: "airlines.csv")
    /// ```
    public enum OTA {
        /// Last flags from disk / the most recent successful sync. Available before `sync()` finishes.
        public static var flags: AnalyticsOTAFlags {
            AnalyticsOTAMemory.currentFlags()
        }

        public static var snapshot: AnalyticsOTASnapshot? {
            AnalyticsOTAMemory.currentSnapshot()
        }

        public static func isEnabled(_ key: String, default fallback: Bool = false) -> Bool {
            flags.isEnabled(key, default: fallback)
        }

        public static func bool(_ key: String) -> Bool? { flags.bool(key) }
        public static func int(_ key: String) -> Int? { flags.int(key) }
        public static func double(_ key: String) -> Double? { flags.double(key) }
        public static func string(_ key: String) -> String? { flags.string(key) }
        public static func json(_ key: String) -> Data? { flags.json(key) }

        /// HMAC-signed manifest, then download only files whose etag changed (`If-None-Match` / 304).
        @discardableResult
        public static func sync(
            using configuration: AnalyticsConfiguration? = nil,
            downloadFiles: Bool = true
        ) async throws -> AnalyticsOTASnapshot {
            try await AnalyticsOTAClient.shared.sync(
                configuration: resolved(configuration),
                downloadFiles: downloadFiles
            )
        }

        /// Lightweight flags-only GET. Does not touch cached files.
        @discardableResult
        public static func refreshFlags(
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> AnalyticsOTAFlags {
            try await AnalyticsOTAClient.shared.refreshFlags(configuration: resolved(configuration))
        }

        public static func cachedFileURL(for path: String) -> URL? {
            guard let configuration = AnalyticsRuntime.configuration() else { return nil }
            return AnalyticsOTADiskStore(appId: configuration.appId).fileURL(for: path)
        }

        public static func cachedFile(for path: String) -> AnalyticsOTACachedFile? {
            guard let configuration = AnalyticsRuntime.configuration() else { return nil }
            return AnalyticsOTADiskStore(appId: configuration.appId).cachedFile(for: path)
        }

        /// Returns cached bytes when the manifest etag matches; otherwise downloads with `If-None-Match`.
        public static func data(
            for path: String,
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> Data {
            try await file(for: path, using: configuration).data
        }

        @discardableResult
        public static func file(
            for path: String,
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> AnalyticsOTACachedFile {
            try await AnalyticsOTAClient.shared.file(for: path, configuration: resolved(configuration))
        }

        private static func resolved(_ configuration: AnalyticsConfiguration?) throws -> AnalyticsConfiguration {
            if let configuration { return configuration }
            if let stored = AnalyticsRuntime.configuration() { return stored }
            throw AnalyticsOTAError.notConfigured
        }
    }
}
