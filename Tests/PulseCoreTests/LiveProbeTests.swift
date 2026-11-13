import Foundation
import Testing
@testable import PulseCore

/// Runs only when PULSE_CPA_URL and PULSE_CPA_KEY_FILE are set: fetches real
/// quota history and prints the pool numbers to compare with the management page.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_CPA_KEY_FILE"] != nil))
func liveQuotaPools() async throws {
    let env = ProcessInfo.processInfo.environment
    let url = try #require(URL(string: env["PULSE_CPA_URL"] ?? ""))
    let key = try String(contentsOfFile: env["PULSE_CPA_KEY_FILE"]!, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let client = CLIProxyClient(baseURL: url, managementKey: key)
    let now = Date()
    let history = try await client.quotaHistory(since: now.addingTimeInterval(-4 * 86_400))
    let burnHours = Double(env["PULSE_BURN_HOURS"] ?? "1") ?? 1
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE d MMM HH:mm"
    let at: (Double?) -> String = { $0.map { formatter.string(from: Date(timeIntervalSince1970: $0 / 1000)) } ?? "none" }
    for pool in PoolSummary.buildAll(history, nowMs: now.timeIntervalSince1970 * 1000, burnWindowHours: burnHours) {
        print("""
        [\(pool.displayName)] \(pool.accounts.count) accounts  \(Int(pool.remainingNow.rounded()))% of \(Int(pool.capacity))%
          pool empty: \(at(pool.projection.poolEmptyAt))  (horizon \(at(pool.projection.horizonMs)))
          first empty: \(pool.firstEmptyAccount.map { $0.id } ?? "none") at \(at(pool.projection.firstEmpty?.t))
          next reset: +\(Int((pool.nextReset?.amount ?? 0).rounded()))% at \(at(pool.nextReset?.t))
          burn last \(Int(burnHours))h: \(String(format: "%.1f", pool.burnPerHour))%/h  lost at resets: \(Int(pool.projection.wastedAtResets.rounded()))%
          recorded points: \(pool.recorded.count)  projected points: \(pool.projected.count)
        """)
    }
}
