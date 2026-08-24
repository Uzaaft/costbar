import Foundation
import Testing
@testable import Costbar

@Test
func decodesDashboardWireFormat() throws {
    let data = Data(
        #"{"period":{"start_unix":1,"end_exclusive_unix":2},"generated_at_unix":1,"totals":[{"currency":"USD","current_cost_micros":42000000,"projected_cost_micros":50000000,"credit_remaining_micros":10000000,"projection_complete":true,"credit_complete":true}],"providers":[]}"#.utf8
    )
    let dashboard = try JSONDecoder().decode(Dashboard.self, from: data)

    #expect(dashboard.primaryTotal?.currentCostMicros == 42_000_000)
    #expect(dashboard.period.endExclusiveUnix == 2)
}

@Test
func zigBridgeHasNoProviderDataBeforeRefresh() throws {
    let core = try CostbarCore()
    let dashboard = try core.snapshot(
        period: .init(startUnix: 1, endExclusiveUnix: 2)
    )

    #expect(dashboard.providers.map(\.summary.id) == [
        "digitalocean", "cloudflare", "runpod", "vercel", "openrouter", "subscriptions",
        "codex", "claude",
        "openai-api", "anthropic-api",
        "github", "cursor",
    ])
    #expect(dashboard.providers.allSatisfy { $0.summary.status == .unavailable })
    #expect(dashboard.providers.allSatisfy { $0.resources.isEmpty })
    #expect(dashboard.totals.isEmpty)
}

@Test
func zigBridgeIngestsLiveDigitalOceanDocuments() throws {
    let core = try CostbarCore()
    try core.ingest(
        providerID: "digitalocean",
        documentID: "balance",
        data: Data(#"{"account_balance":"-10.25","month_to_date_usage":"7.50"}"#.utf8),
        receivedAt: Date(timeIntervalSince1970: 100)
    )
    try core.ingest(
        providerID: "digitalocean",
        documentID: "droplets",
        data: Data(#"{"droplets":[{"id":42,"name":"production","status":"active"}]}"#.utf8),
        receivedAt: Date(timeIntervalSince1970: 100)
    )

    let dashboard = try core.snapshot(
        period: .init(startUnix: 1, endExclusiveUnix: 200)
    )
    let digitalOcean = try #require(
        dashboard.providers.first(where: { $0.summary.id == "digitalocean" })
    )
    #expect(digitalOcean.summary.currentCostMicros == 7_500_000)
    #expect(digitalOcean.summary.creditRemainingMicros == 10_250_000)
    #expect(digitalOcean.resources.map(\.name) == ["production"])
}

@Test
func zigBridgeIngestsRunpodCostsAndCredits() throws {
    let core = try CostbarCore()
    try core.ingest(
        providerID: "runpod",
        documentID: "snapshot",
        data: Data(
            #"{"account":{"data":{"myself":{"clientBalance":18.75,"currentSpendPerHr":0.5}}},"pods":[{"amount":4.25}],"endpoints":[{"amount":2}],"networkVolumes":[{"amount":0.75}]}"#.utf8
        ),
        receivedAt: Date(timeIntervalSince1970: 100)
    )

    let dashboard = try core.snapshot(
        period: .init(startUnix: 1, endExclusiveUnix: 200)
    )
    let runpod = try #require(
        dashboard.providers.first(where: { $0.summary.id == "runpod" })
    )
    #expect(runpod.summary.currentCostMicros == 7_000_000)
    #expect(runpod.summary.creditRemainingMicros == 18_750_000)
    #expect(runpod.lineItems.map(\.service) == ["Pods", "Serverless", "Network volumes"])
}

@Test
func zigBridgeIngestsVercelFOCUSCharges() throws {
    let core = try CostbarCore()
    try core.ingest(
        providerID: "vercel",
        documentID: "charges",
        data: Data(
            """
            {"BillingCurrency":"USD","BilledCost":3.25,"ServiceName":"Functions"}
            {"BillingCurrency":"USD","BilledCost":1.50,"ServiceName":"Fast Data Transfer"}
            """.utf8
        ),
        receivedAt: Date(timeIntervalSince1970: 100)
    )

    let dashboard = try core.snapshot(
        period: .init(startUnix: 1, endExclusiveUnix: 200)
    )
    let vercel = try #require(
        dashboard.providers.first(where: { $0.summary.id == "vercel" })
    )
    #expect(vercel.summary.currentCostMicros == 4_750_000)
    #expect(vercel.lineItems.map(\.service) == ["Functions", "Fast Data Transfer"])
}

@Test
func zigBridgeIngestsOpenRouterUsageAndTokens() throws {
    let core = try CostbarCore()
    try core.ingest(
        providerID: "openrouter",
        documentID: "snapshot",
        data: Data(
            """
            {
              "key":{"data":{"usage_monthly":12.5,"limit":50}},
              "activity_period":{"start_unix":1,"end_exclusive_unix":200},
              "activity":{"data":[{
                "model":"openai/gpt",
                "provider_name":"OpenAI",
                "usage":12.5,
                "prompt_tokens":100,
                "completion_tokens":20,
                "reasoning_tokens":5
              }]}
            }
            """.utf8
        ),
        receivedAt: Date(timeIntervalSince1970: 100)
    )

    let dashboard = try core.snapshot(
        period: .init(startUnix: 1, endExclusiveUnix: 200)
    )
    let openRouter = try #require(
        dashboard.providers.first(where: { $0.summary.id == "openrouter" })
    )
    #expect(openRouter.summary.currentCostMicros == 12_500_000)
    #expect(openRouter.allowanceWindows.first?.usedPercent == 25)
    #expect(openRouter.tokenUsage?.totalTokens == 125)
}

@Test
func zigBridgeNormalizesRecurringSubscriptionsByCurrency() throws {
    let core = try CostbarCore()
    let subscriptions = [
        RecurringSubscription(
            id: "codex",
            name: "Codex",
            amount: "20",
            currency: "USD",
            cadence: .monthly
        ),
        RecurringSubscription(
            id: "service",
            name: "Service",
            amount: "1200",
            currency: "NOK",
            cadence: .yearly
        ),
    ]
    try core.ingest(
        providerID: "subscriptions",
        documentID: "subscriptions",
        data: try SubscriptionSettings.snapshotData(from: subscriptions),
        receivedAt: Date(timeIntervalSince1970: 100)
    )

    let dashboard = try core.snapshot(
        period: .init(startUnix: 1, endExclusiveUnix: 200)
    )
    let report = try #require(
        dashboard.providers.first(where: { $0.summary.id == "subscriptions" })
    )
    #expect(report.financials.count == 2)
    #expect(report.summary.currency == "USD")
    #expect(report.lineItems.map(\.amountMicros) == [20_000_000, 100_000_000])
}

@Test
func zigBridgeKeepsSubscriptionUsageOutOfFinancialTotals() throws {
    let core = try CostbarCore()
    try core.ingest(
        providerID: "codex",
        documentID: "usage",
        data: Data(
            #"{"period":{"start_unix":1,"end_exclusive_unix":200},"token_usage":{"input_tokens":100,"output_tokens":20},"allowance_windows":[{"id":"five-hour","label":"5 hour","used_percent":25}],"source":"test"}"#.utf8
        ),
        receivedAt: Date(timeIntervalSince1970: 100)
    )

    let dashboard = try core.snapshot(period: .init(startUnix: 1, endExclusiveUnix: 200))
    let codex = try #require(
        dashboard.providers.first(where: { $0.summary.id == "codex" })
    )
    #expect(codex.tokenUsage?.totalTokens == 120)
    #expect(codex.allowanceWindows.first?.usedPercent == 25)
    #expect(codex.summary.contributesToTotals == false)
    #expect(dashboard.totals.isEmpty)
}

@Test
func claudeStatusBridgePreservesAndRestoresExistingCommand() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let settingsURL = root.appending(path: ".claude/settings.json")
    let supportURL = root.appending(path: "support", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: settingsURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let original = Data(
        #"{"theme":"dark","statusLine":{"type":"command","command":"old-status"}}"#.utf8
    )
    try original.write(to: settingsURL)

    try ClaudeStatusLineBridge.install(settingsURL: settingsURL, supportURL: supportURL)
    #expect(ClaudeStatusLineBridge.isInstalled(
        settingsURL: settingsURL,
        supportURL: supportURL
    ))

    try ClaudeStatusLineBridge.restore(settingsURL: settingsURL, supportURL: supportURL)
    let restored = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
    )
    let statusLine = try #require(restored["statusLine"] as? [String: Any])
    #expect(statusLine["command"] as? String == "old-status")
    #expect(restored["theme"] as? String == "dark")
}
