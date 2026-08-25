import SwiftUI

enum ProviderLogoAsset {
  struct Variants {
    let light: String
    let dark: String?
  }

  static let variantsByProviderID = [
    "anthropic-api": Variants(
      light: "ProviderLogo-anthropic",
      dark: "ProviderLogo-anthropic-dark"
    ),
    "claude": Variants(light: "ProviderLogo-claude", dark: nil),
    "cloudflare": Variants(light: "ProviderLogo-cloudflare", dark: nil),
    "codex": Variants(light: "ProviderLogo-codex", dark: "ProviderLogo-codex-dark"),
    "cursor": Variants(light: "ProviderLogo-cursor", dark: "ProviderLogo-cursor-dark"),
    "digitalocean": Variants(light: "ProviderLogo-digitalocean", dark: nil),
    "github": Variants(light: "ProviderLogo-github", dark: "ProviderLogo-github-dark"),
    "openai-api": Variants(light: "ProviderLogo-openai", dark: "ProviderLogo-openai-dark"),
    "opencode": Variants(
      light: "ProviderLogo-opencode",
      dark: "ProviderLogo-opencode-dark"
    ),
    "openrouter": Variants(
      light: "ProviderLogo-openrouter",
      dark: "ProviderLogo-openrouter-dark"
    ),
    "vercel": Variants(light: "ProviderLogo-vercel", dark: "ProviderLogo-vercel-dark"),
    "xai-api": Variants(light: "ProviderLogo-xai", dark: "ProviderLogo-xai-dark"),
  ]

  static var allNames: Set<String> {
    Set(variantsByProviderID.values.flatMap { variants in
      [variants.light, variants.dark].compactMap { $0 }
    })
  }

  static func name(for providerID: String, colorScheme: ColorScheme) -> String? {
    guard let variants = variantsByProviderID[providerID] else { return nil }
    if colorScheme == .dark, let dark = variants.dark {
      return dark
    }
    return variants.light
  }
}

struct ProviderLogo: View {
  let providerID: String
  var size: CGFloat = 18
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let assetName = ProviderLogoAsset.name(for: providerID, colorScheme: colorScheme) {
        Image(assetName)
          .resizable()
          .scaledToFit()
      } else {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
          .fill(ProviderTint.color(for: providerID))
          .padding(size * 0.24)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

enum ProviderTint {
  static func color(for id: String) -> Color {
    switch id {
    case "digitalocean": Color(red: 0.22, green: 0.49, blue: 0.96)
    case "ovh": Color(red: 0.20, green: 0.34, blue: 0.68)
    case "hetzner": Color(red: 0.88, green: 0.16, blue: 0.22)
    case "cloudflare": Color(red: 0.95, green: 0.49, blue: 0.20)
    case "runpod": Color(red: 0.40, green: 0.78, blue: 0.55)
    case "vercel": Color(red: 0.91, green: 0.91, blue: 0.94)
    case "openrouter": Color(red: 0.51, green: 0.46, blue: 0.93)
    case "codex": Color(red: 0.23, green: 0.75, blue: 0.66)
    case "claude": Color(red: 0.82, green: 0.44, blue: 0.29)
    case "openai-api": Color(red: 0.22, green: 0.72, blue: 0.62)
    case "anthropic-api": Color(red: 0.78, green: 0.43, blue: 0.26)
    case "xai-api": Color(red: 0.90, green: 0.90, blue: 0.92)
    case "github": Color(red: 0.65, green: 0.65, blue: 0.72)
    case "cursor": Color(red: 0.55, green: 0.70, blue: 0.98)
    case "opencode": Color(red: 0.96, green: 0.72, blue: 0.24)
    default: WindowPalette.blue
    }
  }
}
