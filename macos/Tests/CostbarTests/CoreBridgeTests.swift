import Testing
@testable import Costbar

@Test
func typedSnapshotBridgeHasNoProviderDataBeforeRefresh() throws {
    let core = try CostbarCore()
    let dashboard = try core.snapshot(period: .init(startUnix: 1, endExclusiveUnix: 2))

    #expect(dashboard.providers.map(\.summary.id) == [
        "digitalocean", "ovh", "hetzner", "cloudflare", "runpod", "vercel",
        "openrouter", "codex", "claude", "openai-api", "anthropic-api", "xai-api",
        "github", "cursor", "opencode",
    ])
    #expect(dashboard.providers.allSatisfy { $0.summary.status == .notConfigured })
    #expect(dashboard.providers.allSatisfy { $0.summary.errorMessage == nil })
    #expect(dashboard.providers.allSatisfy { $0.resources.isEmpty })
    #expect(dashboard.providers.allSatisfy { $0.tokenUsageWindows.isEmpty })
    #expect(dashboard.totals.isEmpty)
}
