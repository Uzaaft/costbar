import Foundation

struct Dashboard: Sendable {
    struct Period: Sendable {
        let startUnix: Int64
        let endExclusiveUnix: Int64

        static func currentMonth(now: Date = .now, calendar: Calendar = .current) -> Period {
            let interval = calendar.dateInterval(of: .month, for: now)
            let start = interval?.start ?? now
            let end = interval?.end ?? now.addingTimeInterval(1)
            return Period(
                startUnix: Int64(start.timeIntervalSince1970),
                endExclusiveUnix: Int64(end.timeIntervalSince1970)
            )
        }
    }

    struct CurrencyTotal: Sendable {
        let currency: String
        let currentCostMicros: Int64
        let projectedCostMicros: Int64?
        let creditRemainingMicros: Int64?
        let projectionComplete: Bool
        let creditComplete: Bool
    }

    struct ProviderReport: Identifiable, Sendable {
        let summary: ProviderSummary
        let resources: [Resource]
        let lineItems: [CostLineItem]
        let allowanceWindows: [AllowanceWindow]
        let tokenUsage: TokenUsage?
        let tokenUsageWindows: [TokenUsageWindow]
        let tokenUsageSeries: [TokenUsageSeries]
        let spendSeries: [SpendSeries]
        let financials: [FinancialSummary]

        var id: String { summary.id }
    }

    struct FinancialSummary: Sendable {
        let currency: String
        let currentCostMicros: Int64
        let projectedCostMicros: Int64?
        let creditRemainingMicros: Int64?
    }

    struct AllowanceWindow: Identifiable, Sendable {
        let id: String
        let label: String
        let usedPercent: Double
        let resetsAtUnix: Int64?
        let detail: String?
    }

    struct TokenUsage: TokenCounted, Sendable {
        let period: Period
        let inputTokens: UInt64
        let outputTokens: UInt64
        let cacheReadTokens: UInt64
        let cacheCreationTokens: UInt64
        let reasoningTokens: UInt64
        let source: String
        let updatedAtUnix: Int64
    }

    struct TokenUsageWindow: TokenCounted, Identifiable, Sendable {
        let id: String
        let label: String
        let period: Period
        let inputTokens: UInt64
        let outputTokens: UInt64
        let cacheReadTokens: UInt64
        let cacheCreationTokens: UInt64
        let reasoningTokens: UInt64
    }

    struct TokenUsageSeries: Identifiable, Sendable {
        let id: String
        let label: String
        let period: Period
        let buckets: [TokenUsageBucket]
    }

    struct TokenUsageBucket: TokenCounted, Identifiable, Sendable {
        let period: Period
        let inputTokens: UInt64
        let outputTokens: UInt64
        let cacheReadTokens: UInt64
        let cacheCreationTokens: UInt64
        let reasoningTokens: UInt64

        var id: Int64 { period.startUnix }
    }

    struct SpendSeries: Identifiable, Sendable {
        let id: String
        let label: String
        let currency: String
        let period: Period
        let buckets: [SpendBucket]
    }

    struct SpendBucket: Identifiable, Sendable {
        let period: Period
        let amountMicros: Int64
        let usageQuantity: UInt64

        var id: Int64 { period.startUnix }
    }

    struct ProviderSummary: Sendable {
        enum Status: String, Sendable {
            case available
            case notConfigured = "not_configured"
            case unavailable
        }

        let id: String
        let displayName: String
        /// Stable provider type ID. This differs from `id` when more than one
        /// account of the same provider type is configured.
        let sourceID: String?
        let kind: String
        let status: Status
        let errorMessage: String?
        let currency: String
        let currentCostMicros: Int64
        let projectedCostMicros: Int64?
        let creditRemainingMicros: Int64?
        let contributesToTotals: Bool
        let updatedAtUnix: Int64

        var providerTypeID: String { sourceID ?? id }

        init(
            id: String,
            displayName: String,
            sourceID: String? = nil,
            kind: String,
            status: Status,
            errorMessage: String?,
            currency: String,
            currentCostMicros: Int64,
            projectedCostMicros: Int64?,
            creditRemainingMicros: Int64?,
            contributesToTotals: Bool,
            updatedAtUnix: Int64
        ) {
            self.id = id
            self.displayName = displayName
            self.sourceID = sourceID
            self.kind = kind
            self.status = status
            self.errorMessage = errorMessage
            self.currency = currency
            self.currentCostMicros = currentCostMicros
            self.projectedCostMicros = projectedCostMicros
            self.creditRemainingMicros = creditRemainingMicros
            self.contributesToTotals = contributesToTotals
            self.updatedAtUnix = updatedAtUnix
        }
    }

    struct Resource: Identifiable, Sendable {
        let id: String
        let name: String
        let kind: String
        let status: String
        let quantity: UInt64
    }

    struct CostLineItem: Identifiable, Sendable {
        let id: String
        let description: String
        /// Group this item belongs to, usually the billed product ("Droplets").
        let service: String
        let amountMicros: Int64
        let currency: String?
        /// Secondary label, e.g. "744 Hours · prod" or "monthly · Paid".
        let detail: String?
    }

    let period: Period
    let generatedAtUnix: Int64
    let totals: [CurrencyTotal]
    let providers: [ProviderReport]

    var primaryTotal: CurrencyTotal? {
        totals.first(where: { $0.currency == "USD" }) ?? totals.first
    }
}

/// Anything the core reports token counts for. Every conforming type totals the
/// same five classes, so `totalTokens` is defined once here.
protocol TokenCounted {
    var inputTokens: UInt64 { get }
    var outputTokens: UInt64 { get }
    var cacheReadTokens: UInt64 { get }
    var cacheCreationTokens: UInt64 { get }
    var reasoningTokens: UInt64 { get }
}

extension TokenCounted {
    var totalTokens: UInt64 {
        [inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, reasoningTokens]
            .saturatingSum
    }
}

extension Dashboard.AllowanceWindow {
    /// "62%" or "62.5%" — a fraction digit only when it carries information.
    var usedPercentText: String {
        let precision = usedPercent.rounded() == usedPercent ? 0 : 1
        let percent = usedPercent.formatted(
            .number.precision(.fractionLength(precision)).locale(MoneyFormat.locale)
        )
        return "\(percent)%"
    }
}

extension Dashboard.ProviderSummary {
    /// A copy that belongs to a specific configured account. Only the identity
    /// changes; every cost and status value still comes from the core.
    func identified(id: String, displayName: String, sourceID: String) -> Self {
        .init(
            id: id,
            displayName: displayName,
            sourceID: sourceID,
            kind: kind,
            status: status,
            errorMessage: errorMessage,
            currency: currency,
            currentCostMicros: currentCostMicros,
            projectedCostMicros: projectedCostMicros,
            creditRemainingMicros: creditRemainingMicros,
            contributesToTotals: contributesToTotals,
            updatedAtUnix: updatedAtUnix
        )
    }
}

extension Dashboard.ProviderReport {
    /// The same payload under a different identity.
    func replacingSummary(_ summary: Dashboard.ProviderSummary) -> Self {
        .init(
            summary: summary,
            resources: resources,
            lineItems: lineItems,
            allowanceWindows: allowanceWindows,
            tokenUsage: tokenUsage,
            tokenUsageWindows: tokenUsageWindows,
            tokenUsageSeries: tokenUsageSeries,
            spendSeries: spendSeries,
            financials: financials
        )
    }

    /// A report with no data yet, used for accounts that have not refreshed.
    static func placeholder(summary: Dashboard.ProviderSummary) -> Self {
        .init(
            summary: summary,
            resources: [],
            lineItems: [],
            allowanceWindows: [],
            tokenUsage: nil,
            tokenUsageWindows: [],
            tokenUsageSeries: [],
            spendSeries: [],
            financials: []
        )
    }
}

enum MoneyFormat {
    /// Costbar always renders amounts in US notation ("$80.39"), independent of
    /// the machine locale, so the menu bar title stays narrow and stable.
    static let locale = Locale(identifier: "en_US")
}

extension Int64 {
    private var amount: Double { Double(self) / 1_000_000 }

    func currencyText(code: String) -> String {
        amount.formatted(
            .currency(code: code)
                .precision(.fractionLength(2))
                .locale(MoneyFormat.locale)
        )
    }

    /// Bare number, no currency symbol — used where the currency is already implied.
    func decimalText() -> String {
        amount.formatted(
            .number
                .precision(.fractionLength(2))
                .locale(MoneyFormat.locale)
        )
    }
}

/// A currency amount split so the symbol and cents can be de-emphasised next to
/// the whole-unit digits.
struct CurrencyDisplay {
    let symbol: String
    let whole: String
    let fraction: String

    init(micros: Int64, code: String) {
        let text = micros.currencyText(code: code)
        let firstDigit = text.firstIndex(where: \.isNumber) ?? text.startIndex
        symbol = text[..<firstDigit].trimmingCharacters(in: .whitespaces)

        let number = text[firstDigit...]
        if let separator = number.lastIndex(of: ".") {
            whole = String(number[..<separator])
            fraction = String(number[separator...])
        } else {
            whole = String(number)
            fraction = ""
        }
    }
}
