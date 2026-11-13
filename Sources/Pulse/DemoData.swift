import AppKit
import PulseCore

/// Made-up threads and quota for screenshots: `PULSE_DEMO=1` starts Pulse with
/// this data and no network access. `PULSE_DEMO_ROUTE=claude` opens the forecast,
/// `PULSE_APPEARANCE=dark|light` forces the look.
@MainActor
enum DemoData {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["PULSE_DEMO"] != nil }
    static var route: PanelRoute {
        ProcessInfo.processInfo.environment["PULSE_DEMO_ROUTE"].map { PanelRoute.quota($0) } ?? .main
    }

    static func applyAppearance() {
        switch ProcessInfo.processInfo.environment["PULSE_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    static func history(now: Date) -> QuotaHistory {
        let nowMs = now.timeIntervalSince1970 * 1000
        let hour = 3_600_000.0
        func iso(_ ms: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000)) }

        /// `levels`: (hours ago, % used) samples of the weekly window; `reset` in hours from now.
        func account(_ id: String, _ label: String, provider: String = "claude", rank: Int, used: Double,
                     reset: Double, levels: [(Double, Double)], window: String = "7d") -> [String: Any] {
            let resetMs = nowMs + reset * hour
            let samples: [[String: Any]] = levels.map { ago, value in
                let sampleReset = ago > 60 && id == "studio" ? resetMs - 168 * hour : resetMs
                return ["t": nowMs - ago * hour, "w": [window: ["u": value, "r": sampleReset / 1000]]]
            }
            return [
                "auth_index": id, "auth_id": "\(provider)-\(id).json", "provider": provider, "label": label,
                "email": "", "priority": 0, "disabled": false, "unavailable": false, "observed_at": iso(nowMs),
                "windows": [["id": window, "used_percent": used, "reset_at": iso(resetMs), "window_minutes": 10_080]],
                "routing": ["window_id": window, "tier": "known", "reset_at": iso(resetMs), "rank": rank],
                "samples": samples,
            ]
        }

        // "Studio" drained to 92% used, reset 60 hours ago, and is draining again.
        let studioLevels: [(Double, Double)] = stride(from: 84.0, through: 62, by: -2).map { ($0, 70 + (84 - $0)) }
            + stride(from: 58.0, through: 0, by: -2).map { ($0, (58 - $0) * 0.9) }
        let credentials: [[String: Any]] = [
            account("studio", "Studio", rank: 1, used: 52, reset: 31, levels: studioLevels),
            account("team", "Team", rank: 2, used: 12, reset: 55, levels: [(70, 4), (30, 9), (0, 12)]),
            account("personal", "Personal", rank: 3, used: 6, reset: 130, levels: [(70, 2), (0, 6)]),
            account("spare", "Spare", rank: 4, used: 0, reset: 150, levels: [(70, 0), (0, 0)]),
            account("plus", "Plus", provider: "codex", rank: 1, used: 38, reset: 90, levels: [(70, 20), (0, 38)], window: "secondary"),
        ]
        let json: [String: Any] = [
            "credentials": credentials, "generated_at": iso(nowMs), "recording": true,
            "retention_hours": 336, "routing_strategy": "soonest-reset-first",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! QuotaHistory.decode(data)
    }

    static func threads(now: Date) -> (active: [T3Thread], recent: [T3Thread]) {
        func thread(_ title: String, _ project: String, _ status: String, _ model: String, minutesAgo: Double, vps: Bool) -> T3Thread {
            T3Thread(
                id: UUID().uuidString, projectId: project, title: title, status: status, model: model,
                createdAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                environmentId: vps ? "vps" : "mac", environmentLabel: vps ? "VPS" : "Mac",
                isLocalEnvironment: !vps, projectTitle: project, snoozed: false
            )
        }
        return (
            [
                thread("Trade window overflows on phone", "PetLegends", "waiting", "claude-opus-5-5", minutesAgo: 2, vps: true),
                thread("Refactor the pool scheduler", "rsd", "running", "claude-opus-5-5", minutesAgo: 0, vps: false),
                thread("Daily reward streak", "PetLegends", "running", "gpt-6-luna", minutesAgo: 1, vps: true),
            ],
            [thread("Deal scoring for auctions", "Hammerslag", "completed", "claude-sonnet-5-5", minutesAgo: 3, vps: false)]
        )
    }
}
