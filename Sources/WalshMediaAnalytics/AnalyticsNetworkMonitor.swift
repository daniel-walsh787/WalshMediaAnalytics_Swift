import Foundation
import Network

/// `NWPathMonitor` wrapper. Offline means no ingest attempts; coming online triggers a flush.
final class AnalyticsNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "WalshMediaAnalytics.path")
    private let lock = NSLock()
    private var available = false
    private var didStart = false

    var onAvailable: (@Sendable () -> Void)?

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathChanged(path)
        }
        monitor.start(queue: queue)
    }

    private func pathChanged(_ path: NWPath) {
        let nowAvailable = path.status == .satisfied
        let becameAvailable: Bool
        lock.lock()
        becameAvailable = nowAvailable && !available
        available = nowAvailable
        lock.unlock()
        if becameAvailable {
            onAvailable?()
        }
    }
}
