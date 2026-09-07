import CloudKit
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct UsageTimeline: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, snapshot: UsageCache.read()))
    }
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<UsageEntry>) -> Void) {
        Task {
            var snapshot = UsageCache.read()
            do {
                snapshot = try await UsageCloud().fetch()
                try UsageCache.write(snapshot)
            } catch let error as CKError where error.code == .notAuthenticated {
                snapshot = nil
                try? UsageCache.write(nil)
            } catch { /* Keep the original timestamp on cached data when offline. */ }
            let now = Date.now
            let entries = (snapshot?.timelineDates(from: now) ?? [now]).map {
                UsageEntry(date: $0, snapshot: snapshot)
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
        }
    }
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var isHomeScreen: Bool { family == .systemSmall || family == .systemMedium }

    private func quotaTitle(_ quota: UsageSnapshot.Quota) -> String {
        let parts = quota.label.components(separatedBy: " · ")
        guard parts.count > 2, let provider = parts.first, let window = parts.last else { return quota.label }
        return "\(provider) · \(window)"
    }

    private var highestQuota: UsageSnapshot.Quota? {
        entry.snapshot?.highestActiveQuota(at: entry.date)
    }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryCircular:
                    if let quota = highestQuota {
                        Gauge(value: min(quota.usedPercent, 100), in: 0...100) {
                            Text("Usage")
                        } currentValueLabel: { Text("\(quota.usedPercent.formatted(.number.precision(.fractionLength(0))))%") }
                        .gaugeStyle(.accessoryCircular)
                        .accessibilityLabel("\(quota.label), \(quota.usedPercent.formatted(.number.precision(.fractionLength(0)))) percent used")
                    } else { Image(systemName: snapshot.isStale(at: entry.date) ? "clock.badge.exclamationmark" : "dollarsign.circle") }
                case .accessoryInline:
                    Text("\(snapshot.isStale(at: entry.date) ? "Stale" : "Costbar") · \(snapshot.totals.first?.formatted ?? "No billing data")")
                case .accessoryRectangular:
                    VStack(alignment: .leading, spacing: 4) {
                        if let quota = highestQuota {
                            Text(quotaTitle(quota)).font(.caption.weight(.semibold)).lineLimit(1)
                            Text("\(quota.usedPercent.formatted(.number.precision(.fractionLength(0))))% used")
                                .font(.headline).monospacedDigit()
                            ProgressView(value: min(quota.usedPercent, 100), total: 100)
                        } else {
                            Text("Costbar · Month to date").font(.caption.weight(.semibold)).lineLimit(1)
                            Text(snapshot.totals.first?.formatted ?? "No billing data")
                                .font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        }
                        HStack(spacing: 4) {
                            if snapshot.isStale(at: entry.date) { Image(systemName: "clock.badge.exclamationmark") }
                            Text("Synced")
                            Text(snapshot.generatedAt, style: .relative)
                        }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                default:
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Costbar").font(.caption.weight(.semibold))
                            Spacer()
                            if snapshot.isStale(at: entry.date) { Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange) }
                        }
                        Text(snapshot.totals.first?.formatted ?? "Usage")
                            .font(.system(.title, design: .rounded, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                        if let quota = highestQuota {
                            HStack {
                                Text(quotaTitle(quota)).lineLimit(1)
                                Spacer()
                                Text("\(quota.usedPercent.formatted(.number.precision(.fractionLength(0))))%")
                            }.font(.caption)
                            ProgressView(value: min(quota.usedPercent, 100), total: 100).tint(quota.usedPercent >= 80 ? .orange : .blue)
                        }
                        Text(snapshot.generatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                switch family {
                case .accessoryCircular:
                    Image(systemName: "chart.bar.xaxis")
                        .accessibilityLabel("Costbar. Open the app to sync usage.")
                case .accessoryInline:
                    Text("Costbar · Open app to sync")
                default:
                    VStack(alignment: .leading) {
                        Label("Costbar", systemImage: "chart.bar.xaxis").font(.headline)
                        Text("Open Costbar to sync usage").font(.caption)
                    }
                }
            }
        }
        .environment(\.colorScheme, isHomeScreen ? .dark : colorScheme)
        .containerBackground(for: .widget) { Color(red: 0.106, green: 0.106, blue: 0.118) }
        .widgetURL(URL(string: "costbar://usage"))
    }
}

@main
struct CostbarWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CostbarUsage", provider: UsageTimeline()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Live usage")
        .description("Latest costs and highest quota usage from your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
