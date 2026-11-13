import PulseCore
import SwiftUI

/// One provider's full forecast: the same view as the CLIProxyAPI pool card.
struct QuotaDetailView: View {
    @Environment(AppStore.self) private var store
    let pool: PoolSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection {
                header
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.percent(pool.remainingNow))
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("of \(Format.percent(pool.capacity)) left").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .padding(.top, 10)
                PoolChart(pool: pool, detailed: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                stats
            }
            PanelDivider()
            PanelSection {
                SectionHeader("Accounts")
                ForEach(pool.accounts) { AccountRow(account: $0, pool: pool) }
                Text("Projected with \(Format.strategy(pool.strategy).lowercased()) routing.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 4).padding(.top, 8)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button { store.route = .main } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            ProviderGlyph(provider: pool.provider)
            Text(pool.displayName).font(.system(size: 13.5, weight: .semibold))
            Text(pool.accounts.count == 1 ? "1 account" : "\(pool.accounts.count) accounts")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
            Spacer()
            Button { store.openCLIProxy() } label: {
                HStack(spacing: 3) {
                    Text("CLIProxyAPI")
                    Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private var stats: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatCell(
                    label: "Pool empty",
                    value: pool.projection.poolEmptyAt.map { Format.when($0, now: pool.nowMs) }
                        ?? "Not by \(Format.date(pool.projection.horizonMs))"
                )
                StatCell(
                    label: "First empty",
                    value: pool.firstEmptyAccount?.displayName ?? "None",
                    detail: pool.projection.firstEmpty.map { Format.until($0.t, now: pool.nowMs) }
                )
            }
            GridRow {
                StatCell(
                    label: "Next reset",
                    value: pool.nextReset.map { Format.when($0.t, now: pool.nowMs) } ?? "None soon",
                    detail: pool.nextReset.map { "adds \(Format.percent($0.amount))" },
                    detailTint: .provider(pool.provider)
                )
                StatCell(label: "Burn, last \(pool.burnWindowHours.formatted())h", value: String(format: "%.1f%%/h", pool.burnPerHour))
            }
            GridRow {
                StatCell(
                    label: "Lost at resets, \(Int(PoolSummary.projectionDays)) days",
                    value: Format.percent(pool.projection.wastedAtResets)
                )
                StatCell(label: "Routing", value: Format.strategy(pool.strategy))
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
    }
}

private struct AccountRow: View {
    let account: PoolAccount
    let pool: PoolSummary

    private var isNext: Bool { account.id == pool.accounts.first?.id }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(account.displayName).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if account.unavailable {
                        Text("Cooling down").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.orange)
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Color.provider(pool.provider))
                            .frame(width: geometry.size.width * CGFloat(account.remainingNow / 100))
                    }
                }
                .frame(height: 4)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.percent(account.remainingNow)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(account.nextResetMs.map { Format.whenShort($0, now: pool.nowMs) } ?? "Not started")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isNext ? AnyShapeStyle(Color.provider(pool.provider)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}
