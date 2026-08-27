import SwiftUI

/// One billed line item, flattened across every provider so the breakdown can
/// group it by service, provider, or resource.
struct SpendEntry: Identifiable {
  let id: String
  let providerID: String
  let providerTypeID: String
  let providerName: String
  let service: String
  let resource: String
  let detail: String?
  let amountMicros: Int64
  let currency: String

  var tint: Color { ProviderTint.color(for: providerID) }
}

extension Dashboard {
  /// Every billed charge in `currency`. Providers that report no line items
  /// contribute a single account-total entry so they still appear.
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
            providerTypeID: report.summary.providerTypeID,
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
          providerTypeID: report.summary.providerTypeID,
          providerName: report.summary.displayName,
          service: report.summary.displayName,
          resource: "Account total",
          detail: nil,
          amountMicros: report.summary.currentCostMicros,
          currency: currency
        ),
      ]
    }
  }
}
