import Foundation

/// Drives the per-source refresh timers. Each source has its own interval, and
/// sources whose deadlines land together are refreshed in one batch.
@MainActor
enum RefreshPolling {
    static func run(
        schedule: PollingSchedule,
        action: @escaping (Set<String>) async -> Void
    ) async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var deadlines = schedule.intervals.mapValues { interval in
            startedAt.advanced(by: interval)
        }

        while !Task.isCancelled, let nextDeadline = deadlines.values.min() {
            do {
                try await clock.sleep(until: nextDeadline)
            } catch {
                return
            }

            let now = clock.now
            let dueSources = Set(deadlines.compactMap { sourceID, deadline in
                deadline <= now ? sourceID : nil
            })
            guard !dueSources.isEmpty else { continue }

            await action(dueSources)
            let completedAt = clock.now
            for sourceID in dueSources {
                guard let interval = schedule.intervals[sourceID] else { continue }
                deadlines[sourceID] = completedAt.advanced(by: interval)
            }
        }
    }
}
