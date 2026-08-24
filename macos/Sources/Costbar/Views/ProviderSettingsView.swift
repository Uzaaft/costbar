import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var settings: ProviderSettingsStore
    @ObservedObject var dashboard: DashboardStore

    var body: some View {
        Form {
            Section("DigitalOcean") {
                SecureField("Personal access token", text: $settings.digitalOceanToken)
                Text("Requires billing:read and droplet:read scopes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cloudflare") {
                TextField("Account ID", text: $settings.cloudflareAccountID)
                    .textContentType(.none)
                SecureField("API token", text: $settings.cloudflareToken)
                Text("Requires Billing Read for account subscriptions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Runpod") {
                SecureField("API key", text: $settings.runpodAPIKey)
                Text("Requires read access to account and billing data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vercel") {
                TextField("Team ID or slug (optional)", text: $settings.vercelTeamIDOrSlug)
                    .textContentType(.none)
                SecureField("Access token", text: $settings.vercelToken)
                Text("Billing exports are available for Pro and Enterprise teams.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenRouter") {
                SecureField("API key", text: $settings.openRouterAPIKey)
                SecureField(
                    "Management key (optional)",
                    text: $settings.openRouterManagementKey
                )
                Text("The API key provides spend and limits; a management key adds credits and model activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("API organizations") {
                SecureField("OpenAI Admin API key", text: $settings.openAIAdminKey)
                Text("Organization owner Admin key; reads Costs and Completions usage reports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Anthropic Admin API key", text: $settings.anthropicAdminKey)
                Text("Organization Admin key; reads Cost and Messages usage reports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Developer tools") {
                TextField("GitHub organization", text: $settings.githubOrganization)
                    .textContentType(.none)
                SecureField("GitHub token", text: $settings.githubToken)
                Text("Requires organization Administration read and enhanced billing access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Cursor Team Admin API key", text: $settings.cursorAdminKey)
                Text("Uses team usage events for charged spend and model token totals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recurring subscriptions") {
                ForEach($settings.subscriptions) { $subscription in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            TextField("Subscription name", text: $subscription.name)
                            Button {
                                settings.removeSubscription(id: subscription.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove subscription")
                        }
                        HStack {
                            TextField("Amount", text: $subscription.amount)
                                .frame(width: 100)
                            TextField("Currency", text: $subscription.currency)
                                .frame(width: 70)
                            Picker("Cadence", selection: $subscription.cadence) {
                                ForEach(RecurringSubscription.Cadence.allCases, id: \.self) {
                                    Text($0.title).tag($0)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
                Button("Add subscription", systemImage: "plus") {
                    settings.addSubscription()
                }
            }

            Section("AI subscriptions") {
                Toggle("Track Codex subscription usage", isOn: $settings.tracksCodexUsage)
                Text("Reads Codex quota through the signed-in local CLI and counts tokens from local session logs. Prompt and response text is never retained.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Track Claude subscription usage", isOn: $settings.tracksClaudeUsage)
                Text("Counts Claude Code tokens locally. Subscriber quota comes from Claude's official status-line rate-limit feed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.tracksClaudeUsage {
                    if settings.hasClaudeStatusBridge {
                        Button("Restore previous Claude status line") {
                            settings.restoreClaudeStatusLine()
                        }
                    } else {
                        Button("Install Claude quota bridge") {
                            settings.installClaudeStatusBridge()
                        }
                    }
                }
            }

            HStack {
                if let message = settings.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save and refresh") {
                    if settings.save() {
                        dashboard.refresh()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 820)
    }
}
