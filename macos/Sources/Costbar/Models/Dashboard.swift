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

    struct TokenUsage: Sendable {
        let period: Period
        let inputTokens: UInt64
        let outputTokens: UInt64
        let cacheReadTokens: UInt64
        let cacheCreationTokens: UInt64
        let reasoningTokens: UInt64
        let source: String
        let updatedAtUnix: Int64

        var totalTokens: UInt64 {
            [inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, reasoningTokens]
                .reduce(0) { partial, value in
                    let (sum, overflow) = partial.addingReportingOverflow(value)
                    return overflow ? .max : sum
                }
        }
    }

    struct TokenUsageWindow: Identifiable, Sendable {
        let id: String
        let label: String
        let period: Period
        let inputTokens: UInt64
        let outputTokens: UInt64
        let cacheReadTokens: UInt64
        let cacheCreationTokens: UInt64
        let reasoningTokens: UInt64

        var totalTokens: UInt64 {
            [inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, reasoningTokens]
                .reduce(0) { partial, value in
                    let (sum, overflow) = partial.addingReportingOverflow(value)
                    return overflow ? .max : sum
                }
        }
    }

    struct ProviderSummary: Sendable {
        enum Status: String, Sendable {
            case available
            case notConfigured = "not_configured"
            case unavailable
        }

        let id: String
        let displayName: String
        let kind: String
        let status: Status
        let errorMessage: String?
        let currency: String
        let currentCostMicros: Int64
        let projectedCostMicros: Int64?
        let creditRemainingMicros: Int64?
        let contributesToTotals: Bool
        let updatedAtUnix: Int64

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
