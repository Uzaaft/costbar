import SwiftUI

/// A glanceable quota view for the local coding agents. Subscription quota is
/// intentionally separate from billed providers: it is the number people
/// usually want to check while working, and it has no meaningful dollar total.
struct AgentUsageCards: View {
  let reports: [Dashboard.ProviderReport]

  private var agentReports: [Dashboard.ProviderReport] {
    reports.filter { CodingAgent.providerTypeIDs.contains($0.summary.providerTypeID) }
  }

  var body: some View {
    if !agentReports.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Coding agents")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(MenuPalette.textSecondary)
          Spacer()
          Image(systemName: "waveform.path.ecg")
            .font(.system(size: 11))
            .foregroundStyle(MenuPalette.textTertiary)
        }

        HStack(spacing: 8) {
          ForEach(agentReports) { report in
            AgentUsageCard(report: report)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 4)
      .padding(.bottom, 10)
    }
  }
}

private struct AgentUsageCard: View {
  let report: Dashboard.ProviderReport

  private static let hoverDelay = Duration.milliseconds(280)

  private var summary: Dashboard.ProviderSummary { report.summary }
  private var accent: Color { ProviderTint.color(for: summary.providerTypeID) }
  private var primaryWindow: Dashboard.AllowanceWindow? { report.allowanceWindows.first }
  private var secondaryWindow: Dashboard.AllowanceWindow? { report.allowanceWindows.dropFirst().first }
  @State private var isHovering = false
  @State private var showsDetail = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 7) {
        ProviderLogo(providerID: summary.providerTypeID, size: 17)
        Text(summary.displayName)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(MenuPalette.textPrimary)
          .lineLimit(1)
        Spacer(minLength: 2)
        Circle()
          .fill(statusColor)
          .frame(width: 5, height: 5)
      }

      if let primaryWindow {
        ZStack {
          QuotaRing(percent: primaryWindow.usedPercent, lineWidth: 6)
            .frame(width: 66, height: 66)
          Text(primaryWindow.usedPercentText)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(MenuPalette.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 13)
        .padding(.bottom, 9)

        Text(primaryWindow.label)
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(MenuPalette.textSecondary)
          .lineLimit(1)
        Text(resetText(for: primaryWindow))
          .font(.system(size: 10))
          .foregroundStyle(MenuPalette.textTertiary)
          .lineLimit(1)
      } else {
        Text(summary.status == .available ? "No quota windows" : "Not configured")
          .font(.system(size: 11))
          .foregroundStyle(MenuPalette.textTertiary)
          .padding(.top, 29)
          .padding(.bottom, 31)
      }

      if let secondaryWindow {
        Divider().overlay(MenuPalette.hairline).padding(.vertical, 9)
        HStack(spacing: 5) {
          Text(secondaryWindow.label)
            .lineLimit(1)
          Spacer(minLength: 2)
          Text(secondaryWindow.usedPercentText)
            .monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(MenuPalette.textTertiary)
      }
    }
    .padding(11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.white.opacity(0.08), lineWidth: 1)
    }
    .contentShape(Rectangle())
    .onHover { hovering in
      isHovering = hovering
      if !hovering { showsDetail = false }
    }
    .task(id: isHovering) {
      guard isHovering else { return }
      try? await Task.sleep(for: Self.hoverDelay)
      guard !Task.isCancelled else { return }
      showsDetail = true
    }
    .hoverCard(isPresented: showsDetail) {
      AgentQuotaCard(report: report)
    }
  }

  private var statusColor: Color {
    switch summary.status {
    case .available: accent
    case .notConfigured: MenuPalette.textTertiary
    case .unavailable: MenuPalette.warning
    }
  }

  private func resetText(for window: Dashboard.AllowanceWindow) -> String {
    guard let reset = window.resetsAtUnix else { return "reset unavailable" }
    return "resets " + Date(timeIntervalSince1970: TimeInterval(reset)).formatted(
      date: .omitted, time: .shortened
    )
  }
}
