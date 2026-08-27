import SwiftUI

/// The header above every settings detail pane. The icon is either a provider
/// logo or a tinted SF Symbol.
struct SettingsDetailHeader: View {
  enum Icon {
    case provider(id: String)
    case symbol(String, tint: Color)
  }

  let icon: Icon
  let title: String
  let subtitle: String

  var body: some View {
    HStack(spacing: 13) {
      iconView
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title2.weight(.semibold))
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 28)
    .padding(.top, 24)
    .padding(.bottom, 10)
  }

  @ViewBuilder
  private var iconView: some View {
    switch icon {
    case let .provider(id):
      ProviderLogo(providerID: id, size: 36)
    case let .symbol(systemImage, tint):
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(tint)
        .frame(width: 38, height: 38)
        .overlay {
          Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
        }
    }
  }
}

/// A sidebar entry, with a dot marking sources that are configured.
struct SettingsSidebarRow: View {
  enum Icon {
    case provider(id: String)
    case symbol(String, tint: Color)
  }

  let icon: Icon
  let title: String
  let isEnabled: Bool

  var body: some View {
    HStack(spacing: 9) {
      iconView
        .frame(width: 25, height: 25)
      Text(title)
      Spacer()
      if isEnabled {
        Circle()
          .fill(Color.green)
          .frame(width: 6, height: 6)
      }
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var iconView: some View {
    switch icon {
    case let .provider(id):
      ProviderLogo(providerID: id, size: 22)
    case let .symbol(systemImage, tint):
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(tint)
        .overlay {
          Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
        }
    }
  }
}

/// Explanatory copy under a form control.
struct SettingsHelpText: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

/// A secure field paired with a link to the provider's own credential page.
struct SetupLinkedSecureField: View {
  let title: String
  @Binding var text: String
  let destination: URL
  let actionLabel: String
  var linkEnabled = true

  var body: some View {
    HStack {
      SecureField(title, text: $text)
      Link(destination: destination) {
        Label(actionLabel, systemImage: "arrow.up.right.square")
      }
      .controlSize(.small)
      .disabled(!linkEnabled)
    }
  }
}

/// The pinned footer that commits edits and kicks off a refresh.
struct SettingsSaveBar: View {
  @ObservedObject var settings: ProviderSettingsStore
  @ObservedObject var dashboard: DashboardStore

  var body: some View {
    HStack(spacing: 12) {
      if let message = settings.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer()
      Button("Save and refresh") {
        if settings.save() {
          dashboard.pollingSettingsDidChange()
          dashboard.refresh()
        }
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 12)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }
}

/// Shared layout for every detail pane: header, scrolling form, save bar.
struct SettingsDetailScaffold<Content: View>: View {
  let icon: SettingsDetailHeader.Icon
  let title: String
  let subtitle: String
  @ObservedObject var settings: ProviderSettingsStore
  @ObservedObject var dashboard: DashboardStore
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      SettingsDetailHeader(icon: icon, title: title, subtitle: subtitle)

      Form {
        content
      }
      .formStyle(.grouped)

      SettingsSaveBar(settings: settings, dashboard: dashboard)
    }
  }
}
