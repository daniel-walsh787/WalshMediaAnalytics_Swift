import Foundation
import Testing
import WalshMediaAnalyticsSec
@testable import WalshMediaAnalytics

struct WalshMediaAnalyticsTests {
    @Test func analyticsBatching_shrinksUntilBodyFits() {
        #expect(AnalyticsBatching.reducedCount(current: 40, bodyBytes: 1000) == 40)
        #expect(AnalyticsBatching.reducedCount(current: 40, bodyBytes: AnalyticsBatching.maxBodyBytes + 1) == 20)
        #expect(AnalyticsBatching.reducedCount(current: 2, bodyBytes: AnalyticsBatching.maxBodyBytes + 1) == 1)
        #expect(AnalyticsBatching.reducedCount(current: 1, bodyBytes: AnalyticsBatching.maxBodyBytes + 1) == nil)
    }

    @Test func analyticsConfiguration_normalizesAppId() {
        #expect(AnalyticsConfiguration.normalizedAppId("airbook") == "airbook")
        #expect(AnalyticsConfiguration.normalizedAppId(" EchoMix ") == "echomix")
        #expect(AnalyticsConfiguration.normalizedAppId("") == nil)
        #expect(AnalyticsConfiguration.normalizedAppId("$(ANALYTICS_APPNAME)") == nil)
        #expect(AnalyticsConfiguration.defaultIngestURL?.host == "analytics.walshmedia.net.au")
        #expect(AnalyticsConfiguration.defaultBaseURL?.host == "analytics.walshmedia.net.au")
        #expect(
            AnalyticsConfiguration.serviceBaseURL(from: AnalyticsConfiguration.defaultIngestURL)?.absoluteString
                == "https://analytics.walshmedia.net.au"
        )
    }

    @Test func ingestEnvironment_mapsSignInTier() {
        #expect(AnalyticsConfiguration.ingestEnvironment(fromSignInTier: "development") == "dev")
        #expect(AnalyticsConfiguration.ingestEnvironment(fromSignInTier: "dev") == "dev")
        #expect(AnalyticsConfiguration.ingestEnvironment(fromSignInTier: "testflight") == "testflight")
        #expect(AnalyticsConfiguration.ingestEnvironment(fromSignInTier: "production") == "prod")
        #expect(AnalyticsConfiguration.ingestEnvironment(fromSignInTier: "") == "prod")
    }

    @Test func analyticsEnvironment_parsesPlistOverride() {
        #expect(AnalyticsEnvironment.override(fromPlistValue: nil) == nil)
        #expect(AnalyticsEnvironment.override(fromPlistValue: "") == nil)
        #expect(AnalyticsEnvironment.override(fromPlistValue: "$(ANALYTICS_ENV)") == nil)
        #expect(AnalyticsEnvironment.override(fromPlistValue: "development") == "dev")
        #expect(AnalyticsEnvironment.override(fromPlistValue: "PROD") == "prod")
        #expect(AnalyticsEnvironment.override(fromPlistValue: " testflight ") == "testflight")
    }

    @Test func analyticsEnvironment_detectsSandboxReceiptAndTestFlightProfile() {
        #expect(AnalyticsEnvironment.hasSandboxReceipt(url: URL(fileURLWithPath: "/foo/sandboxReceipt")))
        #expect(!AnalyticsEnvironment.hasSandboxReceipt(url: URL(fileURLWithPath: "/foo/receipt")))
        #expect(!AnalyticsEnvironment.hasSandboxReceipt(url: nil))
        #expect(AnalyticsEnvironment.hasSandboxReceiptFile(appStoreReceiptURL: URL(fileURLWithPath: "/foo/sandboxReceipt")))
        #expect(AnalyticsEnvironment.hasTestFlightProvision("<key>beta-reports-active</key><true/>"))
        #expect(!AnalyticsEnvironment.hasTestFlightProvision("<key>get-task-allow</key><true/>"))
        #expect(AnalyticsEnvironment.hasTestFlightEntitlementValue(true))
        #expect(AnalyticsEnvironment.hasTestFlightEntitlementValue(NSNumber(value: true)))
        #expect(!AnalyticsEnvironment.hasTestFlightEntitlementValue(false))
        #expect(!AnalyticsEnvironment.hasTestFlightEntitlementValue(nil))

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>beta-reports-active</key>
            <true/>
        </dict>
        </plist>
        """
        let xmlBytes = Array(xml.utf8)
        #expect(xmlBytes.withUnsafeBytes { raw in
            WalshMediaEntitlementsDataHasBetaReportsActive(raw.baseAddress, xmlBytes.count)
        })
        let absent = Array("<dict><key>get-task-allow</key><true/></dict>".utf8)
        #expect(!absent.withUnsafeBytes { raw in
            WalshMediaEntitlementsDataHasBetaReportsActive(raw.baseAddress, absent.count)
        })
        _ = AnalyticsEnvironment.hasBetaReportsActiveEntitlement()
    }

    @Test func ingestCodec_signsTimestampDotBody() throws {
        let events = [
            AnalyticsQueuedEvent(
                id: "evt-1",
                name: "app_open",
                ts: 1_755_000_000,
                props: ["screen": "home"]
            )
        ]
        let body = try AnalyticsIngestCodec.encodeBody(
            platform: "ios",
            env: "dev",
            deviceID: "550e8400-e29b-41d4-a716-446655440000",
            events: events
        )
        let json = try #require(String(data: body, encoding: .utf8))
        #expect(json.contains("\"device_id\":\"550e8400-e29b-41d4-a716-446655440000\""))
        #expect(json.contains("\"env\":\"dev\""))
        #expect(json.contains("\"platform\":\"ios\""))
        #expect(json.contains("\"name\":\"app_open\""))
        #expect(!json.contains("user_id"))
        #expect(!json.contains("\n"))

        let withUser = try AnalyticsIngestCodec.encodeBody(
            platform: "ios",
            env: "dev",
            deviceID: "550e8400-e29b-41d4-a716-446655440000",
            userID: "_ckUserRecord",
            events: events
        )
        let withUserJSON = try #require(String(data: withUser, encoding: .utf8))
        #expect(withUserJSON.contains("\"user_id\":\"_ckUserRecord\""))

        let again = try AnalyticsIngestCodec.encodeBody(
            platform: "ios",
            env: "dev",
            deviceID: "550e8400-e29b-41d4-a716-446655440000",
            events: events
        )
        #expect(body == again)

        let timestamp = 1_755_000_100
        let signed = AnalyticsIngestCodec.ingestSignedPayload(timestamp: timestamp, body: body)
        #expect(signed == Data("\(timestamp).".utf8) + body)

        let hex = AnalyticsIngestCodec.signatureHex(secret: "test-secret", payload: signed)
        #expect(hex.count == 64)
        #expect(hex == hex.lowercased())
        #expect(hex == AnalyticsIngestCodec.signatureHex(secret: "test-secret", payload: signed))
        #expect(hex != AnalyticsIngestCodec.signatureHex(secret: "other", payload: signed))

        let bodyOnlyHex = AnalyticsIngestCodec.signatureHex(secret: "test-secret", payload: body)
        #expect(hex != bodyOnlyHex)
    }

    @Test func crashMapper_usesCrashVersusHangNames() {
        let crash = AnalyticsCrashMapper.crash(exceptionType: 1, signal: 11, version: "1.2.3")
        #expect(crash.name == "app_crash")
        #expect(crash.props["exception_type"] == .int(1))
        #expect(crash.props["signal"] == .int(11))
        #expect(crash.props["version"] == .string("1.2.3"))
        #expect(crash.props["hang_ms"] == nil)

        let hang = AnalyticsCrashMapper.hang(hangMilliseconds: 2_400, version: "1.2.3")
        #expect(hang.name == "app_hang")
        #expect(hang.props["hang_ms"] == .int(2_400))
        #expect(hang.props["exception_type"] == nil)
    }

    @Test func crashMapper_truncatesReasonAndStack() throws {
        let reason = String(repeating: "x", count: AnalyticsCrashMapper.maxReasonLength + 40)
        let crash = AnalyticsCrashMapper.crash(reason: reason)
        #expect(crash.props["reason"] == .string(String(repeating: "x", count: AnalyticsCrashMapper.maxReasonLength)))

        let longName = String(repeating: "A", count: 200)
        var current: [String: Any] = [
            "binaryName": longName,
            "offsetIntoBinaryTextSegment": 1
        ]
        for index in 0..<20 {
            current = [
                "binaryName": longName,
                "offsetIntoBinaryTextSegment": index,
                "subFrames": [current]
            ]
        }
        let json = try JSONSerialization.data(withJSONObject: [
            "callStacks": [
                ["threadAttributed": true, "callStackRootFrames": [current]]
            ]
        ])
        let stacked = AnalyticsCrashMapper.crash(callStackJSON: json)
        guard case .string(let stack) = stacked.props["stack"] else {
            Issue.record("expected stack string")
            return
        }
        #expect(stack.count == AnalyticsCrashMapper.maxStackLength)
    }

    @Test func crashMapper_flattensAttributedThreadStack() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "callStacks": [
                [
                    "threadAttributed": false,
                    "callStackRootFrames": [
                        ["binaryName": "Other", "offsetIntoBinaryTextSegment": 1]
                    ]
                ],
                [
                    "threadAttributed": true,
                    "callStackRootFrames": [
                        [
                            "binaryName": "libsystem_kernel",
                            "offsetIntoBinaryTextSegment": 16,
                            "subFrames": [
                                [
                                    "binaryName": "libswiftCore",
                                    "offsetIntoBinaryTextSegment": 4095,
                                    "subFrames": [
                                        [
                                            "binaryName": "AirBook",
                                            "offsetIntoBinaryTextSegment": 6699
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ])
        let stack = try #require(AnalyticsCrashMapper.flattenStack(json))
        #expect(stack == "AirBook+0x1a2b; libswiftCore+0xfff; libsystem_kernel+0x10")
        #expect(!stack.contains("Other+"))
    }

    @Test func httpCall_omitsDurationWhenTimedOut() {
        let props = AnalyticsHTTP.makeProps(
            endpoint: "api.login",
            statusCode: nil,
            durationMs: 1_200,
            timedOut: true,
            appResult: .error,
            extra: [:]
        )
        #expect(props[AnalyticsHTTP.Prop.endpoint] == .string("api.login"))
        #expect(props[AnalyticsHTTP.Prop.timedOut] == .bool(true))
        #expect(props[AnalyticsHTTP.Prop.durationMs] == nil)
        #expect(props[AnalyticsHTTP.Prop.statusCode] == nil)
        #expect(props[AnalyticsHTTP.Prop.appResult] == .string("error"))
    }

    @Test func httpCall_includesStatusDurationAndAppResult() {
        let props = AnalyticsHTTP.makeProps(
            endpoint: "contact.submit",
            statusCode: 200,
            durationMs: 84,
            timedOut: false,
            appResult: .success,
            extra: ["method": "POST"]
        )
        #expect(props[AnalyticsHTTP.Prop.statusCode] == .int(200))
        #expect(props[AnalyticsHTTP.Prop.durationMs] == .int(84))
        #expect(props[AnalyticsHTTP.Prop.timedOut] == .bool(false))
        #expect(props[AnalyticsHTTP.Prop.appResult] == .string("success"))
        #expect(props["method"] == .string("POST"))
    }

    @Test func httpCall_reservedKeysWinOverExtra() {
        let props = AnalyticsHTTP.makeProps(
            endpoint: "api.login",
            statusCode: 201,
            durationMs: 10,
            timedOut: false,
            appResult: .success,
            extra: [
                AnalyticsHTTP.Prop.endpoint: "ignored",
                AnalyticsHTTP.Prop.timedOut: true,
                AnalyticsHTTP.Prop.statusCode: 500
            ]
        )
        #expect(props[AnalyticsHTTP.Prop.endpoint] == .string("api.login"))
        #expect(props[AnalyticsHTTP.Prop.timedOut] == .bool(false))
        #expect(props[AnalyticsHTTP.Prop.statusCode] == .int(201))
    }

    @Test func httpCall_truncatesEndpoint() {
        let long = String(repeating: "a", count: 200)
        let props = AnalyticsHTTP.makeProps(
            endpoint: "  \(long)  ",
            statusCode: nil,
            durationMs: nil,
            timedOut: false,
            appResult: nil,
            extra: [:]
        )
        guard case .string(let endpoint) = props[AnalyticsHTTP.Prop.endpoint] else {
            Issue.record("expected endpoint string")
            return
        }
        #expect(endpoint.count == 128)
    }

    @Test func httpCall_detectsURLTimeout() {
        #expect(AnalyticsHTTP.isTimeout(URLError(.timedOut)))
        #expect(!AnalyticsHTTP.isTimeout(URLError(.notConnectedToInternet)))
        #expect(AnalyticsHTTP.isTimeout(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    @Test func httpCall_readsJSONStatus() throws {
        let errorBody = try JSONSerialization.data(withJSONObject: ["status": "error"])
        #expect(AnalyticsHTTPAppResult.fromJSONStatus(errorBody) == .error)

        let okBody = try JSONSerialization.data(withJSONObject: ["status": "ok"])
        #expect(AnalyticsHTTPAppResult.fromJSONStatus(okBody) == .success)

        let boolBody = try JSONSerialization.data(withJSONObject: ["ok": false])
        #expect(AnalyticsHTTPAppResult.fromJSONStatus(boolBody) == .error)

        let unknown = try JSONSerialization.data(withJSONObject: ["hello": "world"])
        #expect(AnalyticsHTTPAppResult.fromJSONStatus(unknown) == nil)
    }

    @Test func httpCall_logOnlyOnErrorSkipsSuccess() {
        #expect(
            AnalyticsHTTP.shouldLog(
                logOnlyOnError: true,
                statusCode: 200,
                timedOut: false,
                appResult: .success
            ) == false
        )
        #expect(
            AnalyticsHTTP.shouldLog(
                logOnlyOnError: true,
                statusCode: 200,
                timedOut: false,
                appResult: nil
            ) == false
        )
        #expect(
            AnalyticsHTTP.shouldLog(
                logOnlyOnError: false,
                statusCode: 200,
                timedOut: false,
                appResult: .success
            )
        )
    }

    @Test func httpCall_logOnlyOnErrorKeepsFailures() {
        #expect(
            AnalyticsHTTP.shouldLog(
                logOnlyOnError: true,
                statusCode: 404,
                timedOut: false,
                appResult: nil
            )
        )
        #expect(
            AnalyticsHTTP.shouldLog(
                logOnlyOnError: true,
                statusCode: 200,
                timedOut: false,
                appResult: .error
            )
        )
        #expect(
            AnalyticsHTTP.shouldLog(
                logOnlyOnError: true,
                statusCode: nil,
                timedOut: true,
                appResult: .error
            )
        )
    }
}
