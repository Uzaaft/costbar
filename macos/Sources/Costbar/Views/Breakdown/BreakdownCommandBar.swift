import SwiftUI

/// The breakdown window's controls, placed in the system toolbar so they sit on
/// its glass and follow its layout, overflow, and customization rules. The text
/// menu and the icon button are separate groups: items that share a glass
/// background should not mix text and icons.
struct BreakdownToolbar: ToolbarContent {
  @ObservedObject var store: DashboardStore
  @Binding var grouping: SpendGrouping
  let usageWindows: [Dashboard.TokenUsageWindow]
  let usesRollingSpendRanges: Bool
  let showsSpendGrouping: Bool
  @Binding var selectedTokenWindowID: String

  var body: some ToolbarContent {
    if PeriodSelector.hasChoices(windows: usageWindows, usesRollingSpendRanges: usesRollingSpendRanges) {
      ToolbarItem(placement: .principal) {
        PeriodSelector(
          windows: usageWindows,
          usesRollingSpendRanges: usesRollingSpendRanges,
          selection: $selectedTokenWindowID
        )
      }
    }

    ToolbarItem(placement: .primaryAction) {
      Picker("Group By", selection: $grouping) {
        ForEach(SpendGrouping.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.menu)
      .help("Group spend by service, provider, or resource")
    }
    .hiddenWhere(!showsSpendGrouping)

    if #available(macOS 26, *) {
      ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    ToolbarItem(placement: .primaryAction) {
      Button {
        store.refresh()
      } label: {
        if store.isRefreshing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Refreshing")
        } else {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }
      .disabled(store.isRefreshing)
      .keyboardShortcut("r", modifiers: .command)
      .help("Refresh all sources (⌘R)")
    }
  }
}

private extension ToolbarContent {
  /// Hides the whole item rather than its view, so no empty glass slot remains.
  @ToolbarContentBuilder
  func hiddenWhere(_ isHidden: Bool) -> some ToolbarContent {
    if #available(macOS 26, *) {
      hidden(isHidden)
    } else if !isHidden {
      self
    }
  }
}

private struct PeriodSelector: View {
  /// OpenRouter's activity API exposes these ranges rather than the rolling
  /// windows the local sources report.
  private static let rollingSpendRanges = [
    (id: "day", title: "24h"),
    (id: "week", title: "1 week"),
    (id: "thirty-days", title: "1 month"),
  ]

  /// A one-segment control is not a choice, so the toolbar omits it.
  static func hasChoices(windows: [Dashboard.TokenUsageWindow], usesRollingSpendRanges: Bool) -> Bool {
    usesRollingSpendRanges || !windows.isEmpty
  }

  let windows: [Dashboard.TokenUsageWindow]
  let usesRollingSpendRanges: Bool
  @Binding var selection: String

  var body: some View {
    Picker("Period", selection: $selection) {
      if usesRollingSpendRanges {
        ForEach(Self.rollingSpendRanges, id: \.id) { range in
          Text(range.title).tag(range.id)
        }
      } else {
        Text("Month").tag("month")
        ForEach(windows) { window in
          Text(shortLabel(for: window)).tag(window.id)
        }
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .help(usesRollingSpendRanges ? "Choose an OpenRouter activity range" : "Choose a rolling local-usage window")
  }

  private func shortLabel(for window: Dashboard.TokenUsageWindow) -> String {
    switch window.id {
    case "hour": "1h"
    case "day": "24h"
    case "week": "7d"
    case "thirty-days": "30d"
    default: window.label
    }
  }
}
