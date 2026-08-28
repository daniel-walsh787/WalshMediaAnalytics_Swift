import Foundation
import Testing
@testable import WalshMediaAnalytics

@Suite(.serialized)
struct AnalyticsOTATests {
    @Test func configCodec_signsConfigGetPath() {
        let path = "/v1/config/myapp/manifest"
        let payload = AnalyticsIngestCodec.configSignedPayload(path: path)
        #expect(payload == Data("config:GET:/v1/config/myapp/manifest".utf8))
        #expect(AnalyticsIngestCodec.configSignedPayload(path: "v1/config/myapp/manifest") == payload)

        let hex = AnalyticsIngestCodec.signatureHex(secret: "test-secret", payload: payload)
        #expect(hex.count == 64)
        #expect(hex == hex.lowercased())
        #expect(hex != AnalyticsIngestCodec.signatureHex(secret: "test-secret", payload: Data("status:2026-08-28".utf8)))
    }

    @Test func configCodec_encodesURIComponentLikeJS() {
        #expect(AnalyticsIngestCodec.encodeURIComponent("airbook") == "airbook")
        #expect(AnalyticsIngestCodec.encodeURIComponent("my-app") == "my-app")
        #expect(AnalyticsIngestCodec.encodeURIComponent("a b") == "a%20b")
    }

    @Test func etagHelpers_quoteAndNormalize() {
        #expect(AnalyticsOTACodec.ifNoneMatch("abc123") == "\"abc123\"")
        #expect(AnalyticsOTACodec.ifNoneMatch("\"abc123\"") == "\"abc123\"")
        #expect(AnalyticsOTACodec.normalizedEtag("\"abc123\"") == "abc123")
        #expect(AnalyticsOTACodec.normalizedEtag("W/\"abc123\"") == "abc123")
        #expect(AnalyticsOTACodec.etagsMatch("\"abc\"", "abc"))
        #expect(!AnalyticsOTACodec.etagsMatch("abc", "def"))
        #expect(!AnalyticsOTACodec.isSafeFilePath("../secret"))
        #expect(!AnalyticsOTACodec.isSafeFilePath("foo/../../etc/passwd"))
        #expect(!AnalyticsOTACodec.isSafeFilePath(""))
        #expect(AnalyticsOTACodec.isSafeFilePath("logos/QF.png"))
        #expect(AnalyticsOTACodec.isSafeFilePath("/etc/passwd"))
        #expect(AnalyticsOTACodec.normalizedFilePath("/logos/QF.png/") == "logos/QF.png")
    }

    @Test func needsHMAC_distinguishesPublicAndProtectedURLs() throws {
        let protected = try #require(URL(string: "https://analytics.walshmedia.net.au/v1/config/airbook/files/secret.json"))
        let publicURL = try #require(URL(string: "https://analytics.walshmedia.net.au/v1/config/walshmedia/airbook/files/logos/QF.png"))
        #expect(AnalyticsOTACodec.needsHMAC(url: protected, appId: "airbook"))
        #expect(!AnalyticsOTACodec.needsHMAC(url: publicURL, appId: "airbook"))
        #expect(AnalyticsOTACodec.signedPath(for: protected) == "/v1/config/airbook/files/secret.json")
    }

    @Test func decodeManifest_readsFlagsFilesAndTenant() throws {
        let json = """
        {
          "tenant_slug": "walshmedia",
          "app": "airbook",
          "flags": {
            "new_onboarding": true,
            "max_items": 42,
            "theme": "dark",
            "experiment": {"enabled": true, "variant": "b"}
          },
          "files": [
            {
              "path": "logos/QF.png",
              "etag": "abc123",
              "url": "https://analytics.walshmedia.net.au/v1/config/walshmedia/airbook/files/logos/QF.png",
              "visibility": "public",
              "content_type": "image/png",
              "size": 12
            },
            {
              "path": "secret.json",
              "etag": "def456",
              "url": "/v1/config/airbook/files/secret.json",
              "protected": true
            }
          ]
        }
        """.data(using: .utf8)!
        let base = try #require(URL(string: "https://analytics.walshmedia.net.au"))
        let snapshot = try AnalyticsOTACodec.decodeManifest(json, appId: "airbook", baseURL: base)
        #expect(snapshot.tenantSlug == "walshmedia")
        #expect(snapshot.flags.isEnabled("new_onboarding"))
        #expect(snapshot.flags.int("max_items") == 42)
        #expect(snapshot.flags.string("theme") == "dark")
        #expect(snapshot.flags.isEnabled("experiment"))
        #expect(snapshot.files.count == 2)
        #expect(snapshot.file(at: "logos/QF.png")?.isProtected == false)
        #expect(snapshot.file(at: "secret.json")?.isProtected == true)
        #expect(snapshot.file(at: "secret.json")?.url.path == "/v1/config/airbook/files/secret.json")
    }

    @Test func decodeFlags_acceptsBareObjectOrWrapped() throws {
        let wrapped = try AnalyticsOTACodec.decodeFlags(Data(#"{"flags":{"on":true}}"#.utf8))
        #expect(wrapped.bool("on") == true)

        let bare = try AnalyticsOTACodec.decodeFlags(Data(#"{"on":false}"#.utf8))
        #expect(bare.bool("on") == false)
        #expect(bare.isEnabled("missing", default: true))
    }

    @Test func configuration_derivesOTABaseURLFromIngest() {
        #expect(AnalyticsConfiguration.serviceBaseURL(from: AnalyticsConfiguration.defaultIngestURL)?.absoluteString == "https://analytics.walshmedia.net.au")
        #expect(AnalyticsConfiguration.defaultBaseURL?.host == "analytics.walshmedia.net.au")
    }

    @Test func sync_usesManifestEtagsAndSkipsUnchangedFiles() async throws {
        let harness = try OTATestHarness()
        defer { harness.tearDown() }

        OTAMockURLProtocol.stub(
            path: "/v1/config/airbook/manifest",
            status: 200,
            data: Self.manifestJSON(),
            headers: ["ETag": "\"manifest-1\"", "Content-Type": "application/json"]
        )
        OTAMockURLProtocol.stub(
            path: "/v1/config/walshmedia/airbook/files/airlines.csv",
            status: 200,
            data: Data("QF,VA\n".utf8),
            headers: ["ETag": "\"file-1\"", "Content-Type": "text/csv"]
        )
        OTAMockURLProtocol.stub(
            path: "/v1/config/airbook/files/secret.json",
            status: 200,
            data: Data(#"{"ok":true}"#.utf8),
            headers: ["ETag": "\"sec-1\"", "Content-Type": "application/json"]
        )

        let snapshot = try await harness.client.sync(configuration: harness.configuration, downloadFiles: true)
        #expect(snapshot.flags.isEnabled("new_onboarding"))
        #expect(snapshot.tenantSlug == "walshmedia")
        #expect(snapshot.manifestEtag == "manifest-1")
        #expect(snapshot.files.count == 2)

        let requests = OTAMockURLProtocol.requests
        #expect(requests.contains { $0.url?.path == "/v1/config/airbook/manifest" && $0.value(forHTTPHeaderField: "If-None-Match") == nil })
        #expect(requests.contains { $0.url?.path == "/v1/config/airbook/manifest" && $0.value(forHTTPHeaderField: "X-Signature") == Self.signature(for: "/v1/config/airbook/manifest") })

        let publicFile = try #require(requests.first { $0.url?.path == "/v1/config/walshmedia/airbook/files/airlines.csv" })
        #expect(publicFile.value(forHTTPHeaderField: "X-Signature") == nil)
        #expect(publicFile.value(forHTTPHeaderField: "X-App-Id") == nil)

        let protectedFile = try #require(requests.first { $0.url?.path == "/v1/config/airbook/files/secret.json" })
        #expect(protectedFile.value(forHTTPHeaderField: "X-App-Id") == "airbook")
        #expect(protectedFile.value(forHTTPHeaderField: "X-Signature") == Self.signature(for: "/v1/config/airbook/files/secret.json"))

        let csv = try await harness.client.file(for: "airlines.csv", configuration: harness.configuration)
        #expect(String(data: csv.data, encoding: .utf8) == "QF,VA\n")
        #expect(csv.notModified)

        OTAMockURLProtocol.resetRequests()
        OTAMockURLProtocol.stub(
            path: "/v1/config/airbook/manifest",
            status: 304,
            headers: ["ETag": "\"manifest-1\""]
        )
        let again = try await harness.client.sync(configuration: harness.configuration, downloadFiles: true)
        #expect(again.notModified)
        #expect(again.flags.isEnabled("new_onboarding"))
        #expect(OTAMockURLProtocol.requests.contains {
            $0.url?.path == "/v1/config/airbook/manifest"
                && $0.value(forHTTPHeaderField: "If-None-Match") == "\"manifest-1\""
        })
        #expect(!OTAMockURLProtocol.requests.contains { $0.url?.path.contains("/files/") == true })
    }

    @Test func sync_sendsIfNoneMatchWhenFileEtagChanges() async throws {
        let harness = try OTATestHarness()
        defer { harness.tearDown() }

        OTAMockURLProtocol.stub(
            path: "/v1/config/airbook/manifest",
            status: 200,
            data: Self.manifestJSON(fileEtag: "old"),
            headers: ["ETag": "\"m1\""]
        )
        OTAMockURLProtocol.stub(
            path: "/v1/config/walshmedia/airbook/files/airlines.csv",
            status: 200,
            data: Data("v1".utf8),
            headers: ["ETag": "\"old\""]
        )
        OTAMockURLProtocol.stub(
            path: "/v1/config/airbook/files/secret.json",
            status: 200,
            data: Data("{}".utf8),
            headers: ["ETag": "\"sec-1\""]
        )
        _ = try await harness.client.sync(configuration: harness.configuration, downloadFiles: true)

        OTAMockURLProtocol.resetRequests()
        OTAMockURLProtocol.stub(
            path: "/v1/config/airbook/manifest",
            status: 200,
            data: Self.manifestJSON(fileEtag: "new"),
            headers: ["ETag": "\"m2\""]
        )
        OTAMockURLProtocol.stub(
            path: "/v1/config/walshmedia/airbook/files/airlines.csv",
            status: 304,
            headers: ["ETag": "\"old\""]
        )
        let snapshot = try await harness.client.sync(configuration: harness.configuration, downloadFiles: true)
        let csvRequest = try #require(OTAMockURLProtocol.requests.first { $0.url?.path.hasSuffix("airlines.csv") == true })
        #expect(csvRequest.value(forHTTPHeaderField: "If-None-Match") == "\"old\"")
        let csv = try #require(snapshot.file(at: "airlines.csv"))
        #expect(String(data: try Data(contentsOf: harness.store.fileURL(for: csv.path)!), encoding: .utf8) == "v1")
    }

    @Test func sync_mapsQuotaAndUnauthorized() async throws {
        let harness = try OTATestHarness()
        defer { harness.tearDown() }

        OTAMockURLProtocol.stub(path: "/v1/config/airbook/manifest", status: 402, data: Data(#"{"error":"quota exceeded"}"#.utf8))
        await #expect(throws: AnalyticsOTAError.quotaExceeded) {
            try await harness.client.sync(configuration: harness.configuration, downloadFiles: false)
        }

        OTAMockURLProtocol.stub(path: "/v1/config/airbook/manifest", status: 401, data: Data(#"{"error":"unauthorized"}"#.utf8))
        await #expect(throws: AnalyticsOTAError.unauthorized) {
            try await harness.client.sync(configuration: harness.configuration, downloadFiles: false)
        }
    }

    @Test func refreshFlags_isLightweightSignedGet() async throws {
        let harness = try OTATestHarness()
        defer { harness.tearDown() }

        OTAMockURLProtocol.stub(
            path: "/v1/config/airbook/flags",
            status: 200,
            data: Data(#"{"flags":{"beta":true}}"#.utf8),
            headers: ["ETag": "\"flags-1\"", "Content-Type": "application/json"]
        )
        let flags = try await harness.client.refreshFlags(configuration: harness.configuration)
        #expect(flags.isEnabled("beta"))
        let request = try #require(OTAMockURLProtocol.requests.first)
        #expect(request.url?.path == "/v1/config/airbook/flags")
        #expect(request.value(forHTTPHeaderField: "X-Signature") == Self.signature(for: "/v1/config/airbook/flags"))
    }

    @Test func notConfigured_whenSecretMissing() async {
        let configuration = AnalyticsConfiguration(
            appId: "airbook",
            ingestURL: AnalyticsConfiguration.defaultIngestURL,
            hmacSecret: "",
            reportsCrashes: false
        )
        let client = AnalyticsOTAClient()
        await #expect(throws: AnalyticsOTAError.notConfigured) {
            try await client.sync(configuration: configuration, downloadFiles: false)
        }
    }

    private static func signature(for path: String, secret: String = "test-secret") -> String {
        AnalyticsIngestCodec.signatureHex(
            secret: secret,
            payload: AnalyticsIngestCodec.configSignedPayload(path: path)
        )
    }

    private static func manifestJSON(fileEtag: String = "file-1") -> Data {
        Data(
            """
            {
              "tenant_slug": "walshmedia",
              "flags": { "new_onboarding": true },
              "files": [
                {
                  "path": "airlines.csv",
                  "etag": "\(fileEtag)",
                  "url": "https://analytics.walshmedia.net.au/v1/config/walshmedia/airbook/files/airlines.csv",
                  "visibility": "public"
                },
                {
                  "path": "secret.json",
                  "etag": "sec-1",
                  "url": "https://analytics.walshmedia.net.au/v1/config/airbook/files/secret.json",
                  "protected": true
                }
              ]
            }
            """.utf8
        )
    }
}

private struct OTATestHarness {
    let client: AnalyticsOTAClient
    let configuration: AnalyticsConfiguration
    let cacheRoot: URL
    let defaults: UserDefaults
    let suiteName: String

    var store: AnalyticsOTADiskStore {
        AnalyticsOTADiskStore(appId: "airbook", defaults: defaults, cacheRoot: cacheRoot)
    }

    init() throws {
        OTAMockURLProtocol.reset()
        AnalyticsRuntime.resetForTests()
        suiteName = "WalshMediaAnalytics.ota.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw AnalyticsOTAError.invalidResponse
        }
        self.defaults = defaults
        cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [OTAMockURLProtocol.self]
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: sessionConfiguration)

        client = AnalyticsOTAClient(
            urlSession: session,
            defaults: defaults,
            cacheRoot: cacheRoot
        )
        configuration = AnalyticsConfiguration(
            appId: "airbook",
            ingestURL: AnalyticsConfiguration.defaultIngestURL,
            hmacSecret: "test-secret",
            reportsCrashes: false,
            environment: { "dev" }
        )
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheRoot)
        OTAMockURLProtocol.reset()
        AnalyticsRuntime.resetForTests()
    }
}

private final class OTAMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var status: Int
        var data: Data
        var headers: [String: String]
    }

    private static let lock = NSLock()
    private static var stubs: [String: Stub] = [:]
    static var requests: [URLRequest] = []

    static func reset() {
        lock.lock()
        stubs = [:]
        requests = []
        lock.unlock()
    }

    static func resetRequests() {
        lock.lock()
        requests = []
        lock.unlock()
    }

    static func stub(path: String, status: Int, data: Data = Data(), headers: [String: String] = [:]) {
        lock.lock()
        stubs[path] = Stub(status: status, data: data, headers: headers)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = request
        Self.lock.lock()
        Self.requests.append(current)
        let stub = Self.stubs[current.url?.path ?? ""]
        Self.lock.unlock()

        guard let url = current.url, let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
