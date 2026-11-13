import Foundation

/// Quota pool forecast: recorded pool level and a strategy-aware projection.
///
/// A line-for-line port of the management center's
/// `src/features/quota/pool/poolModel.ts`, so Pulse shows the same numbers as
/// the CLIProxyAPI quota page. Pure functions; `nowMs` is always passed in.
///
/// Units: an account's own level is 0...100 (% of its window left). The pool is
/// the weighted sum of account levels, so four equal accounts span 0...400.
public struct SeriesPoint: Sendable, Equatable {
    public var t: Double
    public var v: Double
    public init(t: Double, v: Double) {
        self.t = t
        self.v = v
    }
}

public struct PoolAccount: Sendable, Equatable, Identifiable {
    public var id: String
    public var authIndex: String
    public var name: String
    public var email: String
    public var label: String
    public var planType: String
    /// Capacity multiplier: one account at weight 1 contributes 100 to the pool.
    public var weight: Double
    public var priority: Double
    public var rank: Int
    public var tier: RoutingTier
    public var windowId: String?
    public var periodMs: Double
    /// Own level now, 0...100.
    public var remainingNow: Double
    /// Next reset after now, or nil when the window has not started.
    public var nextResetMs: Double?
    /// Recorded own level; equal consecutive timestamps encode a jump.
    public var recorded: [SeriesPoint]
    public var unavailable: Bool

    public var displayName: String {
        if !label.isEmpty { return label }
        if !email.isEmpty { return email }
        return name
    }
}

public struct PoolReset: Sendable, Equatable {
    public var t: Double
    public var accountId: String
    /// Pool units refilled.
    public var amount: Double
    /// Pool units still unused when the window reset (lost).
    public var wasted: Double
}

public struct PoolProjection: Sendable, Equatable {
    public var pool: [SeriesPoint]
    public var perAccount: [String: [SeriesPoint]]
    public var resets: [PoolReset]
    public var poolEmptyAt: Double?
    public var firstEmpty: (t: Double, accountId: String)?
    public var wastedAtResets: Double
    public var horizonMs: Double

    public static func == (lhs: PoolProjection, rhs: PoolProjection) -> Bool {
        lhs.pool == rhs.pool && lhs.resets == rhs.resets && lhs.poolEmptyAt == rhs.poolEmptyAt
            && lhs.firstEmpty?.t == rhs.firstEmpty?.t && lhs.firstEmpty?.accountId == rhs.firstEmpty?.accountId
            && lhs.wastedAtResets == rhs.wastedAtResets && lhs.horizonMs == rhs.horizonMs
    }
}

public struct TimedAmount: Sendable, Equatable {
    public var t: Double
    public var amount: Double
}

public enum PoolMath {
    public static let minuteMs = 60_000.0
    public static let hourMs = 60 * minuteMs
    public static let dayMs = 24 * hourMs
    public static let weekMs = 7 * dayMs
    static let epsilon = 1e-6
    static let projectionStepMs = 15 * minuteMs
    /// Window ids ordered from the longest to the shortest known window.
    static let windowPreference = ["7d", "secondary", "primary", "5h"]

    static func clampLevel(_ value: Double) -> Double { min(100, max(0, value)) }

    /// The window soonest-reset-first routing orders by: the longest one.
    public static func routingWindowId(_ credential: QuotaCredential) -> String? {
        if let id = credential.routing.windowId { return id }
        var bestId: String?
        var bestMinutes = -1.0
        for window in credential.windows {
            let minutes = window.windowMinutes ?? 0
            if minutes > bestMinutes {
                bestId = window.id
                bestMinutes = minutes
            }
        }
        if let bestId { return bestId }
        let sampled = Set(credential.samples.flatMap { $0.windows.keys })
        return windowPreference.first { sampled.contains($0) }
    }

    static func windowPeriodMs(_ credential: QuotaCredential, _ windowId: String?) -> Double {
        if let window = credential.windows.first(where: { $0.id == windowId }),
           let minutes = window.windowMinutes, minutes > 0 {
            return minutes * minuteMs
        }
        if windowId == "5h" { return 5 * hourMs }
        return weekMs
    }

    /// Rebuilds an account's own level over [fromMs, nowMs] from sparse samples.
    /// Usage is interpolated linearly between samples; a reset recorded on a sample
    /// that falls before the next sample becomes a jump back to 100. The next window
    /// only opens on the next request, so no further resets are invented.
    public static func buildRecordedSeries(
        _ credential: QuotaCredential,
        windowId: String?,
        fromMs: Double,
        nowMs: Double,
        remainingNow: Double
    ) -> [SeriesPoint] {
        struct Level { var t: Double; var v: Double; var reset: Double? }
        let samples: [Level] = credential.samples.compactMap { sample in
            guard let windowId, let window = sample.windows[windowId] else { return nil }
            return Level(t: sample.atMs, v: clampLevel(100 - window.used), reset: window.resetAtMs)
        }.filter { $0.t <= nowMs }

        if samples.isEmpty {
            return [SeriesPoint(t: fromMs, v: remainingNow), SeriesPoint(t: nowMs, v: remainingNow)]
        }

        var points: [SeriesPoint] = []
        func holdThroughReset(_ start: Level, until untilMs: Double) -> Double {
            guard let reset = start.reset, reset <= untilMs else { return start.v }
            points.append(SeriesPoint(t: reset, v: start.v))
            points.append(SeriesPoint(t: reset, v: 100))
            return 100
        }

        for (index, sample) in samples.enumerated() {
            if index == 0 {
                points.append(SeriesPoint(t: sample.t, v: sample.v))
                continue
            }
            let previous = samples[index - 1]
            if let reset = previous.reset, reset > previous.t, reset < sample.t {
                _ = holdThroughReset(previous, until: sample.t - 1)
            }
            points.append(SeriesPoint(t: sample.t, v: sample.v))
        }

        let last = samples[samples.count - 1]
        let endLevel: Double
        if let reset = last.reset, reset > last.t {
            endLevel = holdThroughReset(last, until: nowMs)
        } else {
            endLevel = last.v
        }
        points.append(SeriesPoint(t: nowMs, v: endLevel))
        return clipSeries(points, fromMs: fromMs, toMs: nowMs)
    }

    /// Restricts a series to [fromMs, toMs], interpolating the boundary values.
    public static func clipSeries(_ points: [SeriesPoint], fromMs: Double, toMs: Double) -> [SeriesPoint] {
        guard !points.isEmpty else { return [] }
        var out = [SeriesPoint(t: fromMs, v: valueAt(points, fromMs, side: .right))]
        for point in points where point.t > fromMs && point.t < toMs {
            out.append(point)
        }
        out.append(SeriesPoint(t: toMs, v: valueAt(points, toMs, side: .left)))
        return out
    }

    public enum Side: Sendable { case left, right }

    /// Value of a piecewise-linear series at `t`. At a jump (equal timestamps),
    /// `.left` returns the level before it and `.right` the level after it.
    /// Outside the series the nearest end value is held.
    public static func valueAt(_ points: [SeriesPoint], _ t: Double, side: Side = .right) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if t < first.t { return first.v }
        if t > last.t { return last.v }
        var lo = 0
        var hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if points[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        if points[lo].t == t {
            if side == .left { return points[lo].v }
            var end = lo
            while end + 1 < points.count, points[end + 1].t == t { end += 1 }
            return points[end].v
        }
        let before = points[lo - 1]
        let after = points[lo]
        let span = after.t - before.t
        if span <= 0 { return after.v }
        return before.v + (after.v - before.v) * (t - before.t) / span
    }

    /// Weighted sum of several series at every breakpoint, keeping jumps.
    public static func sumSeries(_ series: [(points: [SeriesPoint], weight: Double)]) -> [SeriesPoint] {
        let times = Set(series.flatMap { $0.points.map(\.t) }).sorted()
        var out: [SeriesPoint] = []
        for t in times {
            var left = 0.0
            var right = 0.0
            for item in series {
                left += valueAt(item.points, t, side: .left) * item.weight
                right += valueAt(item.points, t, side: .right) * item.weight
            }
            out.append(SeriesPoint(t: t, v: left))
            if abs(right - left) > epsilon { out.append(SeriesPoint(t: t, v: right)) }
        }
        return out
    }

    /// Level consumed within [fromMs, toMs], ignoring reset jumps.
    public static func consumedBetween(_ points: [SeriesPoint], fromMs: Double, toMs: Double) -> Double {
        guard points.count >= 2, toMs > fromMs else { return 0 }
        var consumed = 0.0
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            if end.t <= start.t { continue }
            let a = max(start.t, fromMs)
            let b = min(end.t, toMs)
            if b <= a { continue }
            let drop = valueAt([start, end], a) - valueAt([start, end], b)
            if drop > 0 { consumed += drop }
        }
        return consumed
    }

    /// Pool units per hour consumed over the trailing window ending at `nowMs`.
    public static func burnRatePerHour(_ accounts: [PoolAccount], nowMs: Double, windowMs: Double) -> Double {
        guard windowMs > 0 else { return 0 }
        let fromMs = nowMs - windowMs
        let consumed = accounts.reduce(0.0) { sum, account in
            sum + consumedBetween(account.recorded, fromMs: fromMs, toMs: nowMs) * account.weight
        }
        return consumed / (windowMs / hourMs)
    }

    /// Normalizes backend credentials of one provider into pool accounts.
    public static func buildPoolAccounts(
        _ credentials: [QuotaCredential],
        fromMs: Double,
        nowMs: Double,
        planWeights: [String: Double] = [:]
    ) -> [PoolAccount] {
        credentials.filter { !$0.disabled }.map { credential in
            let windowId = routingWindowId(credential)
            let periodMs = windowPeriodMs(credential, windowId)
            let current = credential.windows.first { $0.id == windowId }
            let resetMs = current?.resetAtMs ?? credential.routing.resetAtMs
            let expired = resetMs.map { $0 <= nowMs } ?? false
            let remainingNow = current != nil && !expired ? clampLevel(100 - current!.usedPercent) : 100
            let weight = planWeights[credential.planType].flatMap { $0 > 0 ? $0 : nil } ?? 1
            return PoolAccount(
                id: credential.authId,
                authIndex: credential.authIndex,
                name: credential.name,
                email: credential.email,
                label: credential.label,
                planType: credential.planType,
                weight: weight,
                priority: credential.priority,
                rank: credential.routing.rank,
                tier: credential.routing.tier,
                windowId: windowId,
                periodMs: periodMs,
                remainingNow: remainingNow,
                // A reset that already passed means the next window has not opened yet.
                nextResetMs: resetMs.flatMap { $0 > nowMs ? $0 : nil },
                recorded: buildRecordedSeries(
                    credential, windowId: windowId, fromMs: fromMs, nowMs: nowMs, remainingNow: remainingNow
                ),
                unavailable: credential.unavailable
            )
        }
    }

    public static func poolCapacity(_ accounts: [PoolAccount]) -> Double {
        accounts.reduce(0) { $0 + 100 * $1.weight }
    }

    struct SimAccount {
        var account: PoolAccount
        var capacity: Double
        var level: Double
        var nextResetMs: Double?
    }

    /// Indices of `accounts` in the order the routing strategy drains them.
    static func drainOrder(_ strategy: String, _ accounts: [SimAccount]) -> [Int] {
        let indices = Array(accounts.indices)
        func byId(_ a: Int, _ b: Int) -> Bool { accounts[a].account.id < accounts[b].account.id }
        if strategy == "soonest-reset-first" {
            return indices.sorted { a, b in
                let pa = accounts[a].account.priority
                let pb = accounts[b].account.priority
                if pa != pb { return pa > pb }
                let ra = accounts[a].nextResetMs
                let rb = accounts[b].nextResetMs
                if (ra != nil) != (rb != nil) { return ra != nil }
                if let ra, let rb, ra != rb { return ra < rb }
                return byId(a, b)
            }
        }
        return indices.sorted { a, b in
            let pa = accounts[a].account.priority
            let pb = accounts[b].account.priority
            if pa != pb { return pa > pb }
            return byId(a, b)
        }
    }

    /// Drains `demand` pool units and returns what could not be served.
    static func distributeDemand(_ strategy: String, _ accounts: inout [SimAccount], _ demand: Double) -> Double {
        var remaining = demand
        if strategy == "soonest-reset-first" || strategy == "fill-first" {
            for index in drainOrder(strategy, accounts) {
                if remaining <= epsilon { break }
                if accounts[index].level <= epsilon { continue }
                let take = min(accounts[index].level, remaining)
                accounts[index].level -= take
                remaining -= take
            }
            return remaining
        }
        // Round-robin style: an even split across the highest-priority accounts that
        // still have quota, spilling over as accounts run dry.
        var guardCount = 0
        while guardCount < 64, remaining > epsilon {
            guardCount += 1
            let live = accounts.indices.filter { accounts[$0].level > epsilon }
            guard !live.isEmpty else { break }
            let topPriority = live.map { accounts[$0].account.priority }.max()!
            let tier = live.filter { accounts[$0].account.priority == topPriority }
            let share = remaining / Double(tier.count)
            for index in tier {
                let take = min(accounts[index].level, share)
                accounts[index].level -= take
                remaining -= take
            }
        }
        return remaining
    }

    /// Simulates the pool from now to the horizon: demand drains accounts in the
    /// routing strategy's order, and each account refills at its reset. Windows
    /// that have not started open when first drained.
    public static func projectPool(
        _ accounts: [PoolAccount],
        nowMs: Double,
        horizonMs: Double,
        burnPerHour: Double,
        strategy: String
    ) -> PoolProjection {
        var sims = accounts.map {
            SimAccount(account: $0, capacity: 100 * $0.weight, level: $0.remainingNow * $0.weight, nextResetMs: $0.nextResetMs)
        }
        var pool: [SeriesPoint] = []
        var perAccount: [String: [SeriesPoint]] = [:]
        var resets: [PoolReset] = []
        var poolEmptyAt: Double?
        var firstEmpty: (t: Double, accountId: String)?
        var wastedAtResets = 0.0

        func record(_ t: Double) {
            pool.append(SeriesPoint(t: t, v: sims.reduce(0) { $0 + $1.level }))
            for sim in sims {
                perAccount[sim.account.id, default: []].append(SeriesPoint(t: t, v: sim.level / sim.capacity * 100))
            }
        }

        record(nowMs)
        var t = nowMs
        var guardCount = 0
        while t < horizonMs, guardCount < 20_000 {
            guardCount += 1
            var nextT = min(horizonMs, t + projectionStepMs)
            for sim in sims {
                if let reset = sim.nextResetMs, reset > t, reset < nextT { nextT = reset }
            }
            let stepHours = (nextT - t) / hourMs
            let demand = max(0, burnPerHour) * stepHours
            let before = sims.map(\.level)
            let unmet = demand > 0 ? distributeDemand(strategy, &sims, demand) : 0

            for index in sims.indices {
                if sims[index].level < before[index] - epsilon, sims[index].nextResetMs == nil {
                    // An untouched window opens on first use.
                    sims[index].nextResetMs = t + sims[index].account.periodMs
                }
                if firstEmpty == nil, before[index] > epsilon, sims[index].level <= epsilon {
                    let fraction = demand > 0 ? min(1, before[index] / demand) : 1
                    firstEmpty = (t + (nextT - t) * fraction, sims[index].account.id)
                }
            }
            if poolEmptyAt == nil, demand > 0, unmet > epsilon {
                poolEmptyAt = t + (nextT - t) * ((demand - unmet) / demand)
            }

            t = nextT
            let resetting = sims.indices.filter { sims[$0].nextResetMs.map { $0 <= t } ?? false }
            if !resetting.isEmpty {
                record(t)
                for index in resetting {
                    let sim = sims[index]
                    resets.append(PoolReset(t: t, accountId: sim.account.id, amount: sim.capacity - sim.level, wasted: sim.level))
                    wastedAtResets += sim.level
                    sims[index].level = sim.capacity
                    // The refilled window stays closed until it is drawn on again.
                    sims[index].nextResetMs = nil
                }
            }
            record(t)
        }

        return PoolProjection(
            pool: pool,
            perAccount: perAccount,
            resets: resets,
            poolEmptyAt: poolEmptyAt,
            firstEmpty: firstEmpty,
            wastedAtResets: wastedAtResets,
            horizonMs: horizonMs
        )
    }

    /// Reset jumps in a recorded pool series (for "+N%" annotations).
    public static func recordedResets(_ accounts: [PoolAccount], fromMs: Double, nowMs: Double) -> [TimedAmount] {
        var out: [TimedAmount] = []
        for account in accounts {
            let points = account.recorded
            guard points.count > 1 else { continue }
            for index in 1..<points.count {
                let before = points[index - 1]
                let after = points[index]
                if after.t == before.t, after.v > before.v + epsilon, after.t > fromMs, after.t <= nowMs {
                    out.append(TimedAmount(t: after.t, amount: (after.v - before.v) * account.weight))
                }
            }
        }
        return mergeNearbyResets(out)
    }

    /// Merges resets within `withinMs` of each other so labels do not collide.
    public static func mergeNearbyResets(_ resets: [TimedAmount], withinMs: Double = hourMs) -> [TimedAmount] {
        var merged: [TimedAmount] = []
        for reset in resets.sorted(by: { $0.t < $1.t }) {
            if let last = merged.last, reset.t - last.t <= withinMs {
                merged[merged.count - 1].amount += reset.amount
            } else {
                merged.append(reset)
            }
        }
        return merged
    }

    /// Default visible range: three days back, eleven ahead (starting at local midnight).
    public static func visibleRange(nowMs: Double, calendar: Calendar = .current) -> (fromMs: Double, toMs: Double) {
        let startOfDay = calendar.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000))
        let fromMs = startOfDay.timeIntervalSince1970 * 1000 - 3 * dayMs
        return (fromMs, fromMs + 14 * dayMs)
    }
}
