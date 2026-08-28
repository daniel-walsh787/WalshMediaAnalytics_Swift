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

    /// On/off from a scalar: `true`/`false`, `enabled`/`disabled`, `yes`/`no`, `on`/`off`.
    /// Objects are not interpreted here — use `environmentToggles` or `flag(_:)`.
    public var onOffValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .int(let value):
            return value != 0
        case .double(let value):
            return value != 0
        case .string(let value):
            return Self.parseOnOff(value)
        default:
            return nil
        }
    }

    /// `isEnabled`-style payload: a scalar on/off, or `{ "enabled": … }`.
    public var isEnabled: Bool? {
        if let onOff = onOffValue { return onOff }
        guard case .object(let object) = self else { return nil }
        if let nested = object["enabled"] {
            return nested.onOffValue
        }
        return nil
    }

    /// Exact per-channel payload `{ "dev": …, "testflight": …, "prod": … }` whose values
    /// are on/off tokens. Returns `nil` when the object has any other shape.
    public var environmentToggles: [String: Bool]? {
        guard case .object(let object) = self else { return nil }
        guard Set(object.keys) == Self.environmentFlagKeys else { return nil }
        var map: [String: Bool] = [:]
        for key in Self.environmentFlagKeys {
            guard let enabled = object[key]?.onOffValue else { return nil }
            map[key] = enabled
        }
        return map
    }

    static let environmentFlagKeys: Set<String> = ["dev", "testflight", "prod"]

    static func parseOnOff(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "enabled", "yes", "on", "1":
            return true
        case "false", "disabled", "no", "off", "0":
            return false
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

    /// Raw JSON value for any flag (string, number, object, …). Prefer this unless the
    /// flag is known to be an on/off switch.
    public func flag(_ key: String) -> AnalyticsOTAValue? { values[key] }

    /// On/off flags only. Accepts a single token (`true` / `enabled` / `yes` / `on`
    /// and the false counterparts) or exactly `{ "dev": …, "testflight": …, "prod": … }`.
    /// Other JSON (themes, limits, payloads) should use `flag(_:)`.
    public func isEnabled(_ key: String, default fallback: Bool = false, environment: String? = nil) -> Bool {
        guard let value = values[key] else { return fallback }
        if let map = value.environmentToggles {
            guard let env = resolvedEnvironment(environment) else { return fallback }
            return map[env] ?? fallback
        }
        return value.isEnabled ?? fallback
    }

    private func resolvedEnvironment(_ explicit: String?) -> String? {
        let raw = explicit
            ?? AnalyticsRuntime.environment()
            ?? AnalyticsEnvironment.cached()
        guard let raw else { return nil }
        return AnalyticsEnvironment.ingestValue(fromSignInTier: raw)
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
    public var persist: AnalyticsOTAPersist
}

/// Which OTA files `sync` should download now. Assets can stay lazy via `data(for:)`.
public enum AnalyticsOTADownloadFiles: Sendable {
    /// Every file in the manifest (default).
    case all
    /// Manifest and flags only. Does not fetch file bytes.
    case none
    /// Eager-cache matching paths; leave the rest for `data(for:)` / `file(for:)`.
    case matching(@Sendable (String) -> Bool)

    func shouldDownload(_ path: String) -> Bool {
        switch self {
        case .all:
            return true
        case .none:
            return false
        case .matching(let predicate):
            return predicate(path)
        }
    }
}

/// Where file bytes are stored. Feature flags and the manifest snapshot stay in UserDefaults.
public enum AnalyticsOTAPersist: Sendable, Equatable {
    /// Application Support. Survives OS cache eviction. Default.
    case durable
    /// Caches. OS may delete. Disk etag is still stored so `If-None-Match` / 304 work.
    case purgable
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
    /// let theme = Analytics.OTA.flag("theme")?.stringValue
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

        /// Raw value for any flag. Use this for strings, numbers, and objects that are
        /// not on/off switches.
        public static func flag(_ key: String) -> AnalyticsOTAValue? { flags.flag(key) }

        public static func bool(_ key: String) -> Bool? { flags.bool(key) }
        public static func int(_ key: String) -> Int? { flags.int(key) }
        public static func double(_ key: String) -> Double? { flags.double(key) }
        public static func string(_ key: String) -> String? { flags.string(key) }
        public static func json(_ key: String) -> Data? { flags.json(key) }

        /// HMAC-signed manifest, then download files whose **disk** etag differs from the manifest.
        @discardableResult
        public static func sync(
            using configuration: AnalyticsConfiguration? = nil,
            downloadFiles: AnalyticsOTADownloadFiles = .all
        ) async throws -> AnalyticsOTASnapshot {
            let configuration = try resolved(configuration)
            await cacheEnvironment(configuration)
            return try await AnalyticsOTAClient.shared.sync(
                configuration: configuration,
                downloadFiles: downloadFiles
            )
        }

        /// `true` → `.all`, `false` → `.none`. Prefer `AnalyticsOTADownloadFiles`.
        @available(*, deprecated, message: "Use downloadFiles: .all or .none")
        @discardableResult
        public static func sync(
            using configuration: AnalyticsConfiguration? = nil,
            downloadFiles: Bool
        ) async throws -> AnalyticsOTASnapshot {
            try await sync(using: configuration, downloadFiles: downloadFiles ? .all : .none)
        }

        /// Lightweight flags-only GET. Does not touch cached files.
        @discardableResult
        public static func refreshFlags(
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> AnalyticsOTAFlags {
            let configuration = try resolved(configuration)
            await cacheEnvironment(configuration)
            return try await AnalyticsOTAClient.shared.refreshFlags(configuration: configuration)
        }

        /// Durable (Application Support) first, then purgable (Caches).
        public static func cachedFileURL(for path: String) -> URL? {
            guard let configuration = AnalyticsRuntime.configuration() else { return nil }
            return AnalyticsOTADiskStore(appId: configuration.appId).fileURL(for: path)
        }

        public static func cachedFile(for path: String) -> AnalyticsOTACachedFile? {
            guard let configuration = AnalyticsRuntime.configuration() else { return nil }
            return AnalyticsOTADiskStore(appId: configuration.appId).cachedFile(for: path)
        }

        /// Returns cached bytes when the **disk** etag matches the manifest; otherwise downloads.
        public static func data(
            for path: String,
            persist: AnalyticsOTAPersist = .durable,
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> Data {
            try await file(for: path, persist: persist, using: configuration).data
        }

        @discardableResult
        public static func file(
            for path: String,
            persist: AnalyticsOTAPersist = .durable,
            using configuration: AnalyticsConfiguration? = nil
        ) async throws -> AnalyticsOTACachedFile {
            try await AnalyticsOTAClient.shared.file(
                for: path,
                persist: persist,
                configuration: resolved(configuration)
            )
        }

        private static func resolved(_ configuration: AnalyticsConfiguration?) throws -> AnalyticsConfiguration {
            if let configuration { return configuration }
            if let stored = AnalyticsRuntime.configuration() { return stored }
            throw AnalyticsOTAError.notConfigured
        }

        private static func cacheEnvironment(_ configuration: AnalyticsConfiguration) async {
            let env = await configuration.environment()
            AnalyticsRuntime.setEnvironment(env)
        }
    }
}
