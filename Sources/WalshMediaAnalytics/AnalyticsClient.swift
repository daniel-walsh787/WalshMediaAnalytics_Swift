import Foundation

/// Batches events locally and POSTs to `/v1/ingest`. Flush when 20 events are queued,
/// 60s after the last successful flush, or when the app backgrounds.
@MainActor
final class AnalyticsClient {
    static let shared = AnalyticsClient()

    private static let flushQueueThreshold = 20
    private static let flushInterval: TimeInterval = 60

    private var configuration: AnalyticsConfiguration?
    private var pending: [AnalyticsQueuedEvent] = []
    private var flushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var lastSuccessfulFlushAt: Date?
    private var retryDelay: TimeInterval = 15
    private var isFlushing = false
    private var didStart = false
    private var cachedUserID: String?
    private let metricKitSubscriber = AnalyticsMetricKitSubscriber()
    private let network = AnalyticsNetworkMonitor()

    private init() {}

    private var bufferDefaultsKey: String {
        "\(appId).analytics.pendingEvents"
    }

    private var userIDDefaultsKey: String {
        "\(appId).analytics.userID"
    }

    private var appId: String {
        configuration?.appId ?? "app"
    }

    func start(_ configuration: AnalyticsConfiguration) {
        guard !configuration.appId.isEmpty else { return }
        self.configuration = configuration
        guard !didStart else { return }
        didStart = true
        pending = loadBuffer()
        cachedUserID = AnalyticsIngestCodec.normalizedUserID(
            UserDefaults.standard.string(forKey: userIDDefaultsKey)
        )
        if configuration.reportsCrashes {
            metricKitSubscriber.start()
        }
        network.onAvailable = { [weak self] in
            Task { @MainActor in
                await self?.flush(reason: .networkAvailable)
            }
        }
        network.start()
        scheduleFlushIfNeeded()
        Task { _ = await resolveUserID() }
    }

    func track(name: String, props: [String: AnalyticsPropValue] = [:]) {
        guard configuration != nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(trimmed.count) else { return }

        let event = AnalyticsQueuedEvent(
            id: UUID().uuidString,
            name: trimmed,
            ts: Int(Date().timeIntervalSince1970),
            props: props
        )
        pending.append(event)
        persistBuffer()
        scheduleFlushIfNeeded()
        if pending.count >= Self.flushQueueThreshold {
            Task { await flush(reason: .queueSize) }
        }
    }

    func flushNow() {
        Task { await flush(reason: .background) }
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.flushInterval))
            self?.timerFired()
        }
    }

    private func timerFired() {
        flushTask = nil
        Task { await flush(reason: .timer) }
        if !pending.isEmpty {
            scheduleFlushIfNeeded()
        }
    }

    private enum FlushReason {
        case queueSize
        case timer
        case background
        case networkAvailable
    }

    private func flush(reason: FlushReason) async {
        guard !isFlushing else { return }
        _ = reason
        guard let configuration, configuration.isConfigured else { return }
        guard let url = configuration.ingestURL else { return }
        guard !pending.isEmpty else { return }
        guard network.isAvailable else { return }

        isFlushing = true
        defer { isFlushing = false }

        let env = await configuration.environment()
        let userID = await resolveUserID()
        let deviceID = AnalyticsInstallID.current(appId: configuration.appId)

        while !pending.isEmpty {
            guard network.isAvailable else { return }

            let prepared: (batch: [AnalyticsQueuedEvent], body: Data)
            do {
                guard let next = try encodeNextBatch(
                    configuration: configuration,
                    env: env,
                    deviceID: deviceID,
                    userID: userID
                ) else {
                    return
                }
                prepared = next
            } catch {
                print("[WalshMediaAnalytics] encode failed: \(error.localizedDescription)")
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(configuration.appId, forHTTPHeaderField: "X-App-Id")
            request.setValue(
                AnalyticsIngestCodec.signatureHex(secret: configuration.hmacSecret, body: prepared.body),
                forHTTPHeaderField: "X-Signature"
            )
            request.httpBody = prepared.body
            request.timeoutInterval = 20

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    scheduleRetry()
                    return
                }
                switch http.statusCode {
                case 202:
                    remove(ids: prepared.batch.map(\.id))
                    lastSuccessfulFlushAt = Date()
                    retryDelay = 15
                    retryTask?.cancel()
                    retryTask = nil
                case 429:
                    print("[WalshMediaAnalytics] 429 — backing off")
                    scheduleRetry()
                    return
                case 400, 401, 403:
                    print("[WalshMediaAnalytics] ingest rejected (\(http.statusCode)) — dropping batch")
                    remove(ids: prepared.batch.map(\.id))
                default:
                    print("[WalshMediaAnalytics] ingest HTTP \(http.statusCode)")
                    scheduleRetry()
                    return
                }
            } catch {
                print("[WalshMediaAnalytics] network error: \(error.localizedDescription)")
                scheduleRetry()
                return
            }
        }
    }

    private func encodeNextBatch(
        configuration: AnalyticsConfiguration,
        env: String,
        deviceID: String,
        userID: String?
    ) throws -> (batch: [AnalyticsQueuedEvent], body: Data)? {
        var count = min(pending.count, AnalyticsBatching.maxEvents)
        while count >= 1 {
            let batch = Array(pending.prefix(count))
            let body = try AnalyticsIngestCodec.encodeBody(
                platform: configuration.platform,
                env: env,
                deviceID: deviceID,
                userID: userID,
                events: batch
            )
            if let next = AnalyticsBatching.reducedCount(current: count, bodyBytes: body.count) {
                if next == count {
                    return (batch, body)
                }
                count = next
                continue
            }
            print("[WalshMediaAnalytics] dropping oversized event \(batch[0].name)")
            remove(ids: [batch[0].id])
            count = min(pending.count, AnalyticsBatching.maxEvents)
        }
        return nil
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 300)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.flush(reason: .timer)
        }
    }

    private func resolveUserID() async -> String? {
        guard let configuration else { return cachedUserID }
        if let name = AnalyticsIngestCodec.normalizedUserID(await configuration.userID()) {
            if cachedUserID != name {
                cachedUserID = name
                UserDefaults.standard.set(name, forKey: userIDDefaultsKey)
            }
            return name
        }
        return cachedUserID
    }

    private func remove(ids: [String]) {
        let drop = Set(ids)
        pending.removeAll { drop.contains($0.id) }
        persistBuffer()
    }

    private func persistBuffer() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: bufferDefaultsKey)
    }

    private func loadBuffer() -> [AnalyticsQueuedEvent] {
        guard let data = UserDefaults.standard.data(forKey: bufferDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([AnalyticsQueuedEvent].self, from: data)) ?? []
    }
}
