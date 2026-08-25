import Foundation
import MetricKit

/// Strongly retained MetricKit subscriber. `MXMetricManager` only keeps a weak reference.
final class AnalyticsMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private var didStart = false

    func start() {
        guard !didStart else { return }
        didStart = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let events = payloads.flatMap(Self.mappedEvents(from:))
        guard !events.isEmpty else { return }
        Task { @MainActor in
            for event in events {
                AnalyticsClient.shared.track(name: event.name, props: event.props)
            }
        }
    }

    private static func mappedEvents(from payload: MXDiagnosticPayload) -> [AnalyticsCrashMapper.MappedEvent] {
        var events: [AnalyticsCrashMapper.MappedEvent] = []
        for crash in payload.crashDiagnostics ?? [] {
            events.append(
                AnalyticsCrashMapper.crash(
                    exceptionType: crash.exceptionType?.intValue,
                    exceptionCode: crash.exceptionCode?.intValue,
                    signal: crash.signal?.intValue,
                    reason: crash.terminationReason,
                    version: crash.applicationVersion,
                    callStackJSON: crash.callStackTree.jsonRepresentation()
                )
            )
        }
        for hang in payload.hangDiagnostics ?? [] {
            events.append(
                AnalyticsCrashMapper.hang(
                    hangMilliseconds: hangMilliseconds(hang.hangDuration),
                    version: hang.applicationVersion,
                    callStackJSON: hang.callStackTree.jsonRepresentation()
                )
            )
        }
        return events
    }

    private static func hangMilliseconds(_ duration: Measurement<UnitDuration>) -> Int {
        Int(duration.converted(to: .milliseconds).value.rounded())
    }
}
