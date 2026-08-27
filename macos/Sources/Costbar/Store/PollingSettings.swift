import Foundation

/// Everything Costbar refreshes on a timer: one entry per provider type plus
/// one per locally tracked coding agent.
struct PollingSource: Identifiable, Sendable {
    let id: String
    let displayName: String

    static let all: [PollingSource] =
        ProviderAccountType.allCases.map {
            .init(id: $0.sourceID, displayName: $0.displayName)
        } + LocalSource.allCases.map {
            .init(id: $0.sourceID, displayName: $0.displayName)
        }
}

struct PollingSchedule: Sendable {
    let intervals: [String: Duration]

    static func uniform(_ interval: Duration) -> PollingSchedule {
        .init(intervals: Dictionary(
            uniqueKeysWithValues: PollingSource.all.map { ($0.id, interval) }
        ))
    }
}

enum PollingSettings {
    struct IntervalOption: Identifiable, Sendable {
        let seconds: Int
        let label: String

        var id: Int { seconds }
    }

    static let defaultIntervalSeconds = 300
    static let intervalOptions: [IntervalOption] = [
        .init(seconds: 60, label: "1 minute"),
        .init(seconds: 300, label: "5 minutes"),
        .init(seconds: 900, label: "15 minutes"),
        .init(seconds: 1_800, label: "30 minutes"),
        .init(seconds: 3_600, label: "1 hour"),
        .init(seconds: 21_600, label: "6 hours"),
        .init(seconds: 43_200, label: "12 hours"),
        .init(seconds: 86_400, label: "24 hours"),
    ]

    private static let defaultIntervalKey = "polling-default-seconds-v1"
    private static let overridesKey = "polling-source-overrides-v1"

    static func defaultInterval(defaults: UserDefaults = .standard) -> Int {
        validated(defaults.integer(forKey: defaultIntervalKey)) ?? defaultIntervalSeconds
    }

    static func overrides(defaults: UserDefaults = .standard) -> [String: Int] {
        let knownSources = Set(PollingSource.all.map(\.id))
        return (defaults.dictionary(forKey: overridesKey) ?? [:]).reduce(into: [:]) { result, entry in
            guard knownSources.contains(entry.key),
                  let number = entry.value as? NSNumber,
                  let seconds = validated(number.intValue)
            else { return }
            result[entry.key] = seconds
        }
    }

    static func save(
        defaultInterval: Int,
        overrides: [String: Int],
        defaults: UserDefaults = .standard
    ) {
        let fallback = validated(defaultInterval) ?? defaultIntervalSeconds
        let knownSources = Set(PollingSource.all.map(\.id))
        let sanitized = overrides.reduce(into: [String: Int]()) { result, entry in
            guard knownSources.contains(entry.key), let seconds = validated(entry.value) else {
                return
            }
            result[entry.key] = seconds
        }
        defaults.set(fallback, forKey: defaultIntervalKey)
        defaults.set(sanitized, forKey: overridesKey)
    }

    static func schedule(defaults: UserDefaults = .standard) -> PollingSchedule {
        let fallback = defaultInterval(defaults: defaults)
        let sourceOverrides = overrides(defaults: defaults)
        return .init(intervals: Dictionary(
            uniqueKeysWithValues: PollingSource.all.map { source in
                (source.id, .seconds(sourceOverrides[source.id] ?? fallback))
            }
        ))
    }

    static func label(for seconds: Int) -> String {
        intervalOptions.first(where: { $0.seconds == seconds })?.label ?? "\(seconds) seconds"
    }

    private static func validated(_ seconds: Int) -> Int? {
        intervalOptions.contains(where: { $0.seconds == seconds }) ? seconds : nil
    }
}
