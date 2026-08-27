import SwiftUI

struct BreakdownCommandBar: View {
  @ObservedObject var store: DashboardStore
  @Binding var grouping: SpendGrouping
  let usageWindows: [Dashboard.TokenUsageWindow]
  let usesRollingSpendRanges: Bool
  let showsSpendGrouping: Bool
  @Binding var selectedTokenWindowID: String

  var body: some View {
    HStack(spacing: 14) {
      PeriodSelector(
        windows: usageWindows,
        usesRollingSpendRanges: usesRollingSpendRanges,
        selection: $selectedTokenWindowID
      )

      Spacer(minLength: 20)

      if showsSpendGrouping {
        Menu {
          Picker("Group spend", selection: $grouping) {
            ForEach(SpendGrouping.allCases) { option in
              Text(option.title).tag(option)
            }
          }
        } label: {
          CommandBarSurface {
            Text("Group: \(grouping.title)")
            Image(systemName: "chevron.down")
              .font(.system(size: 9, weight: .semibold))
          }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }

      Button {
        store.refresh()
      } label: {
        CommandBarSurface {
          if store.isRefreshing {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(systemName: "arrow.clockwise")
          }
          Text(refreshTitle)
        }
      }
      .buttonStyle(.plain)
      .disabled(store.isRefreshing)
      .keyboardShortcut("r", modifiers: .command)
    }
    .padding(.horizontal, 30)
    .frame(height: 72)
    .background(WindowPalette.chrome)
  }

  /// The last refresh time doubles as the button label once data has loaded.
  private var refreshTitle: String {
    guard let updated = store.lastUpdatedAt else { return "Refresh" }
    return updated.formatted(date: .omitted, time: .shortened)
  }
}

/// The outlined pill shared by the command bar's controls.
private struct CommandBarSurface<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 8) {
      content
    }
    .font(.system(size: 12.5, weight: .medium))
    .foregroundStyle(WindowPalette.textSecondary)
    .padding(.horizontal, 13)
    .frame(height: 34)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(WindowPalette.border, lineWidth: 1)
    )
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

  let windows: [Dashboard.TokenUsageWindow]
  let usesRollingSpendRanges: Bool
  @Binding var selection: String

  var body: some View {
    HStack(spacing: 2) {
      if usesRollingSpendRanges {
        ForEach(Self.rollingSpendRanges, id: \.id) { range in
          periodButton(id: range.id, title: range.title)
        }
      } else {
        periodButton(id: "month", title: "Month")
        ForEach(windows) { window in
          periodButton(id: window.id, title: shortLabel(for: window))
        }
      }
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(WindowPalette.controlBackground)
    )
    .help(helpText)
  }

  private var helpText: String {
    if usesRollingSpendRanges { return "Choose an OpenRouter activity range" }
    return windows.isEmpty ? "Monthly data" : "Choose a rolling local-usage window"
  }

  private func periodButton(id: String, title: String) -> some View {
    let isSelected = selection == id
    return Button {
      selection = id
    } label: {
      Text(title)
        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? WindowPalette.textPrimary : WindowPalette.textSecondary)
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected ? WindowPalette.segmentSelected : .clear)
        )
    }
    .buttonStyle(.plain)
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
