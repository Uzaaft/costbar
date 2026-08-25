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

            Section("OVHcloud Public Cloud") {
                Picker("API region", selection: $settings.ovhEndpoint) {
                    Text("Europe").tag("ovh-eu")
                    Text("Canada").tag("ovh-ca")
                    Text("United States").tag("ovh-us")
                }
                TextField("Public Cloud project ID", text: $settings.ovhProjectID)
                    .textContentType(.none)
                TextField("Application key", text: $settings.ovhApplicationKey)
                    .textContentType(.none)
                SecureField("Application secret", text: $settings.ovhApplicationSecret)
                SecureField("Consumer key", text: $settings.ovhConsumerKey)
                Text("The API credential needs GET access to the project's current usage and forecast endpoints.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hetzner Cloud") {
                SecureField("Project API token", text: $settings.hetznerToken)
                Text("Shows a gross, VAT-inclusive estimate from current servers, backups, volumes, load balancers, IPs, and snapshots. Deleted resources are not visible to the Cloud API.")
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
                TextField("xAI team ID", text: $settings.xAITeamID)
                    .textContentType(.none)
                SecureField("xAI Management API key", text: $settings.xAIManagementKey)
                Text("Reads Grok API spend and prepaid credit. SuperGrok consumer quota is a separate service without a public API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Developer tools") {
                TextField("GitHub organization", text: $settings.githubOrganization)
                    .textContentType(.none)
                Picker("GitHub authentication", selection: $settings.usesGitHubCLI) {
                    Text("Saved token").tag(false)
                    Text("GitHub CLI").tag(true)
                }
                .pickerStyle(.segmented)
                if settings.usesGitHubCLI {
                    Text("Zig invokes the signed-in gh CLI directly. Its token is never exported to Costbar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField("GitHub token", text: $settings.githubToken)
                }
                Text("The selected identity requires organization Administration read and enhanced billing access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Cursor Team Admin API key", text: $settings.cursorAdminKey)
                Text("Uses team usage events for charged spend and model token totals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI subscriptions and agents") {
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

                Toggle("Track OpenCode usage", isOn: $settings.tracksOpenCodeUsage)
                Text("Queries exact cost and token metadata from the installed OpenCode CLI. Prompts and responses are never read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
