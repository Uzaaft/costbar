import CloudKit
import SwiftUI

@main
struct CostbarMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = MobileStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardScreen(store: store)
                .preferredColorScheme(.dark)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await store.connect()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        _ = await store.refresh()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                    Task { await store.accountChanged() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { store.scheduleRefresh() }
                }
        }
    }
}

private enum Layout {
    static let cornerRadius: CGFloat = 16
}

private enum Palette {
    static let background = Color(red: 0.075, green: 0.078, blue: 0.09)
    static let raised = Color(red: 0.12, green: 0.125, blue: 0.14)
    static let blue = Color(red: 0.24, green: 0.60, blue: 1)
    static let green = Color(red: 0.32, green: 0.81, blue: 0.64)
    static let muted = Color.white.opacity(0.48)
}

private enum MobileTab: Hashable { case overview, usage, settings }

struct DashboardScreen: View {
    @ObservedObject var store: MobileStore
    @State private var tab = MobileTab.overview
    @State private var selectedProvider: UsageSnapshot.Provider?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(store: MobileStore) {
        self.store = store
        #if DEBUG
        switch ProcessInfo.processInfo.environment["COSTBAR_LAUNCH_TAB"] {
        case "usage": _tab = State(initialValue: .usage)
        case "settings": _tab = State(initialValue: .settings)
        default: break
        }
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                dashboard(agentsOnly: false)
                    .navigationTitle("Overview")
                    .toolbar { refreshButton }
            }
            .tabItem { Label("Overview", systemImage: "square.grid.2x2") }.tag(MobileTab.overview)
            NavigationStack {
                dashboard(agentsOnly: true)
                    .navigationTitle("AI Usage")
                    .toolbar { refreshButton }
            }
            .tabItem { Label("AI Usage", systemImage: "chart.bar.xaxis") }.tag(MobileTab.usage)
            NavigationStack { settings }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(MobileTab.settings)
        }
        .tint(Palette.blue)
        .sheet(item: $selectedProvider) { provider in
            ProviderDetail(providerID: provider.id, store: store)
        }
        .onOpenURL { url in
            if url.host == "settings" { tab = .settings }
            else if url.host == "agents" { tab = .usage }
            else { tab = .overview }
        }
    }

    private var refreshButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { _ = await store.refresh() }
            } label: {
                if store.refreshing { ProgressView() }
                else { Image(systemName: "arrow.clockwise") }
            }
            .disabled(store.refreshing)
            .accessibilityLabel(store.refreshing ? "Refreshing usage" : "Refresh usage")
        }
    }

    private func dashboard(agentsOnly: Bool) -> some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 24) {
                    if let snapshot = store.snapshot {
                        syncStatus(snapshot, now: context.date)
                        if let message = store.message { Notice(title: "Couldn’t update", text: message) }
                        if snapshot.isStale(at: context.date) {
                            Notice(title: "Showing saved usage", text: "Keep Costbar running on your Mac for fresh updates.")
                        }
                        if agentsOnly {
                            agentList(snapshot, now: context.date)
                        } else {
                            SpendOverview(snapshot: snapshot)
                            let agents = snapshot.providers.filter { !$0.quotas.isEmpty }
                            if !agents.isEmpty {
                                HStack {
                                    sectionTitle("AI allowances")
                                    Spacer()
                                    Button("See all", systemImage: "arrow.right") { tab = .usage }
                                        .font(.subheadline)
                                }
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                                    ForEach(agents.prefix(4)) { provider in
                                        Button { selectedProvider = provider } label: {
                                            AgentSummary(provider: provider, now: context.date)
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                            HStack {
                                sectionTitle("All sources")
                                Spacer()
                                Text("\(snapshot.providers.filter(\.available).count) of \(snapshot.providers.count) reporting")
                                    .font(.caption).foregroundStyle(Palette.muted)
                            }
                            if snapshot.providers.isEmpty {
                                Text("Add a provider in Costbar on your Mac to start tracking usage.")
                                    .font(.subheadline).foregroundStyle(.secondary).card()
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(snapshot.providers.enumerated()), id: \.element.id) { index, provider in
                                        if index > 0 { Divider().padding(.leading, 62) }
                                        Button { selectedProvider = provider } label: {
                                            SourceRow(provider: provider)
                                        }.buttonStyle(.plain)
                                    }
                                }.card(padding: 0)
                            }
                        }
                    } else {
                        onboarding
                    }
                    Text("From your Mac · Pull down to refresh")
                        .font(.caption2).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity).padding(.top, 4)
                }.padding(.horizontal, 20).padding(.bottom, 28).padding(.top, 8)
            }
        }
        .background(Palette.background)
        .refreshable { _ = await store.refresh() }
    }

    private func syncStatus(_ snapshot: UsageSnapshot, now: Date) -> some View {
        HStack(spacing: 7) {
            Image(systemName: snapshot.isStale(at: now) ? "clock" : "checkmark.icloud")
                .foregroundStyle(snapshot.isStale(at: now) ? .orange : Palette.green)
            Text(snapshot.isStale(at: now) ? "Last synced" : "Synced")
            Text(snapshot.generatedAt, style: .relative)
            Spacer(minLength: 0)
            if store.isPreview { Text("SAMPLE").foregroundStyle(.orange) }
        }.font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func agentList(_ snapshot: UsageSnapshot, now: Date) -> some View {
        let agents = snapshot.providers.filter { !$0.quotas.isEmpty }
        if agents.isEmpty {
            ContentUnavailableView("No allowances yet", systemImage: "terminal", description: Text("Enable Codex or Claude tracking in Costbar on your Mac. Their quota windows will appear here."))
        } else {
            Text("Your subscription windows, at a glance.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(agents) { provider in
                VStack(alignment: .leading, spacing: 20) {
                    Button { selectedProvider = provider } label: {
                        HStack(spacing: 12) {
                            SourceIcon(name: provider.name)
                            ProviderName(name: provider.name)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                        }
                    }.buttonStyle(.plain)
                    if !provider.available { Notice(title: "Source unavailable", text: "Check this account in Costbar on your Mac.") }
                    ForEach(provider.quotas) { quota in
                        QuotaRow(quota: quota, now: now,
                                 stale: !provider.available || now.timeIntervalSince(provider.updatedAt) >= UsageSnapshot.freshnessInterval)
                    }
                }.card()
            }
            Button { tab = .settings } label: {
                Label(store.alertsEnabled ? "Alerts at \(store.threshold)% used" : "Get notified before you run out", systemImage: "bell.badge")
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(16)
            }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: Layout.cornerRadius)).tint(Palette.blue)
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 44)).foregroundStyle(Palette.blue).padding(.top, 24)
            Text("Your usage,\nwherever you are.").font(.largeTitle.bold())
            Text("Connect to Costbar on your Mac to see spending, follow AI allowances, and get usage alerts.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 20) {
                setupStep("1", title: "Use the same Apple Account", detail: "Sign in to iCloud on your Mac and iPhone.")
                setupStep("2", title: "Enable sync on your Mac", detail: "Costbar → Settings → General → iPhone companion.")
                setupStep("3", title: "Keep an eye on usage", detail: "Add a widget or turn on quota alerts in Settings.")
            }.card()
            if let message = store.message { Notice(title: "Connection status", text: message) }
            Button { Task { await store.connect() } } label: {
                Text(store.refreshing ? "Connecting…" : "Connect to my Mac").frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: Layout.cornerRadius)).disabled(store.refreshing)
        }
    }

    private func setupStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.caption.bold()).foregroundStyle(Palette.blue)
                .frame(width: 26, height: 26).background(Palette.blue.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var settings: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.alertsEnabled }, set: { enabled in
                    if enabled { Task { await store.enableAlerts() } } else { store.alertsEnabled = false }
                })) { Label("Quota alerts", systemImage: "bell.badge") }
                .disabled(store.requestingNotificationPermission)
                Picker("Notify when usage reaches", selection: $store.threshold) {
                    ForEach([50, 75, 80, 90, 95, 100], id: \.self) { Text("\($0)%").tag($0) }
                }.disabled(!store.alertsEnabled)
                if store.notificationsDenied {
                    Button("Allow notifications in iPhone Settings", systemImage: "arrow.up.forward.app") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button("Send a test notification", systemImage: "paperplane") {
                    Task { await store.sendTestNotification() }
                }.disabled(!store.notificationsAllowed)
                if let feedback = store.notificationFeedback {
                    Text(feedback).font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Stay ahead of your limit") } footer: {
                Text("One alert per quota window at your chosen threshold. iOS manages background delivery, so alerts may be delayed.")
            }
            Section {
                Label("Home Screen", systemImage: "square.grid.2x2")
                Text("Touch and hold the Home Screen, tap Edit → Add Widget, then search for Costbar.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Label("Lock Screen", systemImage: "lock.rectangle")
                Text("Touch and hold your Lock Screen, tap Customize, then add a Costbar widget.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } header: { Text("Usage without opening the app") } footer: {
                Text("Widgets show the latest synced costs and allowances, with their age.")
            }
            Section("Connection") {
                LabeledContent("Source", value: "Costbar on your Mac")
                if let snapshot = store.snapshot {
                    LabeledContent("Last snapshot") { Text(snapshot.generatedAt, format: .dateTime.hour().minute()).foregroundStyle(.secondary) }
                }
                Button("Sync now", systemImage: "arrow.clockwise") { Task { await store.connect() } }
                    .disabled(store.refreshing)
                if let message = store.backgroundMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let message = store.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            Section {
                Label("Credentials stay on your Mac", systemImage: "lock.shield")
                    .font(.subheadline.weight(.medium))
                Text("Only usage summaries are shared through your private iCloud account. Update provider tokens in Costbar on your Mac; the refreshed usage syncs here.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("To disconnect, turn off iPhone sync on your Mac. This phone clears its saved snapshot on the next successful sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden).background(Palette.background)
        .navigationTitle("Settings")
        .task { await store.refreshNotificationStatus() }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline)
    }
}

private struct SpendOverview: View {
    let snapshot: UsageSnapshot
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("MONTH TO DATE").font(.caption.weight(.semibold)).tracking(1.3).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(Palette.blue)
            }
            if snapshot.totals.isEmpty {
                Text("No billing data yet").font(.title2.weight(.semibold))
                Text("AI subscription allowances are tracked separately below.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(snapshot.totals) { total in
                VStack(alignment: .leading, spacing: 14) {
                    Text(total.formatted).font(.system(size: amountSize, weight: .semibold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                    if let projected = total.projectedFormatted {
                        HStack {
                            Text("Month-end estimate").foregroundStyle(.secondary)
                            Spacer()
                            Text(projected).fontWeight(.medium).monospacedDigit()
                        }.font(.subheadline)
                    }
                }
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Palette.blue.opacity(0.15), Palette.raised], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

private struct SourceIcon: View {
    let name: String
    private var symbol: String {
        let name = name.lowercased()
        if name.contains("claude") { return "sparkle" }
        if name.contains("codex") || name.contains("opencode") { return "terminal" }
        if name.contains("cloudflare") { return "cloud" }
        if name.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        return "server.rack"
    }
    var body: some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.blue)
            .frame(width: 38, height: 38).background(Palette.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct ProviderName: View {
    let name: String
    var body: some View {
        let parts = name.components(separatedBy: " · ")
        VStack(alignment: .leading, spacing: 3) {
            Text(parts.first ?? name).font(.headline)
            if parts.count > 1 {
                Text(parts.dropFirst().joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SourceRow: View {
    let provider: UsageSnapshot.Provider
    var body: some View {
        HStack(spacing: 12) {
            SourceIcon(name: provider.name)
            ProviderName(name: provider.name)
            VStack(alignment: .trailing, spacing: 3) {
                if !provider.available {
                    Text("Unavailable").foregroundStyle(.orange)
                } else if let total = provider.totals.first {
                    Text(total.formatted).monospacedDigit()
                    if provider.totals.count > 1 { Text("+\(provider.totals.count - 1) currencies").font(.caption2).foregroundStyle(.secondary) }
                } else { Text(provider.quotas.isEmpty ? "No quota data" : "Allowances").foregroundStyle(.secondary) }
            }.font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Palette.muted)
        }.padding(16).contentShape(Rectangle())
    }
}

private struct AgentSummary: View {
    let provider: UsageSnapshot.Provider
    let now: Date
    private var quota: UsageSnapshot.Quota? {
        provider.quotas.filter { $0.isActive(at: now) }.max { $0.usedPercent < $1.usedPercent }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SourceIcon(name: provider.name)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Palette.muted)
            }
            Text(provider.name.components(separatedBy: " · ").first ?? provider.name).font(.headline).lineLimit(1)
            if provider.available, now.timeIntervalSince(provider.updatedAt) < UsageSnapshot.freshnessInterval, let quota {
                Text("\(quota.usedPercent.formatted(.number.precision(.fractionLength(0))))%")
                    .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
                ProgressView(value: min(quota.usedPercent, 100), total: 100).tint(quota.usedPercent >= 80 ? .orange : Palette.blue)
                Text("\(quota.label) used").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("—").font(.system(.title, design: .rounded, weight: .semibold))
                ProgressView(value: 0, total: 100).tint(.gray).opacity(0.35)
                Text(provider.available ? "Awaiting refresh" : "Check on your Mac").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 16)
    }
}

private struct QuotaRow: View {
    let quota: UsageSnapshot.Quota
    let now: Date
    let stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.label).fontWeight(.medium)
                Spacer()
                Text(quota.isActive(at: now) ? "\(quota.usedPercent.formatted(.number.precision(.fractionLength(0))))% used" : "Awaiting refresh")
                    .foregroundStyle(stale ? .secondary : .primary).monospacedDigit()
            }.font(.subheadline)
            if quota.isActive(at: now) {
                ProgressView(value: min(quota.usedPercent, 100), total: 100)
                    .tint(stale ? .gray : quota.usedPercent >= 80 ? .orange : Palette.blue)
            }
            HStack {
                if stale { Text("Last reported usage").foregroundStyle(.orange) }
                else if let reset = quota.resetsAt, reset > now {
                    Text("Resets in")
                    Text(reset, style: .relative)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

private struct ProviderDetail: View {
    let providerID: String
    @ObservedObject var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let provider = store.snapshot?.providers.first(where: { $0.id == providerID }) {
                        VStack(alignment: .leading, spacing: 24) {
                            HStack(spacing: 12) { SourceIcon(name: provider.name); ProviderName(name: provider.name) }
                            if !provider.available {
                                Notice(title: "This source needs attention", text: "Open this provider in Costbar on your Mac to check its credentials and connection. After saving, its usage syncs here.")
                            }
                            ForEach(provider.totals) { total in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Month to date · \(total.currency)").font(.subheadline).foregroundStyle(.secondary)
                                    Text(total.formatted).font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                                    if let projected = total.projectedFormatted { Text("Month-end estimate \(projected)").font(.subheadline).foregroundStyle(.secondary) }
                                }.card()
                            }
                            ForEach(provider.quotas) { quota in
                                QuotaRow(quota: quota, now: context.date, stale: !provider.available || context.date.timeIntervalSince(provider.updatedAt) >= UsageSnapshot.freshnessInterval).card()
                            }
                            if provider.available && provider.totals.isEmpty && provider.quotas.isEmpty {
                                Notice(title: "No allowance or billing data", text: "This source hasn’t reported a spending total or quota window yet.")
                            }
                            Label {
                                Text("Updated \(provider.updatedAt, style: .relative) ago")
                            } icon: { Image(systemName: "clock") }
                            .font(.caption).foregroundStyle(.secondary)
                            Button("Refresh usage", systemImage: "arrow.clockwise") { Task { _ = await store.refresh() } }
                                .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: Layout.cornerRadius)).disabled(store.refreshing)
                        }.padding(20)
                    } else { ContentUnavailableView("Source removed", systemImage: "server.rack", description: Text("This source is no longer in your Mac’s latest snapshot.")) }
                }
            }.background(Palette.background)
            .navigationTitle("Source details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(Palette.blue)
    }
}

private struct Notice: View {
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle").foregroundStyle(Palette.blue)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 16)
    }
}

private extension View {
    func card(padding: CGFloat = 20) -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading).padding(padding)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}
