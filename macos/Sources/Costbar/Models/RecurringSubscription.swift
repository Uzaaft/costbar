import Foundation

struct RecurringSubscription: Codable, Identifiable, Equatable, Sendable {
    enum Cadence: String, Codable, CaseIterable, Sendable {
        case monthly
        case quarterly
        case yearly

        var title: String { rawValue.capitalized }
    }

    var id: String
    var name: String
    /// Decimal amount in the selected currency. Zig performs the authoritative
    /// fixed-point parsing and cadence normalization.
    var amount: String
    var currency: String
    var cadence: Cadence

    static func empty() -> RecurringSubscription {
        .init(
            id: UUID().uuidString.lowercased(),
            name: "",
            amount: "",
            currency: "USD",
            cadence: .monthly
        )
    }
}

enum SubscriptionSettings {
    private static let key = "recurring-subscriptions-v1"

    static func load(defaults: UserDefaults = .standard) -> [RecurringSubscription] {
        guard let data = defaults.data(forKey: key),
              let subscriptions = try? JSONDecoder().decode(
                  [RecurringSubscription].self,
                  from: data
              )
        else {
            return []
        }
        return subscriptions
    }

    static func save(
        _ subscriptions: [RecurringSubscription],
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        defaults.set(data, forKey: key)
    }

    static func snapshotData(
        from subscriptions: [RecurringSubscription]
    ) throws -> Data {
        let active = subscriptions.compactMap { subscription -> RecurringSubscription? in
            var normalized = subscription
            normalized.name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.amount = normalized.amount.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.currency = normalized.currency
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !normalized.name.isEmpty, !normalized.amount.isEmpty else { return nil }
            return normalized
        }
        return try JSONEncoder().encode(["subscriptions": active])
    }
}
