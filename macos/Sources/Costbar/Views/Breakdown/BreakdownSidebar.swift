import SwiftUI

struct BreakdownSidebar: View {
  let dashboard: Dashboard?
  @Binding var section: WindowSection
  @Binding var selectedProviderID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sidebarLabel("Views")
        .padding(.top, 26)

      VStack(spacing: 4) {
        ForEach(WindowSection.allCases) { item in
          SidebarButton(isSelected: section == item && selectedProviderID == nil) {
            section = item
            selectedProviderID = nil
          } label: {
            Label(item.title, systemImage: item.icon)
              .font(.system(
                size: 13.5,
                weight: section == item && selectedProviderID == nil ? .medium : .regular
              ))
          }
        }
      }
      .padding(.top, 10)

      sidebarLabel("Accounts")
        .padding(.top, 30)

      ScrollView {
        VStack(spacing: 4) {
          ForEach(dashboard?.providers ?? []) { report in
            SidebarButton(
              isSelected: selectedProviderID == report.id,
              verticalPadding: 8
            ) {
              selectedProviderID = report.id
              section = .providers
            } label: {
              accountLabel(report)
            }
          }
        }
        .padding(.top, 10)
      }

      Spacer(minLength: 20)

      SettingsLink {
        Label("Add or edit accounts", systemImage: "plus")
          .font(.system(size: 13))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(WindowPalette.textSecondary)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
          .foregroundStyle(WindowPalette.border)
      )
      .padding(.bottom, 20)
    }
    .padding(.horizontal, 18)
    .background(WindowPalette.sidebar)
  }

  private func accountLabel(_ report: Dashboard.ProviderReport) -> some View {
    HStack(spacing: 10) {
      ProviderLogo(providerID: report.summary.providerTypeID, size: 17)

      Text(report.summary.displayName)
        .lineLimit(1)

      Spacer(minLength: 4)

      if report.summary.status == .unavailable {
        Circle()
          .fill(WindowPalette.warning)
          .frame(width: 5, height: 5)
      }
    }
    .font(.system(size: 13))
  }

  private func sidebarLabel(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .tracking(1.2)
      .textCase(.uppercase)
      .foregroundStyle(WindowPalette.textTertiary)
      .padding(.horizontal, 10)
  }
}

private struct SidebarButton<Label: View>: View {
  let isSelected: Bool
  var verticalPadding: CGFloat = 9
  let action: () -> Void
  @ViewBuilder let label: Label

  var body: some View {
    Button(action: action) {
      label
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, verticalPadding)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? WindowPalette.textPrimary : WindowPalette.textSecondary)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isSelected ? WindowPalette.selection : .clear)
    )
  }
}
