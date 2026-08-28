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
    var cacheRoot: URL

    init(
        appId: String,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        cacheRoot: URL? = nil
    ) {
        self.appId = appId
        self.defaults = defaults
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot(fileManager: fileManager)
    }

    private var snapshotKey: String { "\(appId).analytics.ota.snapshot" }

    private var filesRoot: URL {
        cacheRoot
            .appendingPathComponent("WalshMediaAnalytics", isDirectory: true)
            .appendingPathComponent(appId, isDirectory: true)
            .appendingPathComponent("ota", isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
    }

    static func defaultCacheRoot(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
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

    func destinationURL(for path: String) -> URL? {
        guard AnalyticsOTACodec.isSafeFilePath(path) else { return nil }
        let parts = AnalyticsOTACodec.normalizedFilePath(path).split(separator: "/").map(String.init)
        guard let last = parts.last else { return nil }
        var url = filesRoot
        for directory in parts.dropLast() {
            url = url.appendingPathComponent(directory, isDirectory: true)
        }
        return url.appendingPathComponent(last, isDirectory: false)
    }

    func fileURL(for path: String) -> URL? {
        guard let url = destinationURL(for: path) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    func cachedFile(for path: String) -> AnalyticsOTACachedFile? {
        let normalized = AnalyticsOTACodec.normalizedFilePath(path)
        guard let localURL = fileURL(for: normalized),
              let data = try? Data(contentsOf: localURL),
              let meta = loadSnapshot()?.file(at: normalized) else {
            return nil
        }
        return AnalyticsOTACachedFile(
            path: normalized,
            etag: meta.etag,
            localURL: localURL,
            data: data,
            contentType: meta.contentType,
            notModified: true
        )
    }

    func writeFile(path: String, data: Data) throws -> URL {
        guard let url = destinationURL(for: path) else {
            throw AnalyticsOTAError.invalidPath(path)
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    func removeFile(path: String) {
        guard let url = fileURL(for: path) else { return }
        try? fileManager.removeItem(at: url)
    }

    func prune(keeping paths: Set<String>) {
        guard let enumerator = fileManager.enumerator(at: filesRoot, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }
        let rootPath = filesRoot.standardizedFileURL.path
        for case let url as URL in enumerator {
            let resource = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard resource?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            let relative = String(full.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !paths.contains(relative) {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

actor AnalyticsOTAClient {
    static let shared = AnalyticsOTAClient()

    private static let maxFileBytes = 6 * 1024 * 1024

    private let urlSession: URLSession
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let cacheRoot: URL?

    init(
        urlSession: URLSession = .shared,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        cacheRoot: URL? = nil
    ) {
        self.urlSession = urlSession
        self.defaults = defaults
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot
    }

    func sync(configuration: AnalyticsConfiguration, downloadFiles: Bool) async throws -> AnalyticsOTASnapshot {
        try await performSync(configuration: configuration, downloadFiles: downloadFiles)
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

    func file(for path: String, configuration: AnalyticsConfiguration) async throws -> AnalyticsOTACachedFile {
        let credentials = try credentials(from: configuration)
        let store = store(appId: credentials.appId)
        let normalized = AnalyticsOTACodec.normalizedFilePath(path)
        guard AnalyticsOTACodec.isSafeFilePath(normalized) else {
            throw AnalyticsOTAError.invalidPath(path)
        }

        var snapshot = store.loadSnapshot()
        if snapshot == nil {
            snapshot = try await performSync(configuration: configuration, downloadFiles: false)
        }
        guard var snapshot else {
            throw AnalyticsOTAError.invalidResponse
        }
        guard let remote = snapshot.file(at: normalized) else {
            throw AnalyticsOTAError.fileNotInManifest(normalized)
        }
        if let cached = store.cachedFile(for: normalized),
           AnalyticsOTACodec.etagsMatch(cached.etag, remote.etag) {
            return cached
        }
        let fetched = try await download(file: remote, storedEtag: store.cachedFile(for: normalized)?.etag, credentials: credentials, store: store)
        if let index = snapshot.files.firstIndex(where: { $0.path == normalized }) {
            snapshot.files[index].etag = fetched.etag
            snapshot.files[index].contentType = fetched.contentType ?? snapshot.files[index].contentType
        }
        store.saveSnapshot(snapshot)
        AnalyticsOTAMemory.publish(snapshot)
        return fetched
    }

    private func performSync(configuration: AnalyticsConfiguration, downloadFiles: Bool) async throws -> AnalyticsOTASnapshot {
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

        if downloadFiles, !snapshot.notModified {
            snapshot = try await downloadChangedFiles(snapshot: snapshot, store: store, credentials: credentials)
            store.prune(keeping: Set(snapshot.files.map(\.path)))
        }

        store.saveSnapshot(snapshot)
        AnalyticsOTAMemory.publish(snapshot)
        return snapshot
    }

    private func downloadChangedFiles(
        snapshot: AnalyticsOTASnapshot,
        store: AnalyticsOTADiskStore,
        credentials: Credentials
    ) async throws -> AnalyticsOTASnapshot {
        var updated = snapshot
        for (index, file) in snapshot.files.enumerated() {
            if let cached = store.cachedFile(for: file.path),
               AnalyticsOTACodec.etagsMatch(cached.etag, file.etag) {
                continue
            }
            let fetched = try await download(
                file: file,
                storedEtag: store.cachedFile(for: file.path)?.etag,
                credentials: credentials,
                store: store
            )
            updated.files[index].etag = fetched.etag
            updated.files[index].contentType = fetched.contentType ?? file.contentType
        }
        return updated
    }

    private func download(
        file: AnalyticsOTAFile,
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
        case .notModified:
            if let cached = store.cachedFile(for: file.path) {
                return cached
            }
            let retry = try await get(url: file.url, sign: sign, etag: nil, credentials: credentials)
            guard case .ok(let data, let etag, let contentType) = retry else {
                throw AnalyticsOTAError.invalidResponse
            }
            return try persist(path: file.path, data: data, etag: etag ?? file.etag, contentType: contentType, store: store, notModified: false)
        case .ok(let data, let etag, let contentType):
            return try persist(path: file.path, data: data, etag: etag ?? file.etag, contentType: contentType, store: store, notModified: false)
        }
    }

    private func persist(
        path: String,
        data: Data,
        etag: String,
        contentType: String?,
        store: AnalyticsOTADiskStore,
        notModified: Bool
    ) throws -> AnalyticsOTACachedFile {
        guard data.count <= Self.maxFileBytes else {
            throw AnalyticsOTAError.httpStatus(413, message: "OTA file exceeds \(Self.maxFileBytes) bytes")
        }
        let localURL = try store.writeFile(path: path, data: data)
        return AnalyticsOTACachedFile(
            path: AnalyticsOTACodec.normalizedFilePath(path),
            etag: etag,
            localURL: localURL,
            data: data,
            contentType: contentType,
            notModified: notModified
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
            cacheRoot: cacheRoot
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
