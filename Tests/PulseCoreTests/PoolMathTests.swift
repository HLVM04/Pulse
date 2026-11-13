import Foundation
import Testing
@testable import PulseCore

private let hour = PoolMath.hourMs
private let day = PoolMath.dayMs

private func credential(
    _ id: String,
    used: Double,
    resetInHours: Double?,
    now: Double,
    samples: [(hoursAgo: Double, used: Double)] = [],
    disabled: Bool = false
) -> QuotaCredential {
    let reset = resetInHours.map { now + $0 * hour }
    return QuotaCredential(
        authIndex: id, authId: id, name: id, provider: "claude", label: "", email: "\(id)@example.com",
        planType: "", priority: 0, disabled: disabled, unavailable: false, observedAtMs: now,
        windows: [QuotaWindow(id: "7d", usedPercent: used, resetAtMs: reset, windowMinutes: 10_080)],
        routing: QuotaRouting(windowId: "7d", tier: .known, resetAtMs: reset, rank: 1),
        samples: samples.map { QuotaSample(atMs: now - $0.hoursAgo * hour, windows: ["7d": SampleWindow(used: $0.used, resetAtMs: reset)]) }
    )
}

@Test func valueAtInterpolatesAndHandlesJumps() {
    let points = [SeriesPoint(t: 0, v: 100), SeriesPoint(t: 10, v: 50), SeriesPoint(t: 10, v: 100), SeriesPoint(t: 20, v: 80)]
    #expect(PoolMath.valueAt(points, 5) == 75)
    #expect(PoolMath.valueAt(points, 10, side: .left) == 50)
    #expect(PoolMath.valueAt(points, 10, side: .right) == 100)
    #expect(PoolMath.valueAt(points, -5) == 100)
    #expect(PoolMath.valueAt(points, 99) == 80)
}

@Test func consumedBetweenIgnoresResetJumps() {
    let points = [SeriesPoint(t: 0, v: 100), SeriesPoint(t: 10, v: 50), SeriesPoint(t: 10, v: 100), SeriesPoint(t: 20, v: 80)]
    #expect(PoolMath.consumedBetween(points, fromMs: 0, toMs: 20) == 70)
}

@Test func burnRateFromRecordedSamples() {
    let now = 1_000 * day
    // 10% used over the last two hours on one account: 5 pool units per hour.
    let a = credential("a", used: 10, resetInHours: 48, now: now, samples: [(2, 0), (0, 10)])
    let accounts = PoolMath.buildPoolAccounts([a], fromMs: now - day, nowMs: now)
    #expect(abs(PoolMath.burnRatePerHour(accounts, nowMs: now, windowMs: 2 * hour) - 5) < 1e-9)
}

@Test func soonestResetFirstDrainsTheEarliestResetAndRefillsIt() {
    let now = 1_000 * day
    let soon = credential("soon", used: 0, resetInHours: 10, now: now)
    let late = credential("late", used: 0, resetInHours: 100, now: now)
    let accounts = PoolMath.buildPoolAccounts([late, soon], fromMs: now - day, nowMs: now)
    let projection = PoolMath.projectPool(accounts, nowMs: now, horizonMs: now + 20 * hour, burnPerHour: 2, strategy: "soonest-reset-first")

    // After 10 hours "soon" has given 20 units, then resets back to full.
    let firstReset = try! #require(projection.resets.first)
    #expect(firstReset.accountId == "soon")
    #expect(abs(firstReset.t - (now + 10 * hour)) < 1)
    #expect(abs(firstReset.amount - 20) < 1e-6)
    #expect(abs(firstReset.wasted - 80) < 1e-6)
    #expect(projection.poolEmptyAt == nil)
}

@Test func poolEmptyAndFirstEmptyAreFound() {
    let now = 1_000 * day
    let a = credential("a", used: 90, resetInHours: 500, now: now)
    let b = credential("b", used: 90, resetInHours: 600, now: now)
    let accounts = PoolMath.buildPoolAccounts([a, b], fromMs: now - day, nowMs: now)
    let projection = PoolMath.projectPool(accounts, nowMs: now, horizonMs: now + 48 * hour, burnPerHour: 1, strategy: "soonest-reset-first")
    // 20 units at 1/hour: "a" empties after 10h, the pool after 20h.
    #expect(projection.firstEmpty?.accountId == "a")
    #expect(abs(projection.firstEmpty!.t - (now + 10 * hour)) < 1)
    #expect(abs(projection.poolEmptyAt! - (now + 20 * hour)) < 1)
}

@Test func expiredWindowCountsAsFullAndUnstarted() {
    let now = 1_000 * day
    let expired = credential("x", used: 70, resetInHours: -1, now: now)
    let account = PoolMath.buildPoolAccounts([expired], fromMs: now - day, nowMs: now)[0]
    #expect(account.remainingNow == 100)
    #expect(account.nextResetMs == nil)
}

@Test func summaryAddsAccountsIntoOnePool() throws {
    let now = 1_000 * day
    let history = QuotaHistory(
        generatedAtMs: now, routingStrategy: "soonest-reset-first", recording: true, retentionHours: 336,
        credentials: [
            credential("a", used: 5, resetInHours: 30, now: now),
            credential("b", used: 0, resetInHours: 60, now: now),
            credential("c", used: 0, resetInHours: 90, now: now),
            credential("d", used: 0, resetInHours: 120, now: now),
            credential("off", used: 50, resetInHours: 10, now: now, disabled: true),
        ]
    )
    let pools = PoolSummary.buildAll(history, nowMs: now, burnWindowHours: 1)
    let claude = try #require(pools.first)
    #expect(claude.capacity == 400)
    #expect(claude.remainingNow == 395)
    #expect(claude.accounts.count == 4)
}

@Test func decodesBackendQuotaHistory() throws {
    let json = """
    {"credentials":[{"auth_index":"1b9c","auth_id":"claude-a.json","provider":"claude","email":"a@example.com",
      "priority":0,"disabled":false,"unavailable":false,"observed_at":"2026-11-13T10:21:08.020088708Z",
      "windows":[{"id":"5h","used_percent":11,"reset_at":"2026-11-13T14:30:00Z","window_minutes":300},
                 {"id":"7d","used_percent":5,"reset_at":"2026-11-14T18:00:00Z","window_minutes":10080}],
      "routing":{"window_id":"7d","tier":"known","reset_at":"2026-11-14T18:00:00Z","rank":1},
      "samples":[{"t":1794309827307,"w":{"5h":{"u":0},"7d":{"u":0,"r":1794679200}}},
                 {"t":1794305845291,"w":{"7d":{"u":0,"r":1794679200}}}]}],
     "generated_at":"2026-11-13T10:21:08.055540558Z","recording":true,"retention_hours":336,
     "routing_strategy":"soonest-reset-first","since":"2026-11-10T10:21:07Z"}
    """
    let history = try QuotaHistory.decode(Data(json.utf8))
    #expect(history.routingStrategy == "soonest-reset-first")
    let credential = try #require(history.credentials.first)
    #expect(credential.windows.count == 2)
    #expect(credential.routing.rank == 1)
    #expect(credential.samples.first!.atMs == 1_794_305_845_291) // sorted ascending
    #expect(credential.samples.first!.windows["7d"]?.resetAtMs == 1_794_679_200_000)
    #expect(credential.observedAtMs != nil)
}

@Test func sseParsing() {
    let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}\n\n"
    let messages = MCPClient.sseMessages(Data(body.utf8))
    #expect(messages.count == 1)
    #expect(J.num(messages[0]["id"]) == 3)
}

@Test func modelDisplayNames() {
    func thread(_ model: String) -> T3Thread {
        T3Thread(id: "t", projectId: "p", title: "", status: "running", model: model, createdAt: nil, updatedAt: nil,
                 environmentId: "e", environmentLabel: "Mac", isLocalEnvironment: true, projectTitle: nil, snoozed: false)
    }
    #expect(thread("claude-opus-5-5").modelDisplay == "Opus 5.5")
    #expect(thread("gpt-6-luna").modelDisplay == "GPT-6 Luna")
    #expect(thread("claude-opus-5-5").deepLink.absoluteString == "t3code://threads/e/t")
}
