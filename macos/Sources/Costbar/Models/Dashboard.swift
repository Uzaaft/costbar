import Foundation

struct Dashboard: Decodable, Sendable {
    struct Period: Codable, Sendable {
        let startUnix: Int64
        let endExclusiveUnix: Int64

        enum CodingKeys: String, CodingKey {
            case startUnix = "start_unix"
            case endExclusiveUnix = "end_exclusive_unix"
        }

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

    struct CurrencyTotal: Decodable, Sendable {
        let currency: String
        let currentCostMicros: Int64
        let projectedCostMicros: Int64?
        let creditRemainingMicros: Int64?
        let projectionComplete: Bool
        let creditComplete: Bool

        enum CodingKeys: String, CodingKey {
            case currency
            case currentCostMicros = "current_cost_micros"
            case projectedCostMicros = "projected_cost_micros"
            case creditRemainingMicros = "credit_remaining_micros"
            case projectionComplete = "projection_complete"
            case creditComplete = "credit_complete"
        }
    }

    struct ProviderReport: Decodable, Identifiable, Sendable {
        let summary: ProviderSummary
        let resources: [Resource]
        let lineItems: [CostLineItem]
        let allowanceWindows: [AllowanceWindow]
        let tokenUsage: TokenUsage?
        let financials: [FinancialSummary]

        var id: String { summary.id }

        enum CodingKeys: String, CodingKey {
            case summary
            case resources
            case lineItems = "line_items"
            case allowanceWindows = "allowance_windows"
            case tokenUsage = "token_usage"
            case financials
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            summary = try container.decode(ProviderSummary.self, forKey: .summary)
            resources = try container.decodeIfPresent([Resource].self, forKey: .resources) ?? []
            lineItems = try container.decodeIfPresent([CostLineItem].self, forKey: .lineItems) ?? []
            allowanceWindows = try container.decodeIfPresent(
                [AllowanceWindow].self,
                forKey: .allowanceWindows
            ) ?? []
            tokenUsage = try container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
            financials = try container.decodeIfPresent(
                [FinancialSummary].self,
                forKey: .financials
            ) ?? []
        }
    }

    struct FinancialSummary: Decodable, Sendable {
        let currency: String
        let currentCostMicros: Int64
        let projectedCostMicros: Int64?
        let creditRemainingMicros: Int64?

        enum CodingKeys: String, CodingKey {
            case currency
            case currentCostMicros = "current_cost_micros"
            case projectedCostMicros = "projected_cost_micros"
            case creditRemainingMicros = "credit_remaining_micros"
        }
    }

    struct AllowanceWindow: Decodable, Identifiable, Sendable {
        let id: String
        let label: String
        let usedPercent: Double
        let resetsAtUnix: Int64?
        let detail: String?

        enum CodingKeys: String, CodingKey {
            case id
            case label
            case usedPercent = "used_percent"
            case resetsAtUnix = "resets_at_unix"
            case detail
        }
    }

    struct TokenUsage: Decodable, Sendable {
        let period: Period
        let inputTokens: UInt64
        let outputTokens: UInt64
        let cacheReadTokens: UInt64
        let cacheCreationTokens: UInt64
        let reasoningTokens: UInt64
        let source: String
        let updatedAtUnix: Int64

        enum CodingKeys: String, CodingKey {
            case period
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case cacheCreationTokens = "cache_creation_tokens"
            case reasoningTokens = "reasoning_tokens"
            case source
            case updatedAtUnix = "updated_at_unix"
        }

        var totalTokens: UInt64 {
            [inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, reasoningTokens]
                .reduce(0) { partial, value in
                    let (sum, overflow) = partial.addingReportingOverflow(value)
                    return overflow ? .max : sum
                }
        }
    }

    struct ProviderSummary: Decodable, Sendable {
        enum Status: String, Decodable, Sendable {
            case available
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

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case kind
            case status
            case errorMessage = "error_message"
            case currency
            case currentCostMicros = "current_cost_micros"
            case projectedCostMicros = "projected_cost_micros"
            case creditRemainingMicros = "credit_remaining_micros"
            case contributesToTotals = "contributes_to_totals"
            case updatedAtUnix = "updated_at_unix"
        }
    }

    struct Resource: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
        let kind: String
        let status: String
        let quantity: UInt64
    }

    struct CostLineItem: Decodable, Identifiable, Sendable {
        let id: String
        let description: String
        /// Group this item belongs to, usually the billed product ("Droplets").
        let service: String
        let amountMicros: Int64
        let currency: String?
        /// Secondary label, e.g. "744 Hours · prod" or "monthly · Paid".
        let detail: String?

        enum CodingKeys: String, CodingKey {
            case id
            case description
            case service
            case amountMicros = "amount_micros"
            case currency
            case detail
        }
    }

    let period: Period
    let generatedAtUnix: Int64
    let totals: [CurrencyTotal]
    let providers: [ProviderReport]

    enum CodingKeys: String, CodingKey {
        case period
        case generatedAtUnix = "generated_at_unix"
        case totals
        case providers
    }

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
