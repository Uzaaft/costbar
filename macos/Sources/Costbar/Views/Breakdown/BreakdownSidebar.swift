import SwiftUI

/// What the breakdown sidebar has selected: a whole-dashboard view, or one account.
enum BreakdownSelection: Hashable {
  case section(WindowSection)
  case provider(String)
}

/// A standard source list, so the system draws it as the floating glass sidebar
/// with native selection, keyboard navigation, and VoiceOver.
struct BreakdownSidebar: View {
  let dashboard: Dashboard?
  @Binding var selection: BreakdownSelection?

  var body: some View {
    List(selection: $selection) {
      Section("Views") {
        ForEach(WindowSection.allCases) { item in
          Label(item.title, systemImage: item.icon)
            .tag(BreakdownSelection.section(item))
        }
      }

      Section("Accounts") {
        ForEach(dashboard?.providers ?? []) { report in
          accountLabel(report)
            .tag(BreakdownSelection.provider(report.id))
        }
      }
    }
    .listStyle(.sidebar)
    .bottomBar {
      SettingsLink {
        Label("Add or Edit Accounts…", systemImage: "plus.circle")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
  }

  private func accountLabel(_ report: Dashboard.ProviderReport) -> some View {
    Label {
      HStack {
        Text(report.summary.displayName)
          .lineLimit(1)
        Spacer(minLength: 4)
        if report.summary.status == .unavailable {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(WindowPalette.warning)
            .imageScale(.small)
            .help(report.summary.errorMessage ?? "Unavailable")
            .accessibilityLabel("Unavailable")
        }
      }
    } icon: {
      ProviderLogo(providerID: report.summary.providerTypeID, size: 16)
    }
  }
}
