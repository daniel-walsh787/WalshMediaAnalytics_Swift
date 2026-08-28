import Foundation

struct AnalyticsOTAPersistedSnapshot: Codable, Equatable {
    var tenantSlug: String?
    var flags: [String: AnalyticsOTAValue]
    var files: [AnalyticsOTAPersistedFile]
    var manifestEtag: String?
    var flagsEtag: String?

    func snapshot() -> AnalyticsOTASnapshot {
        AnalyticsOTASnapshot(
            tenantSlug: tenantSlug,
            flags: AnalyticsOTAFlags(values: flags),
            files: files.compactMap(\.file),
            manifestEtag: manifestEtag,
            flagsEtag: flagsEtag
        )
    }

    static func from(_ snapshot: AnalyticsOTASnapshot) -> AnalyticsOTAPersistedSnapshot {
        AnalyticsOTAPersistedSnapshot(
            tenantSlug: snapshot.tenantSlug,
            flags: snapshot.flags.values,
            files: snapshot.files.map(AnalyticsOTAPersistedFile.init),
            manifestEtag: snapshot.manifestEtag,
            flagsEtag: snapshot.flagsEtag
        )
    }
}

struct AnalyticsOTAPersistedFile: Codable, Equatable {
    var path: String
    var etag: String
    var url: String
    var isProtected: Bool
    var contentType: String?
    var size: Int?

    init(_ file: AnalyticsOTAFile) {
        path = file.path
        etag = file.etag
        url = file.url.absoluteString
        isProtected = file.isProtected
        contentType = file.contentType
        size = file.size
    }

    var file: AnalyticsOTAFile? {
        guard let url = URL(string: url) else { return nil }
        return AnalyticsOTAFile(
            path: path,
            etag: etag,
            url: url,
            isProtected: isProtected,
            contentType: contentType,
            size: size
        )
    }
}

struct AnalyticsOTADiskStore {
    var appId: String
    var defaults: UserDefaults
    var fileManager: FileManager
    var durableRoot: URL
    var purgableRoot: URL

    init(
        appId: String,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        durableRoot: URL? = nil,
        purgableRoot: URL? = nil
    ) {
        self.appId = appId
        self.defaults = defaults
        self.fileManager = fileManager
        self.durableRoot = Self.filesRoot(
            under: durableRoot ?? Self.defaultDurableRoot(fileManager: fileManager),
            appId: appId
        )
        self.purgableRoot = Self.filesRoot(
            under: purgableRoot ?? Self.defaultPurgableRoot(fileManager: fileManager),
            appId: appId
        )
    }

    private var snapshotKey: String { "\(appId).analytics.ota.snapshot" }

    static func filesRoot(under base: URL, appId: String) -> URL {
        base
            .appendingPathComponent("WalshMediaAnalytics", isDirectory: true)
            .appendingPathComponent(appId, isDirectory: true)
            .appendingPathComponent("ota", isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
    }

    static func defaultDurableRoot(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    static func defaultPurgableRoot(fileManager: FileManager) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    func loadSnapshot() -> AnalyticsOTASnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return (try? AnalyticsOTACodec.jsonDecoder().decode(AnalyticsOTAPersistedSnapshot.self, from: data))?.snapshot()
    }

    func saveSnapshot(_ snapshot: AnalyticsOTASnapshot) {
        guard let data = try? AnalyticsOTACodec.jsonEncoder().encode(AnalyticsOTAPersistedSnapshot.from(snapshot)) else {
            return
        }
        defaults.set(data, forKey: snapshotKey)
    }

    func filesRoot(for persist: AnalyticsOTAPersist) -> URL {
        persist == .durable ? durableRoot : purgableRoot
    }

    func destinationURL(for path: String, persist: AnalyticsOTAPersist) -> URL? {
        guard AnalyticsOTACodec.isSafeFilePath(path) else { return nil }
        let parts = AnalyticsOTACodec.normalizedFilePath(path).split(separator: "/").map(String.init)
        guard let last = parts.last else { return nil }
        var url = filesRoot(for: persist)
        for directory in parts.dropLast() {
            url = url.appendingPathComponent(directory, isDirectory: true)
        }
        return url.appendingPathComponent(last, isDirectory: false)
    }

    func sidecarURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("etag")
    }

    func fileURL(for path: String, persist: AnalyticsOTAPersist) -> URL? {
        guard let url = destinationURL(for: path, persist: persist) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// Durable first, then purgable.
    func fileURL(for path: String) -> URL? {
        fileURL(for: path, persist: .durable) ?? fileURL(for: path, persist: .purgable)
    }

    func diskEtag(for path: String, persist: AnalyticsOTAPersist) -> String? {
        guard let fileURL = destinationURL(for: path, persist: persist) else { return nil }
        let sidecar = sidecarURL(for: fileURL)
        guard let data = try? Data(contentsOf: sidecar),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return AnalyticsOTACodec.normalizedEtag(raw)
    }

    func diskEtag(for path: String) -> String? {
        diskEtag(for: path, persist: .durable) ?? diskEtag(for: path, persist: .purgable)
    }

    func cachedFile(for path: String, persist: AnalyticsOTAPersist) -> AnalyticsOTACachedFile? {
        let normalized = AnalyticsOTACodec.normalizedFilePath(path)
        guard let localURL = fileURL(for: normalized, persist: persist),
              let data = try? Data(contentsOf: localURL) else {
            return nil
        }
        let etag = diskEtag(for: normalized, persist: persist) ?? ""
        return AnalyticsOTACachedFile(
            path: normalized,
            etag: etag,
            localURL: localURL,
            data: data,
            contentType: loadSnapshot()?.file(at: normalized)?.contentType,
            notModified: true,
            persist: persist
        )
    }

    func cachedFile(for path: String) -> AnalyticsOTACachedFile? {
        cachedFile(for: path, persist: .durable) ?? cachedFile(for: path, persist: .purgable)
    }

    /// Bytes on disk whose sidecar etag matches the manifest. Durable wins over purgable.
    func cachedFile(for path: String, matchingManifestEtag manifestEtag: String) -> AnalyticsOTACachedFile? {
        if let durable = cachedFile(for: path, persist: .durable),
           AnalyticsOTACodec.etagsMatch(durable.etag, manifestEtag) {
            return durable
        }
        if let purgable = cachedFile(for: path, persist: .purgable),
           AnalyticsOTACodec.etagsMatch(purgable.etag, manifestEtag) {
            return purgable
        }
        return nil
    }

    func writeEtag(path: String, etag: String, persist: AnalyticsOTAPersist) throws {
        guard let fileURL = destinationURL(for: path, persist: persist) else {
            throw AnalyticsOTAError.invalidPath(path)
        }
        let sidecar = sidecarURL(for: fileURL)
        try fileManager.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        let normalized = AnalyticsOTACodec.normalizedEtag(etag) ?? etag
        try Data(normalized.utf8).write(to: sidecar, options: .atomic)
    }

    func writeFile(path: String, data: Data, etag: String, persist: AnalyticsOTAPersist) throws -> URL {
        guard let url = destinationURL(for: path, persist: persist) else {
            throw AnalyticsOTAError.invalidPath(path)
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try writeEtag(path: path, etag: etag, persist: persist)
        return url
    }

    func removeFile(path: String, persist: AnalyticsOTAPersist) {
        if let url = destinationURL(for: path, persist: persist) {
            try? fileManager.removeItem(at: url)
            try? fileManager.removeItem(at: sidecarURL(for: url))
        }
    }

    func promoteToDurable(path: String) throws -> AnalyticsOTACachedFile? {
        guard let purgable = cachedFile(for: path, persist: .purgable) else { return nil }
        let url = try writeFile(path: path, data: purgable.data, etag: purgable.etag, persist: .durable)
        removeFile(path: path, persist: .purgable)
        return AnalyticsOTACachedFile(
            path: purgable.path,
            etag: purgable.etag,
            localURL: url,
            data: purgable.data,
            contentType: purgable.contentType,
            notModified: true,
            persist: .durable
        )
    }

    func prune(keeping manifestPaths: Set<String>) {
        prune(root: durableRoot, keeping: manifestPaths)
        prune(root: purgableRoot, keeping: manifestPaths)
    }

    private func prune(root: URL, keeping manifestPaths: Set<String>) {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let resource = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard resource?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            let relative = String(full.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if shouldKeep(relative: relative, manifestPaths: manifestPaths) { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Keep manifest files and their `.etag` sidecars. Never delete a path that is still listed
    /// but has not been downloaded (it is not on disk).
    func shouldKeep(relative: String, manifestPaths: Set<String>) -> Bool {
        if manifestPaths.contains(relative) { return true }
        if relative.hasSuffix(".etag") {
            let associated = String(relative.dropLast(5))
            return manifestPaths.contains(associated)
        }
        return false
    }
}

actor AnalyticsOTAClient {
    static let shared = AnalyticsOTAClient()

    private static let maxFileBytes = 6 * 1024 * 1024

    private let urlSession: URLSession
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let durableRoot: URL?
    private let purgableRoot: URL?

    init(
        urlSession: URLSession = .shared,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        durableRoot: URL? = nil,
        purgableRoot: URL? = nil
    ) {
        self.urlSession = urlSession
        self.defaults = defaults
        self.fileManager = fileManager
        self.durableRoot = durableRoot
        self.purgableRoot = purgableRoot
    }

    func sync(configuration: AnalyticsConfiguration, downloadFiles: AnalyticsOTADownloadFiles) async throws -> AnalyticsOTASnapshot {
        try await performSync(configuration: configuration, downloadFiles: downloadFiles)
    }

    func sync(configuration: AnalyticsConfiguration, downloadFiles: Bool) async throws -> AnalyticsOTASnapshot {
        try await performSync(configuration: configuration, downloadFiles: downloadFiles ? .all : .none)
    }

    func refreshFlags(configuration: AnalyticsConfiguration) async throws -> AnalyticsOTAFlags {
        let credentials = try credentials(from: configuration)
        let store = store(appId: credentials.appId)
        var snapshot = store.loadSnapshot() ?? AnalyticsOTASnapshot()

        let url = try configURL(credentials: credentials, suffix: "flags")
        let result = try await get(
            url: url,
            sign: true,
            etag: snapshot.flagsEtag,
            credentials: credentials
        )
        switch result {
        case .notModified(let etag):
            snapshot.flagsEtag = etag ?? snapshot.flagsEtag
            snapshot.notModified = true
        case .ok(let data, let etag, _):
            snapshot.flags = try AnalyticsOTACodec.decodeFlags(data)
            snapshot.flagsEtag = etag ?? snapshot.flagsEtag
            snapshot.notModified = false
        }
        store.saveSnapshot(snapshot)
        AnalyticsOTAMemory.publish(snapshot)
        return snapshot.flags
    }

    func file(
        for path: String,
        persist: AnalyticsOTAPersist = .durable,
        configuration: AnalyticsConfiguration
    ) async throws -> AnalyticsOTACachedFile {
        let credentials = try credentials(from: configuration)
        let store = store(appId: credentials.appId)
        let normalized = AnalyticsOTACodec.normalizedFilePath(path)
        guard AnalyticsOTACodec.isSafeFilePath(normalized) else {
            throw AnalyticsOTAError.invalidPath(path)
        }

        var snapshot = store.loadSnapshot()
        if snapshot == nil {
            snapshot = try await performSync(configuration: configuration, downloadFiles: .none)
        }
        guard let snapshot else {
            throw AnalyticsOTAError.invalidResponse
        }
        guard let remote = snapshot.file(at: normalized) else {
            throw AnalyticsOTAError.fileNotInManifest(normalized)
        }
        if let cached = store.cachedFile(for: normalized, matchingManifestEtag: remote.etag) {
            if persist == .durable, cached.persist == .purgable {
                return try store.promoteToDurable(path: normalized) ?? cached
            }
            return cached
        }
        return try await download(
            file: remote,
            persist: persist,
            storedEtag: store.diskEtag(for: normalized),
            credentials: credentials,
            store: store
        )
    }

    private func performSync(
        configuration: AnalyticsConfiguration,
        downloadFiles: AnalyticsOTADownloadFiles
    ) async throws -> AnalyticsOTASnapshot {
        let credentials = try credentials(from: configuration)
        let store = store(appId: credentials.appId)
        let cached = store.loadSnapshot()

        let url = try configURL(credentials: credentials, suffix: "manifest")
        let result = try await get(
            url: url,
            sign: true,
            etag: cached?.manifestEtag,
            credentials: credentials
        )

        var snapshot: AnalyticsOTASnapshot
        switch result {
        case .notModified(let etag):
            snapshot = cached ?? AnalyticsOTASnapshot()
            snapshot.manifestEtag = etag ?? cached?.manifestEtag
            snapshot.notModified = true
        case .ok(let data, let etag, _):
            snapshot = try AnalyticsOTACodec.decodeManifest(data, appId: credentials.appId, baseURL: credentials.baseURL)
            snapshot.manifestEtag = etag
            snapshot.flagsEtag = cached?.flagsEtag
            snapshot.notModified = false
        }

        if !snapshot.notModified {
            let pending = snapshot.files.filter { downloadFiles.shouldDownload($0.path) }
            if !pending.isEmpty {
                snapshot = try await downloadChangedFiles(
                    snapshot: snapshot,
                    files: pending,
                    store: store,
                    credentials: credentials
                )
            }
            store.prune(keeping: Set(snapshot.files.map(\.path)))
        }

        store.saveSnapshot(snapshot)
        AnalyticsOTAMemory.publish(snapshot)
        return snapshot
    }

    private func downloadChangedFiles(
        snapshot: AnalyticsOTASnapshot,
        files: [AnalyticsOTAFile],
        store: AnalyticsOTADiskStore,
        credentials: Credentials
    ) async throws -> AnalyticsOTASnapshot {
        for file in files {
            if let cached = store.cachedFile(for: file.path, matchingManifestEtag: file.etag) {
                if cached.persist == .purgable {
                    _ = try store.promoteToDurable(path: file.path)
                }
                continue
            }
            _ = try await download(
                file: file,
                persist: .durable,
                storedEtag: store.diskEtag(for: file.path),
                credentials: credentials,
                store: store
            )
        }
        return snapshot
    }

    private func download(
        file: AnalyticsOTAFile,
        persist: AnalyticsOTAPersist,
        storedEtag: String?,
        credentials: Credentials,
        store: AnalyticsOTADiskStore
    ) async throws -> AnalyticsOTACachedFile {
        let sign = file.isProtected || AnalyticsOTACodec.needsHMAC(url: file.url, appId: credentials.appId)
        let result = try await get(
            url: file.url,
            sign: sign,
            etag: storedEtag,
            credentials: credentials
        )
        switch result {
        case .notModified(let etag):
            if let cached = store.cachedFile(for: file.path) {
                let confirmed = etag ?? cached.etag
                if !cached.etag.isEmpty {
                    try store.writeEtag(path: file.path, etag: confirmed, persist: cached.persist)
                }
                if persist == .durable, cached.persist == .purgable {
                    return try store.promoteToDurable(path: file.path) ?? cached
                }
                return AnalyticsOTACachedFile(
                    path: cached.path,
                    etag: confirmed,
                    localURL: cached.localURL,
                    data: cached.data,
                    contentType: cached.contentType,
                    notModified: true,
                    persist: cached.persist
                )
            }
            let retry = try await get(url: file.url, sign: sign, etag: nil, credentials: credentials)
            guard case .ok(let data, let etag, let contentType) = retry else {
                throw AnalyticsOTAError.invalidResponse
            }
            return try persistFile(
                path: file.path,
                data: data,
                etag: etag ?? file.etag,
                contentType: contentType,
                persist: persist,
                store: store,
                notModified: false
            )
        case .ok(let data, let etag, let contentType):
            return try persistFile(
                path: file.path,
                data: data,
                etag: etag ?? file.etag,
                contentType: contentType,
                persist: persist,
                store: store,
                notModified: false
            )
        }
    }

    private func persistFile(
        path: String,
        data: Data,
        etag: String,
        contentType: String?,
        persist: AnalyticsOTAPersist,
        store: AnalyticsOTADiskStore,
        notModified: Bool
    ) throws -> AnalyticsOTACachedFile {
        guard data.count <= Self.maxFileBytes else {
            throw AnalyticsOTAError.httpStatus(413, message: "OTA file exceeds \(Self.maxFileBytes) bytes")
        }
        if persist == .purgable,
           let durable = store.cachedFile(for: path, persist: .durable),
           AnalyticsOTACodec.etagsMatch(durable.etag, etag) {
            return durable
        }
        let writeTo: AnalyticsOTAPersist = persist == .durable ? .durable : .purgable
        let localURL = try store.writeFile(path: path, data: data, etag: etag, persist: writeTo)
        if writeTo == .durable {
            store.removeFile(path: path, persist: .purgable)
        }
        return AnalyticsOTACachedFile(
            path: AnalyticsOTACodec.normalizedFilePath(path),
            etag: etag,
            localURL: localURL,
            data: data,
            contentType: contentType,
            notModified: notModified,
            persist: writeTo
        )
    }

    private enum HTTPResult {
        case ok(Data, etag: String?, contentType: String?)
        case notModified(etag: String?)
    }

    private func get(
        url: URL,
        sign: Bool,
        etag: String?,
        credentials: Credentials
    ) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if let header = etag.flatMap(AnalyticsOTACodec.ifNoneMatch) {
            request.setValue(header, forHTTPHeaderField: "If-None-Match")
        }
        if sign {
            let path = AnalyticsOTACodec.signedPath(for: url)
            request.setValue(credentials.appId, forHTTPHeaderField: "X-App-Id")
            request.setValue(
                AnalyticsIngestCodec.signatureHex(
                    secret: credentials.hmacSecret,
                    payload: AnalyticsIngestCodec.configSignedPayload(path: path)
                ),
                forHTTPHeaderField: "X-Signature"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AnalyticsOTAError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AnalyticsOTAError.invalidResponse
        }
        let responseEtag = AnalyticsOTACodec.normalizedEtag(http.value(forHTTPHeaderField: "ETag"))
        let contentType = http.value(forHTTPHeaderField: "Content-Type")

        switch http.statusCode {
        case 200:
            return .ok(data, etag: responseEtag, contentType: contentType)
        case 304:
            return .notModified(etag: responseEtag ?? AnalyticsOTACodec.normalizedEtag(etag))
        case 401, 403:
            throw AnalyticsOTAError.unauthorized
        case 402:
            print("[WalshMediaAnalytics] OTA 402 — quota exceeded, pause config reads")
            throw AnalyticsOTAError.quotaExceeded
        case 404:
            throw AnalyticsOTAError.notFound
        default:
            throw AnalyticsOTAError.httpStatus(http.statusCode, message: AnalyticsOTACodec.errorMessage(from: data))
        }
    }

    private func configURL(credentials: Credentials, suffix: String) throws -> URL {
        guard let url = AnalyticsOTACodec.configURL(baseURL: credentials.baseURL, appId: credentials.appId, suffix: suffix) else {
            throw AnalyticsOTAError.invalidResponse
        }
        return url
    }

    private func store(appId: String) -> AnalyticsOTADiskStore {
        AnalyticsOTADiskStore(
            appId: appId,
            defaults: defaults,
            fileManager: fileManager,
            durableRoot: durableRoot,
            purgableRoot: purgableRoot
        )
    }

    private struct Credentials {
        var appId: String
        var hmacSecret: String
        var baseURL: URL
    }

    private func credentials(from configuration: AnalyticsConfiguration) throws -> Credentials {
        guard configuration.isConfigured, let baseURL = configuration.baseURL else {
            throw AnalyticsOTAError.notConfigured
        }
        return Credentials(appId: configuration.appId, hmacSecret: configuration.hmacSecret, baseURL: baseURL)
    }
}
