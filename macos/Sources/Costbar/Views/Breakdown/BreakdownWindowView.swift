import SwiftUI

enum WindowSection: String, CaseIterable, Identifiable {
  case overview
  case providers
  case services
  case resources

  var id: Self { self }

  var title: String {
    switch self {
    case .overview: "Overview"
    case .providers: "By provider"
    case .services: "By service"
    case .resources: "By resource type"
    }
  }

  var icon: String {
    switch self {
    case .overview: "rectangle.grid.2x2"
    case .providers: "building.2"
    case .services: "square.stack.3d.up"
    case .resources: "shippingbox"
    }
  }
}

enum SpendGrouping: String, CaseIterable, Identifiable {
  case service
  case provider
  case resource

  var id: Self { self }
  var title: String { rawValue.capitalized }

  var entryLabel: KeyPath<SpendEntry, String> {
    switch self {
    case .service: \.service
    case .provider: \.providerName
    case .resource: \.resource
    }
  }
}

struct BreakdownWindowView: View {
  /// OpenRouter reports rolling activity ranges rather than calendar months.
  private static let rollingSpendProviderID = "openrouter"

  @ObservedObject var store: DashboardStore
  @State private var section = WindowSection.overview
  @State private var grouping = SpendGrouping.service
  @State private var selectedProviderID: String?
  @State private var selectedTokenWindowID = "month"

  var body: some View {
    NavigationSplitView {
      BreakdownSidebar(dashboard: store.dashboard, selection: sidebarSelection)
    } detail: {
      content
        .navigationTitle(selectedProvider?.summary.displayName ?? section.title)
        .navigationSubtitle(subtitle)
        .toolbar {
          BreakdownToolbar(
            store: store,
            grouping: $grouping,
            usageWindows: selectedProvider?.tokenUsageWindows ?? [],
            usesRollingSpendRanges: usesRollingSpendRanges,
            showsSpendGrouping: selectedProvider?.tokenUsageSeries.isEmpty != false,
            selectedTokenWindowID: $selectedTokenWindowID
          )
        }
    }
    .frame(minWidth: 960, idealWidth: 1_180, minHeight: 620, idealHeight: 760)
    .onChange(of: selectedProviderID) { _, providerID in
      let report = store.dashboard?.providers.first { $0.id == providerID }
      selectedTokenWindowID = report?.summary.providerTypeID == Self.rollingSpendProviderID
        ? "thirty-days"
        : "month"
      if providerID != nil {
        grouping = .resource
      }
    }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch contentState {
    case let .loaded(dashboard, total):
      loadedContent(dashboard: dashboard, total: total)
    case .loading:
      ProgressView("Loading costs…")
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case let .unavailable(title, systemImage, message):
      ContentUnavailableView(
        title,
        systemImage: systemImage,
        description: Text(message)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func loadedContent(
    dashboard: Dashboard,
    total: Dashboard.CurrencyTotal
  ) -> some View {
    let provider = selectedProvider
    let plotsTokenHistory = provider?.tokenUsageSeries.isEmpty == false
    return ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        BreakdownMetrics(
          dashboard: dashboard,
          total: total,
          selectedProvider: provider,
          selectedTokenWindowID: selectedTokenWindowID
        )

        if let error = store.errorMessage {
          ErrorStrip(message: error)
        }

        if let provider, !provider.spendSeries.isEmpty {
          SpendHistoryCard(report: provider, selectedWindowID: selectedTokenWindowID)
        }

        if let provider, plotsTokenHistory {
          TokenUsageHistoryCard(report: provider, selectedSeriesID: selectedTokenWindowID)
        } else {
          SpendCompositionCard(
            entries: visibleEntries(dashboard: dashboard, total: total),
            currency: total.currency,
            grouping: grouping
          )
        }

        if !plotsTokenHistory {
          BreakdownDataTable(
            dashboard: dashboard,
            total: total,
            section: section,
            selectedProviderID: selectedProviderID
          )
        }
      }
      .padding(.horizontal, 30)
      .padding(.top, 28)
      .padding(.bottom, 34)
    }
  }

  private enum ContentState {
    case loaded(Dashboard, Dashboard.CurrencyTotal)
    case loading
    case unavailable(title: String, systemImage: String, message: String)

    static func failed(_ message: String) -> Self {
      .unavailable(
        title: "Unable to load costs",
        systemImage: "exclamationmark.triangle",
        message: message
      )
    }
  }

  private var contentState: ContentState {
    guard let dashboard = store.dashboard else {
      if let error = store.errorMessage { return .failed(error) }
      if store.isRefreshing { return .loading }
      return .unavailable(
        title: "No cost data",
        systemImage: "chart.bar.xaxis",
        message: "Refresh or configure a provider in Settings."
      )
    }
    if let total = displayTotal(in: dashboard) {
      return .loaded(dashboard, total)
    }
    if dashboard.providers.allSatisfy({ $0.summary.status == .notConfigured }) {
      return .unavailable(
        title: "No providers configured",
        systemImage: "gearshape",
        message: "Add provider credentials or enable a local integration in Settings."
      )
    }
    if let error = store.errorMessage { return .failed(error) }
    return .unavailable(
      title: "No billed costs",
      systemImage: "chart.bar.xaxis",
      message: "Usage data loaded successfully. Select Codex, Claude, or OpenCode in Accounts to view it."
    )
  }

  // MARK: - Selection

  private var selectedProvider: Dashboard.ProviderReport? {
    guard let selectedProviderID else { return nil }
    return store.dashboard?.providers.first { $0.id == selectedProviderID }
  }

  private var usesRollingSpendRanges: Bool {
    selectedProvider?.summary.providerTypeID == Self.rollingSpendProviderID
  }

  /// The selected account's own totals, or the dashboard total when the whole
  /// overview is shown.
  private func displayTotal(in dashboard: Dashboard) -> Dashboard.CurrencyTotal? {
    guard
      let selectedProviderID,
      let report = dashboard.providers.first(where: { $0.id == selectedProviderID })
    else {
      return dashboard.primaryTotal
    }

    let financial = report.financials.first { $0.currency == report.summary.currency }
    return Dashboard.CurrencyTotal(
      currency: financial?.currency ?? report.summary.currency,
      currentCostMicros: financial?.currentCostMicros ?? report.summary.currentCostMicros,
      projectedCostMicros: financial?.projectedCostMicros ?? report.summary.projectedCostMicros,
      creditRemainingMicros: financial?.creditRemainingMicros
        ?? report.summary.creditRemainingMicros,
      projectionComplete: financial?.projectedCostMicros != nil
        || report.summary.projectedCostMicros != nil,
      creditComplete: financial?.creditRemainingMicros != nil
        || report.summary.creditRemainingMicros != nil
    )
  }

  private func visibleEntries(
    dashboard: Dashboard,
    total: Dashboard.CurrencyTotal
  ) -> [SpendEntry] {
    dashboard.spendEntries(currency: total.currency).filter { entry in
      selectedProviderID == nil || entry.providerID == selectedProviderID
    }
  }

  private var sidebarSelection: Binding<BreakdownSelection?> {
    Binding(
      get: { selectedProviderID.map(BreakdownSelection.provider) ?? .section(section) },
      set: { selection in
        switch selection {
        case let .section(item):
          section = item
          selectedProviderID = nil
        case let .provider(id):
          selectedProviderID = id
          section = .providers
        case nil:
          break
        }
      }
    )
  }

  private var subtitle: String {
    guard let updated = store.lastUpdatedAt else { return "" }
    return "Updated " + updated.formatted(date: .omitted, time: .shortened)
  }
}
