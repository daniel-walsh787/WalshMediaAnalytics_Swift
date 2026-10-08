import Foundation

/// Persisted visible-screen trail joined onto MetricKit crash and hang events.
enum AnalyticsDiagnosticContext {
    static let maxEntries = 30
    static let maxReported = 5
    static let maxScreenLength = 128

    struct Entry: Equatable, Sendable {
        var screen: String
        var at: Date
    }

    private static let defaultsKey = "analytics.diagnosticScreens"
    private static let lock = NSLock()

    static func record(
        screen: String,
        at: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard let screen = normalized(screen) else { return }
        lock.lock()
        defer { lock.unlock() }
        var entries = load(defaults: defaults)
        if entries.last?.screen == screen { return }
        entries.append(Entry(screen: screen, at: at))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        save(entries, defaults: defaults)
    }

    /// Last `maxReported` screens with `at <= end`, oldest first. Empty when none match.
    static func screensJSON(
        atOrBefore end: Date,
        defaults: UserDefaults = .standard
    ) -> String? {
        lock.lock()
        let entries = load(defaults: defaults)
        lock.unlock()
        let matching = entries.filter { $0.at <= end }
        guard !matching.isEmpty else { return nil }
        let tail = matching.suffix(maxReported)
        return encode(Array(tail))
    }

    static func resetForTests(defaults: UserDefaults) {
        lock.lock()
        defaults.removeObject(forKey: defaultsKey)
        lock.unlock()
    }

    private static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        if trimmed.count <= maxScreenLength { return trimmed }
        return String(trimmed.prefix(maxScreenLength))
    }

    private static func load(defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let rows = try? JSONDecoder().decode([StoredEntry].self, from: data)
        else { return [] }
        return rows.compactMap { row in
            guard let screen = normalized(row.screen), let at = row.at else { return nil }
            return Entry(screen: screen, at: at)
        }
    }

    private static func save(_ entries: [Entry], defaults: UserDefaults) {
        let rows = entries.map { StoredEntry(screen: $0.screen, at: $0.at) }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func encode(_ entries: [Entry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let objects = entries.map { entry -> String in
            let screen = jsonString(entry.screen)
            let at = formatter.string(from: entry.at)
            return "{\"screen\":\(screen),\"at\":\"\(at)\"}"
        }
        return "[" + objects.joined(separator: ",") + "]"
    }

    private static func jsonString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.append(Character(scalar))
                }
            }
        }
        escaped += "\""
        return escaped
    }
}

private struct StoredEntry: Codable {
    var screen: String
    var at: Date?
}
