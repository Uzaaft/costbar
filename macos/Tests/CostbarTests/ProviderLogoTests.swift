import AppKit
import Testing
@testable import Costbar

@Test
func knownProviderIDsMapToBundledAssets() {
    let expectedProviderIDs = Set([
        "anthropic-api",
        "claude",
        "cloudflare",
        "codex",
        "cursor",
        "digitalocean",
        "github",
        "openai-api",
        "opencode",
        "openrouter",
        "vercel",
        "xai-api",
    ])

    #expect(Set(ProviderLogoAsset.variantsByProviderID.keys) == expectedProviderIDs)
    #expect(ProviderLogoAsset.name(for: "runpod", colorScheme: .dark) == nil)
    #expect(ProviderLogoAsset.name(for: "unknown", colorScheme: .light) == nil)
    #expect(
        ProviderLogoAsset.name(for: "openrouter", colorScheme: .dark)
            == "ProviderLogo-openrouter-dark"
    )
    #expect(
        ProviderLogoAsset.name(for: "openrouter", colorScheme: .light)
            == "ProviderLogo-openrouter"
    )
    #expect(
        ProviderLogoAsset.name(for: "digitalocean", colorScheme: .dark)
            == "ProviderLogo-digitalocean"
    )
}

@Test
func mappedAssetsLoadFromTheAppCatalog() {
    for assetName in ProviderLogoAsset.allNames {
        #expect(NSImage(named: NSImage.Name(assetName)) != nil, Comment(rawValue: assetName))
    }
}
