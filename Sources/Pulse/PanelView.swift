import PulseCore
import SwiftUI

/// The window under the menubar item. The main list and a provider's quota
/// detail share it; the detail slides in like a Control Center module.
struct PanelView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack(alignment: .top) {
            switch store.route {
            case .main:
                MainPanel()
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
            case .quota(let provider):
                if let pool = store.pools.first(where: { $0.provider == provider }) {
                    QuotaDetailView(pool: pool)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: store.route)
        .frame(width: 340)
        .padding(6)
        .onAppear { store.panelDidOpen() }
        .onDisappear { store.panelDidClose() }
    }
}

private struct MainPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThreadsSection()
            PanelDivider()
            QuotaSections()
            PanelDivider()
            PanelFooter()
        }
    }
}

// MARK: - Threads

private struct ThreadsSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        switch store.t3Status {
        case .notConfigured, .expired:
            PanelSection {
                NoticeCard(
                    symbol: "link",
                    title: store.t3Status == .expired ? "Sign in to T3 Code again" : "Connect T3 Code",
                    message: store.t3Status == .expired
                        ? "T3's sign-in lasts 30 days. Approve Pulse again to keep seeing your threads."
                        : "Pulse reads your threads through T3's own sign-in, with read-only access.",
                    tint: .accentColor
                ) {
                    Button(store.t3Connecting ? "Waiting for T3 Code…" : "Connect…") { store.connectT3() }
                        .buttonStyle(.glass)
                        .disabled(store.t3Connecting)
                }
            }
        default:
            if !store.waitingThreads.isEmpty {
                PanelSection {
                    SectionHeader("Waiting for you")
                    VStack(spacing: 8) {
                        ForEach(store.waitingThreads) { WaitingCard(thread: $0) }
                    }
                }
                PanelDivider()
            }
            PanelSection {
                SectionHeader("Running") {
                    if case .error(let message) = store.t3Status {
                        Text(message).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                if store.runningThreads.isEmpty && store.recentlyFinished.isEmpty {
                    Text(store.t3Status == .loading ? "Loading threads…" : "Nothing running right now.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 6).padding(.vertical, 6)
                }
                ForEach(store.runningThreads) { ThreadRow(thread: $0) }
                ForEach(store.recentlyFinished.prefix(3)) { ThreadRow(thread: $0) }
            }
        }
    }
}

private struct WaitingCard: View {
    @Environment(AppStore.self) private var store
    let thread: T3Thread

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: "hand.raised.fill", tint: .orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(thread.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 12) {
                        if let project = thread.projectTitle { MetaLabel(symbol: "folder", text: project) }
                        MetaLabel(symbol: thread.isLocalEnvironment ? "laptopcomputer" : "server.rack", text: thread.environmentLabel)
                        MetaLabel(symbol: "clock", text: Format.age(thread.updatedAt, now: store.now))
                    }
                }
            }
            HStack {
                Text(thread.modelDisplay).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    store.open(thread)
                } label: {
                    Label("Open in T3", systemImage: "arrow.up.forward").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.8), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

private struct ThreadRow: View {
    @Environment(AppStore.self) private var store
    let thread: T3Thread

    var body: some View {
        RowButton(action: { store.open(thread) }) {
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(thread.isFinished ? .secondary : .primary)
                        .lineLimit(1)
                    subtitle
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(thread.isFinished ? Format.age(thread.updatedAt, now: store.now) : thread.modelDisplay)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                    MetaLabel(symbol: thread.isLocalEnvironment ? "laptopcomputer" : "server.rack", text: thread.environmentLabel)
                        .font(.system(size: 11))
                }
            }
        }
    }

    @ViewBuilder private var avatar: some View {
        if thread.isFinished {
            IconTile(
                symbol: thread.status == "completed" ? "checkmark" : thread.status == "failed" ? "xmark" : "stop.fill",
                tint: thread.status == "completed" ? .green : thread.status == "failed" ? .red : .secondary,
                size: 28
            )
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(avatarGradient)
                .overlay {
                    Text(String((thread.projectTitle ?? thread.title).prefix(1)).uppercased())
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
        }
    }

    private var avatarGradient: LinearGradient {
        let palette: [Color] = [.indigo, .green, .blue, .purple, .pink, .teal, .orange, .mint]
        let seed = (thread.projectTitle ?? thread.projectId).unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let base = palette[abs(seed) % palette.count]
        return LinearGradient(colors: [base, base.mix(with: .black, by: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder private var subtitle: some View {
        let project = thread.projectTitle ?? "No project"
        switch thread.status {
        case "completed": MetaLabel(symbol: "folder", text: "Finished in \(project)")
        case "failed": MetaLabel(symbol: "folder", text: "Failed in \(project)")
        case "interrupted": MetaLabel(symbol: "folder", text: "Stopped in \(project)")
        case "queued", "preparing", "starting": MetaLabel(symbol: "folder", text: "Starting in \(project)")
        default: MetaLabel(symbol: "folder", text: project)
        }
    }
}

// MARK: - Quota

private struct QuotaSections: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        PanelSection {
            switch store.quotaStatus {
            case .notConfigured:
                NoticeCard(
                    symbol: "gauge.with.dots.needle.33percent",
                    title: "Add CLIProxyAPI",
                    message: "Pulse needs your CLIProxyAPI address and management key to show quota.",
                    tint: .accentColor
                ) {
                    SettingsLink { Text("Open Settings…") }.buttonStyle(.glass)
                }
            default:
                if let primary = store.pools.first {
                    PrimaryPool(pool: primary)
                    ForEach(store.pools.dropFirst()) { CompactPoolRow(pool: $0) }
                } else if case .error(let message) = store.quotaStatus {
                    NoticeCard(symbol: "exclamationmark.triangle", title: "Quota unavailable", message: message, tint: .orange) {
                        EmptyView()
                    }
                } else {
                    Text("Loading quota…").font(.system(size: 12)).foregroundStyle(.tertiary).padding(6)
                }
            }
        }
    }
}

private struct PrimaryPool: View {
    @Environment(AppStore.self) private var store
    let pool: PoolSummary
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ProviderGlyph(provider: pool.provider)
                Text(pool.displayName).font(.system(size: 13.5, weight: .semibold))
                Text("\(pool.accounts.count) accounts").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
                StaleBadge()
            }
            .padding(.horizontal, 4)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.percent(pool.remainingNow))
                    .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(store.isPoolLow ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Text("of \(Format.percent(pool.capacity)) left").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)

            Button {
                store.route = .quota(pool.provider)
            } label: {
                PoolChart(pool: pool)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Show the full forecast")
            .padding(.top, 2)

            HStack(alignment: .top, spacing: 8) {
                StatCell(
                    label: "Pool empty",
                    value: pool.projection.poolEmptyAt.map { Format.whenShort($0, now: pool.nowMs) }
                        ?? "Not by \(Format.date(pool.projection.horizonMs))"
                )
                StatCell(
                    label: "Next reset",
                    value: pool.nextReset.map { Format.whenShort($0.t, now: pool.nowMs) } ?? "None soon",
                    detail: pool.nextReset.map { "adds \(Format.percent($0.amount))" },
                    detailTint: .provider(pool.provider)
                )
                StatCell(label: "Burn", value: String(format: "%.1f%%/h", pool.burnPerHour), detail: "last \(pool.burnWindowHours.formatted())h")
            }
            .padding(.horizontal, 4)
            .padding(.top, 10)
        }
    }
}

private struct CompactPoolRow: View {
    @Environment(AppStore.self) private var store
    let pool: PoolSummary

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6).padding(.vertical, 8)
            RowButton(action: { store.route = .quota(pool.provider) }) {
                HStack(spacing: 8) {
                    ProviderGlyph(provider: pool.provider, size: 12)
                    Text(pool.displayName).font(.system(size: 13, weight: .medium))
                    Text(pool.accounts.count == 1 ? "1 account" : "\(pool.accounts.count) accounts")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(Format.percent(pool.remainingNow)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("of \(Format.percent(pool.capacity))").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Shows when quota data is older than the last successful refresh should be.
private struct StaleBadge: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if case .error(let message) = store.quotaStatus, let updated = store.quotaUpdatedAt {
            Label("Updated \(Format.age(updated, now: store.now)) ago", systemImage: "wifi.exclamationmark")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .help(message)
        }
    }
}

// MARK: - Footer

private struct PanelFooter: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 6) {
            Button { store.openT3() } label: {
                HStack(spacing: 7) {
                    Text("T3 Code")
                    Text("⌘1").foregroundStyle(.tertiary)
                }
            }
            .keyboardShortcut("1")
            Button { store.openCLIProxy() } label: {
                HStack(spacing: 7) {
                    Text("CLIProxyAPI")
                    Text("⌘2").foregroundStyle(.tertiary)
                }
            }
            .keyboardShortcut("2")
            Spacer()
            Menu {
                Button("Refresh Now") { store.refreshAll() }.keyboardShortcut("r")
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                Divider()
                Button("Quit Pulse") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
