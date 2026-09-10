import SwiftUI

/// The small window behind the notch's gear: what each ring opens, whether the
/// notch shows at all, and which edge it hangs from.
struct NotchSettingsView: View {
  @ObservedObject var settings: NotchSettingsStore
  @Environment(\.openSettings) private var openSettings

  static let size = CGSize(width: 380, height: 560)

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          ForEach(CodingAgent.allCases) { agent in
            agentRow(agent)
          }
        } header: {
          Text("Coding Agents")
        } footer: {
          Text(
            "Claude and Codex quota come from the sign-in each tool already holds on this Mac. "
              + "Cursor personal allowance uses the editor session; team billing still uses the admin key. "
              + "Costbar reads the numbers and keeps no copy."
          )
        }

        Section("Notch") {
          Toggle("Side notch", isOn: $settings.isEnabled)
          SettingsHelpText("Slides out when the pointer reaches the edge and tucks away when you leave.")
          Toggle("Peek when an agent finishes or waits", isOn: $settings.announcesCompletion)
          Toggle("Play a sound with that peek", isOn: $settings.playsCompletionSound)
            .disabled(!settings.announcesCompletion)

          Picker("Edge", selection: $settings.edge) {
            ForEach(NotchEdge.allCases) { edge in
              Text(edge.label).tag(edge)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          SettingsHelpText("Which side of the screen the notch hangs from.")
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Text("Costbar \(version)")
        Spacer()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
    .frame(width: Self.size.width, height: Self.size.height)
  }

  private func agentRow(_ agent: CodingAgent) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        ProviderLogo(providerID: agent.providerTypeID, size: 18)
        Text(agent.displayName)
          .font(.system(size: 13, weight: .semibold))
        Spacer(minLength: 12)
        Toggle(isOn: opensApp(agent)) {
          Text("Open \(agent.launchLabel)")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
      }
      Text("Clicking the ring opens \(agent.launchLabel).")
        .font(.caption)
        .foregroundStyle(.secondary)
      if agent == .codex {
        // Costbar's own Settings, where Codex accounts are switched.
        Button("Switch Account…") {
          NSApp.activate()
          openSettings()
        }
          .buttonStyle(.link)
          .font(.caption)
      }
    }
    .padding(.vertical, 2)
  }

  private func opensApp(_ agent: CodingAgent) -> Binding<Bool> {
    Binding(
      get: { settings.opensApp(agent) },
      set: { settings.setOpensApp($0, for: agent) }
    )
  }

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }
}
