import Foundation

/// Everything the UI shows for one provider's pool, computed the way the
/// management center's `PoolCard` does.
public struct PoolSummary: Sendable, Identifiable, Equatable {
    public var id: String { provider }
    public var provider: String
    public var strategy: String
    public var nowMs: Double
    public var rangeFromMs: Double
    public var rangeToMs: Double
    /// Accounts in routing order (rank 1 drains first).
    public var accounts: [PoolAccount]
    public var capacity: Double
    public var remainingNow: Double
    public var burnPerHour: Double
    public var burnWindowHours: Double
    /// Recorded pool level over [rangeFrom, now].
    public var recorded: [SeriesPoint]
    /// Projected pool level over [now, rangeTo].
    public var projected: [SeriesPoint]
    public var projection: PoolProjection
    public var nextReset: TimedAmount?
    public var recordedResets: [TimedAmount]
    public var projectedResets: [TimedAmount]
    public static let projectionDays = 14.0

    public var fractionLeft: Double { capacity > 0 ? remainingNow / capacity : 0 }

    public var displayName: String {
        switch provider {
        case "claude": "Claude"
        case "codex": "Codex"
        case "gemini", "gemini-cli": "Gemini"
        case "antigravity": "Antigravity"
        case "xai": "Grok"
        case "kimi": "Kimi"
        default: provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    public var firstEmptyAccount: PoolAccount? {
        guard let id = projection.firstEmpty?.accountId else { return nil }
        return accounts.first { $0.id == id }
    }

    public static func build(
        provider: String,
        credentials: [QuotaCredential],
        strategy: String,
        nowMs: Double,
        burnWindowHours: Double,
        calendar: Calendar = .current
    ) -> PoolSummary? {
        let range = PoolMath.visibleRange(nowMs: nowMs, calendar: calendar)
        let burnWindowMs = burnWindowHours * PoolMath.hourMs
        let historyFrom = min(range.fromMs, nowMs - max(burnWindowMs, PoolMath.dayMs))
        let accounts = PoolMath.buildPoolAccounts(credentials, fromMs: historyFrom, nowMs: nowMs)
        guard !accounts.isEmpty else { return nil }

        let capacity = PoolMath.poolCapacity(accounts)
        let recordedPool = PoolMath.sumSeries(accounts.map { ($0.recorded, $0.weight) })
        let burn = PoolMath.burnRatePerHour(accounts, nowMs: nowMs, windowMs: burnWindowMs)
        let horizonMs = max(range.toMs, nowMs + projectionDays * PoolMath.dayMs)
        let projection = PoolMath.projectPool(
            accounts, nowMs: nowMs, horizonMs: horizonMs, burnPerHour: burn, strategy: strategy
        )
        let remainingNow = accounts.reduce(0) { $0 + $1.remainingNow * $1.weight }
        let upcoming = projection.resets.filter { $0.t > nowMs }.map { TimedAmount(t: $0.t, amount: $0.amount) }

        return PoolSummary(
            provider: provider,
            strategy: strategy,
            nowMs: nowMs,
            rangeFromMs: range.fromMs,
            rangeToMs: range.toMs,
            accounts: accounts.sorted { ($0.rank == 0 ? Int.max : $0.rank) < ($1.rank == 0 ? Int.max : $1.rank) },
            capacity: capacity,
            remainingNow: remainingNow,
            burnPerHour: burn,
            burnWindowHours: burnWindowHours,
            recorded: PoolMath.clipSeries(recordedPool, fromMs: range.fromMs, toMs: nowMs),
            projected: PoolMath.clipSeries(projection.pool, fromMs: nowMs, toMs: range.toMs),
            projection: projection,
            nextReset: PoolMath.mergeNearbyResets(upcoming, withinMs: PoolMath.minuteMs).first,
            recordedResets: PoolMath.recordedResets(accounts, fromMs: range.fromMs, nowMs: nowMs),
            projectedResets: PoolMath.mergeNearbyResets(upcoming.filter { $0.t <= range.toMs })
        )
    }

    /// One summary per provider with enabled credentials, Claude first.
    public static func buildAll(
        _ history: QuotaHistory,
        nowMs: Double,
        burnWindowHours: Double
    ) -> [PoolSummary] {
        let order = ["claude", "codex"]
        let grouped = Dictionary(grouping: history.credentials.filter { !$0.disabled }, by: \.provider)
        let providers = grouped.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count
            let ib = order.firstIndex(of: b) ?? order.count
            return ia != ib ? ia < ib : a < b
        }
        return providers.compactMap { provider in
            build(
                provider: provider,
                credentials: grouped[provider] ?? [],
                strategy: history.routingStrategy,
                nowMs: nowMs,
                burnWindowHours: burnWindowHours
            )
        }
    }
}
