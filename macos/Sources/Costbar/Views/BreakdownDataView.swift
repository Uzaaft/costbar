import SwiftUI

struct SpendEntry: Identifiable {
  let id: String
  let providerID: String
  let providerName: String
  let service: String
  let resource: String
  let detail: String?
  let amountMicros: Int64
  let currency: String

  var tint: Color { ProviderTint.color(for: providerID) }
}

struct SpendCompositionCard: View {
  let entries: [SpendEntry]
  let currency: String
  let grouping: SpendGrouping

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Month-to-date composition")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(WindowPalette.textPrimary)
          Text("Actual billed spend grouped by \(grouping.title.lowercased())")
            .font(.system(size: 11.5))
            .foregroundStyle(WindowPalette.textTertiary)
        }

        Spacer(minLength: 12)

        Text(totalMicros.currencyText(code: currency))
          .font(.system(size: 13, weight: .medium, design: .monospaced))
          .foregroundStyle(WindowPalette.textSecondary)
      }

      if chartItems.isEmpty {
        ContentUnavailableView(
          "No billed spend",
          systemImage: "chart.bar",
          description: Text("Configure an account or refresh provider data.")
        )
        .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        SpendBarChart(items: chartItems, currency: currency)
      }
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(WindowPalette.sidebar.opacity(0.68))
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(WindowPalette.hairline, lineWidth: 1)
        }
    )
  }

  private var totalMicros: Int64 {
    entries.reduce(0) { $0 + $1.amountMicros }
  }

  private var chartItems: [SpendChartItem] {
    let grouped: [String: [SpendEntry]]
    switch grouping {
    case .service:
      grouped = Dictionary(grouping: entries, by: \.service)
    case .provider:
      grouped = Dictionary(grouping: entries, by: \.providerName)
    }

    return grouped.map { label, groupedEntries in
      let dominant = groupedEntries.max { $0.amountMicros < $1.amountMicros }
      return SpendChartItem(
        id: label,
        label: label,
        amountMicros: groupedEntries.reduce(0) { $0 + $1.amountMicros },
        color: dominant?.tint ?? WindowPalette.blue
      )
    }
    .filter { $0.amountMicros > 0 }
    .sorted { $0.amountMicros > $1.amountMicros }
    .prefix(8)
    .map { $0 }
  }
}

private struct SpendChartItem: Identifiable {
  let id: String
  let label: String
  let amountMicros: Int64
  let color: Color
}

private struct SpendBarChart: View {
  let items: [SpendChartItem]
  let currency: String

  var body: some View {
    GeometryReader { geometry in
      let availableHeight = max(80, geometry.size.height - 49)

      ZStack(alignment: .bottom) {
        chartGrid

        HStack(alignment: .bottom, spacing: 12) {
          ForEach(items) { item in
            VStack(spacing: 7) {
              Text(item.amountMicros.currencyText(code: currency))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(WindowPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)

              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                  LinearGradient(
                    colors: [item.color.opacity(0.72), item.color],
                    startPoint: .bottom,
                    endPoint: .top
                  )
                )
                .frame(height: barHeight(for: item, available: availableHeight))

              Text(item.label)
                .font(.system(size: 10.5))
                .foregroundStyle(WindowPalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
          }
        }
        .padding(.horizontal, 4)
      }
    }
    .frame(height: 196)
  }

  private var chartGrid: some View {
    VStack {
      Rectangle().fill(WindowPalette.hairline).frame(height: 1)
      Spacer()
      Rectangle().fill(WindowPalette.hairline).frame(height: 1)
      Spacer()
      Rectangle().fill(WindowPalette.hairline).frame(height: 1)
    }
    .padding(.bottom, 27)
  }

  private func barHeight(for item: SpendChartItem, available: CGFloat) -> CGFloat {
    guard let maximum = items.map(\.amountMicros).max(), maximum > 0 else { return 4 }
    let ratio = CGFloat(Double(item.amountMicros) / Double(maximum))
    return max(5, ratio * available)
  }
}

struct BreakdownDataTable: View {
  let dashboard: Dashboard
  let total: Dashboard.CurrencyTotal
  let section: WindowSection
  let selectedProviderID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(WindowPalette.textPrimary)
          if let selectedProviderName {
            Text("Filtered to \(selectedProviderName)")
              .font(.system(size: 11.5))
              .foregroundStyle(WindowPalette.textTertiary)
          }
        }
        Spacer()
        Text("\(rowCount) \(rowCount == 1 ? "row" : "rows")")
          .font(.system(size: 11.5, design: .monospaced))
          .foregroundStyle(WindowPalette.textTertiary)
      }

      if section == .resources {
        ResourceInventoryTable(rows: resourceRows)
      } else {
        SpendRowsTable(
          rows: spendRows,
          totalMicros: total.currentCostMicros,
          currency: total.currency
        )
      }
    }
  }

  private var title: String {
    switch section {
    case .overview: "Largest charges"
    case .providers: "Provider breakdown"
    case .services: "Service breakdown"
    case .resources: "Resource inventory"
    }
  }

  private var selectedProviderName: String? {
    guard let selectedProviderID else { return nil }
    return dashboard.providers.first { $0.id == selectedProviderID }?.summary.displayName
  }

  private var spendRows: [SpendTableRowModel] {
    let entries = dashboard.spendEntries(currency: total.currency).filter { entry in
      selectedProviderID == nil || entry.providerID == selectedProviderID
    }

    switch section {
    case .overview:
      return entries.map(SpendTableRowModel.init(entry:)).sortedByAmount()
    case .providers:
      return groupedRows(entries: entries, key: \.providerName, providerGrouping: true)
    case .services:
      return groupedRows(entries: entries, key: \.service, providerGrouping: false)
    case .resources:
      return []
    }
  }

  private var resourceRows: [ResourceTableRowModel] {
    dashboard.providers.flatMap { report -> [ResourceTableRowModel] in
      guard selectedProviderID == nil || report.id == selectedProviderID else { return [] }
      return report.resources.map { resource in
        ResourceTableRowModel(
          id: "\(report.id):\(resource.id)",
          providerID: report.id,
          account: report.summary.displayName,
          name: resource.name,
          kind: resource.kind.replacingOccurrences(of: "_", with: " ").capitalized,
          status: resource.status.capitalized,
          quantity: resource.quantity
        )
      }
    }
    .sorted { lhs, rhs in
      if lhs.account == rhs.account { return lhs.name < rhs.name }
      return lhs.account < rhs.account
    }
  }

  private var rowCount: Int {
    section == .resources ? resourceRows.count : spendRows.count
  }

  private func groupedRows(
    entries: [SpendEntry],
    key: KeyPath<SpendEntry, String>,
    providerGrouping: Bool
  ) -> [SpendTableRowModel] {
    Dictionary(grouping: entries, by: { $0[keyPath: key] })
      .map { label, group in
        let dominant = group.max { $0.amountMicros < $1.amountMicros }
        let accounts = Set(group.map(\.providerName))
        return SpendTableRowModel(
          id: label,
          providerID: dominant?.providerID ?? "",
          service: label,
          account: providerGrouping ? "All services" : accountLabel(accounts),
          resource: "\(group.count) \(group.count == 1 ? "charge" : "charges")",
          amountMicros: group.reduce(0) { $0 + $1.amountMicros }
        )
      }
      .sortedByAmount()
  }

  private func accountLabel(_ accounts: Set<String>) -> String {
    if accounts.count == 1 { return accounts.first ?? "" }
    return "\(accounts.count) accounts"
  }
}

private struct SpendRowsTable: View {
  let rows: [SpendTableRowModel]
  let totalMicros: Int64
  let currency: String

  var body: some View {
    VStack(spacing: 0) {
      SpendTableHeader()

      if rows.isEmpty {
        TableEmptyState(message: "No billed line items are available for this view.")
      } else {
        ForEach(rows.prefix(14)) { row in
          SpendTableRow(
            row: row,
            totalMicros: totalMicros,
            currency: currency
          )
        }
      }
    }
    .tableSurface()
  }
}

private struct SpendTableHeader: View {
  var body: some View {
    HStack(spacing: 18) {
      TableHeaderText("Service")
        .frame(maxWidth: .infinity, alignment: .leading)
      TableHeaderText("Account")
        .frame(width: 138, alignment: .leading)
      TableHeaderText("Resource")
        .frame(width: 180, alignment: .leading)
      TableHeaderText("MTD")
        .frame(width: 104, alignment: .trailing)
      TableHeaderText("Share")
        .frame(width: 60, alignment: .trailing)
    }
    .padding(.horizontal, 16)
    .frame(height: 40)
    .background(WindowPalette.chrome)
  }
}

private struct SpendTableRow: View {
  let row: SpendTableRowModel
  let totalMicros: Int64
  let currency: String

  var body: some View {
    HStack(spacing: 18) {
      HStack(spacing: 10) {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
          .fill(ProviderTint.color(for: row.providerID))
          .frame(width: 8, height: 8)
        Text(row.service)
          .foregroundStyle(WindowPalette.textPrimary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(row.account)
        .frame(width: 138, alignment: .leading)
      Text(row.resource)
        .frame(width: 180, alignment: .leading)
      Text(row.amountMicros.currencyText(code: currency))
        .foregroundStyle(WindowPalette.textPrimary)
        .monospacedDigit()
        .frame(width: 104, alignment: .trailing)
      Text(shareText)
        .monospacedDigit()
        .frame(width: 60, alignment: .trailing)
    }
    .font(.system(size: 12.5))
    .foregroundStyle(WindowPalette.textSecondary)
    .padding(.horizontal, 16)
    .frame(height: 46)
    .overlay(alignment: .bottom) {
      Rectangle().fill(WindowPalette.hairline).frame(height: 1)
    }
  }

  private var shareText: String {
    guard totalMicros > 0 else { return "0%" }
    return (Double(row.amountMicros) / Double(totalMicros)).formatted(
      .percent.precision(.fractionLength(0)).locale(MoneyFormat.locale)
    )
  }
}

private struct SpendTableRowModel: Identifiable {
  let id: String
  let providerID: String
  let service: String
  let account: String
  let resource: String
  let amountMicros: Int64

  init(entry: SpendEntry) {
    id = entry.id
    providerID = entry.providerID
    service = entry.service
    account = entry.providerName
    resource = entry.resource
    amountMicros = entry.amountMicros
  }

  init(
    id: String,
    providerID: String,
    service: String,
    account: String,
    resource: String,
    amountMicros: Int64
  ) {
    self.id = id
    self.providerID = providerID
    self.service = service
    self.account = account
    self.resource = resource
    self.amountMicros = amountMicros
  }
}

private struct ResourceInventoryTable: View {
  let rows: [ResourceTableRowModel]

  var body: some View {
    VStack(spacing: 0) {
      ResourceTableHeader()

      if rows.isEmpty {
        TableEmptyState(message: "No resources were reported by the selected accounts.")
      } else {
        ForEach(rows.prefix(18)) { row in
          HStack(spacing: 18) {
            HStack(spacing: 10) {
              RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(ProviderTint.color(for: row.providerID))
                .frame(width: 8, height: 8)
              Text(row.name)
                .foregroundStyle(WindowPalette.textPrimary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.account).frame(width: 180, alignment: .leading)
            Text(row.kind).frame(width: 150, alignment: .leading)
            Text(row.status).frame(width: 100, alignment: .leading)
            Text(row.quantity.formatted())
              .monospacedDigit()
              .frame(width: 70, alignment: .trailing)
          }
          .font(.system(size: 12.5))
          .foregroundStyle(WindowPalette.textSecondary)
          .padding(.horizontal, 16)
          .frame(height: 46)
          .overlay(alignment: .bottom) {
            Rectangle().fill(WindowPalette.hairline).frame(height: 1)
          }
        }
      }
    }
    .tableSurface()
  }
}

private struct ResourceTableHeader: View {
  var body: some View {
    HStack(spacing: 18) {
      TableHeaderText("Resource").frame(maxWidth: .infinity, alignment: .leading)
      TableHeaderText("Account").frame(width: 180, alignment: .leading)
      TableHeaderText("Type").frame(width: 150, alignment: .leading)
      TableHeaderText("Status").frame(width: 100, alignment: .leading)
      TableHeaderText("Qty").frame(width: 70, alignment: .trailing)
    }
    .padding(.horizontal, 16)
    .frame(height: 40)
    .background(WindowPalette.chrome)
  }
}

private struct ResourceTableRowModel: Identifiable {
  let id: String
  let providerID: String
  let account: String
  let name: String
  let kind: String
  let status: String
  let quantity: UInt64
}

private struct TableHeaderText: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(.system(size: 10.5, weight: .semibold))
      .tracking(0.9)
      .textCase(.uppercase)
      .foregroundStyle(WindowPalette.textTertiary)
  }
}

private struct TableEmptyState: View {
  let message: String

  var body: some View {
    Text(message)
      .font(.system(size: 12.5))
      .foregroundStyle(WindowPalette.textTertiary)
      .frame(maxWidth: .infinity, minHeight: 92)
  }
}

extension Dashboard {
  func spendEntries(currency: String) -> [SpendEntry] {
    providers.flatMap { report -> [SpendEntry] in
      guard report.summary.status == .available,
        report.summary.contributesToTotals
      else { return [] }

      let matchingItems = report.lineItems.filter { item in
        let itemCurrency = item.currency ?? report.summary.currency
        return itemCurrency == currency && item.amountMicros > 0
      }

      if !matchingItems.isEmpty {
        return matchingItems.map { item in
          SpendEntry(
            id: "\(report.id):\(item.id)",
            providerID: report.id,
            providerName: report.summary.displayName,
            service: item.service,
            resource: item.description,
            detail: item.detail,
            amountMicros: item.amountMicros,
            currency: item.currency ?? report.summary.currency
          )
        }
      }

      guard report.summary.currency == currency,
        report.summary.currentCostMicros > 0
      else { return [] }
      return [
        SpendEntry(
          id: "\(report.id):account-total",
          providerID: report.id,
          providerName: report.summary.displayName,
          service: report.summary.displayName,
          resource: "Account total",
          detail: nil,
          amountMicros: report.summary.currentCostMicros,
          currency: currency
        )
      ]
    }
  }
}

extension Array where Element == SpendTableRowModel {
  fileprivate func sortedByAmount() -> Self {
    sorted { $0.amountMicros > $1.amountMicros }
  }
}

extension View {
  fileprivate func tableSurface() -> some View {
    clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(WindowPalette.hairline, lineWidth: 1)
      }
  }
}
