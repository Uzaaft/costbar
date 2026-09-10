import SwiftUI

/// The table under the charts: billed line items, or the resource inventory
/// when the resources section is selected.
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
            .font(.title3.weight(.semibold))
            .foregroundStyle(WindowPalette.textPrimary)
          if let selectedProviderName {
            Text("Filtered to \(selectedProviderName)")
              .font(.subheadline)
              .foregroundStyle(WindowPalette.textTertiary)
          }
        }
        Spacer()
        Text("\(rowCount) \(rowCount == 1 ? "row" : "rows")")
          .font(.subheadline.monospacedDigit())
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
    case .overview: "Largest Charges"
    case .providers: "Provider Breakdown"
    case .services: "Service Breakdown"
    case .resources: "Resource Inventory"
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

    // A single account is already one provider and one service, so grouping it
    // further would collapse the table to one row.
    guard selectedProviderID == nil else {
      return entries.map(SpendTableRowModel.init(entry:)).sortedByAmount()
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
          providerTypeID: report.summary.providerTypeID,
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
          providerTypeID: dominant?.providerTypeID ?? "",
          service: label,
          account: providerGrouping ? "All services" : accountLabel(accounts),
          resource: "\(group.count) \(group.count == 1 ? "charge" : "charges")",
          amountMicros: group.map(\.amountMicros).saturatingSum
        )
      }
      .sortedByAmount()
  }

  private func accountLabel(_ accounts: Set<String>) -> String {
    if accounts.count == 1 { return accounts.first ?? "" }
    return "\(accounts.count) accounts"
  }
}

// MARK: - Spend table

private struct SpendRowsTable: View {
  /// The table is a summary, not a ledger; deeper rows live in the provider's
  /// own dashboard.
  private static let maximumRows = 14

  let rows: [SpendTableRowModel]
  let totalMicros: Int64
  let currency: String

  var body: some View {
    VStack(spacing: 0) {
      TableHeaderRow(columns: SpendTableColumn.allCases)

      if rows.isEmpty {
        TableEmptyState(message: "No billed line items are available for this view.")
      } else {
        ForEach(rows.prefix(Self.maximumRows)) { row in
          SpendTableRow(row: row, totalMicros: totalMicros, currency: currency)
        }
      }
    }
    .tableSurface()
  }
}

private enum SpendTableColumn: TableColumnDescribing, CaseIterable {
  case service
  case account
  case resource
  case monthToDate
  case share

  var title: String {
    switch self {
    case .service: "Service"
    case .account: "Account"
    case .resource: "Resource"
    case .monthToDate: "Month to Date"
    case .share: "Share"
    }
  }

  var width: CGFloat? {
    switch self {
    case .service: nil
    case .account: 138
    case .resource: 180
    case .monthToDate: 104
    case .share: 60
    }
  }

  var alignment: Alignment {
    switch self {
    case .service, .account, .resource: .leading
    case .monthToDate, .share: .trailing
    }
  }
}

private struct SpendTableRow: View {
  let row: SpendTableRowModel
  let totalMicros: Int64
  let currency: String

  var body: some View {
    TableRow {
      HStack(spacing: 10) {
        ProviderLogo(providerID: row.providerTypeID, size: 16)
        Text(row.service)
          .foregroundStyle(WindowPalette.textPrimary)
          .lineLimit(1)
      }
      .tableColumn(SpendTableColumn.service)

      Text(row.account)
        .tableColumn(SpendTableColumn.account)
      Text(row.resource)
        .tableColumn(SpendTableColumn.resource)
      Text(row.amountMicros.currencyText(code: currency))
        .foregroundStyle(WindowPalette.textPrimary)
        .monospacedDigit()
        .tableColumn(SpendTableColumn.monthToDate)
      Text(shareText)
        .monospacedDigit()
        .tableColumn(SpendTableColumn.share)
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
  let providerTypeID: String
  let service: String
  let account: String
  let resource: String
  let amountMicros: Int64
}

private extension SpendTableRowModel {
  init(entry: SpendEntry) {
    self.init(
      id: entry.id,
      providerTypeID: entry.providerTypeID,
      service: entry.service,
      account: entry.providerName,
      resource: entry.resource,
      amountMicros: entry.amountMicros
    )
  }
}

private extension [SpendTableRowModel] {
  func sortedByAmount() -> Self {
    sorted { $0.amountMicros > $1.amountMicros }
  }
}

// MARK: - Resource table

private struct ResourceInventoryTable: View {
  private static let maximumRows = 18

  let rows: [ResourceTableRowModel]

  var body: some View {
    VStack(spacing: 0) {
      TableHeaderRow(columns: ResourceTableColumn.allCases)

      if rows.isEmpty {
        TableEmptyState(message: "No resources were reported by the selected accounts.")
      } else {
        ForEach(rows.prefix(Self.maximumRows)) { row in
          TableRow {
            HStack(spacing: 10) {
              ProviderLogo(providerID: row.providerTypeID, size: 16)
              Text(row.name)
                .foregroundStyle(WindowPalette.textPrimary)
                .lineLimit(1)
            }
            .tableColumn(ResourceTableColumn.resource)

            Text(row.account).tableColumn(ResourceTableColumn.account)
            Text(row.kind).tableColumn(ResourceTableColumn.kind)
            Text(row.status).tableColumn(ResourceTableColumn.status)
            Text(row.quantity.formatted())
              .monospacedDigit()
              .tableColumn(ResourceTableColumn.quantity)
          }
        }
      }
    }
    .tableSurface()
  }
}

private enum ResourceTableColumn: TableColumnDescribing, CaseIterable {
  case resource
  case account
  case kind
  case status
  case quantity

  var title: String {
    switch self {
    case .resource: "Resource"
    case .account: "Account"
    case .kind: "Type"
    case .status: "Status"
    case .quantity: "Quantity"
    }
  }

  var width: CGFloat? {
    switch self {
    case .resource: nil
    case .account: 180
    case .kind: 150
    case .status: 100
    case .quantity: 70
    }
  }

  var alignment: Alignment {
    self == .quantity ? .trailing : .leading
  }
}

private struct ResourceTableRowModel: Identifiable {
  let id: String
  let providerTypeID: String
  let account: String
  let name: String
  let kind: String
  let status: String
  let quantity: UInt64
}

// MARK: - Shared table chrome

/// One column of a breakdown table. A `nil` width means the column takes the
/// space the fixed-width columns leave over.
private protocol TableColumnDescribing {
  var title: String { get }
  var width: CGFloat? { get }
  var alignment: Alignment { get }
}

private extension View {
  @ViewBuilder
  func tableColumn(_ column: some TableColumnDescribing) -> some View {
    if let width = column.width {
      frame(width: width, alignment: column.alignment)
    } else {
      frame(maxWidth: .infinity, alignment: column.alignment)
    }
  }
}

private struct TableHeaderRow<Column: TableColumnDescribing>: View {
  let columns: [Column]

  var body: some View {
    HStack(spacing: 18) {
      ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
        Text(column.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(WindowPalette.textTertiary)
          .tableColumn(column)
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 40)
    .background(WindowPalette.tableHeader)
  }
}

private struct TableRow<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 18) {
      content
    }
    .font(.callout)
    .foregroundStyle(WindowPalette.textSecondary)
    .padding(.horizontal, 16)
    .frame(height: 46)
    .overlay(alignment: .bottom) {
      Rectangle().fill(WindowPalette.hairline).frame(height: 1)
    }
  }
}

private struct TableEmptyState: View {
  let message: String

  var body: some View {
    Text(message)
      .font(.callout)
      .foregroundStyle(WindowPalette.textTertiary)
      .frame(maxWidth: .infinity, minHeight: 92)
  }
}
