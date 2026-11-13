import Foundation

/// Recorded quota history from CLIProxyAPI (`GET /v8/management/observability/quota`).
/// Mirrors the management center's `services/api/quotaHistory.ts` normalization.
public enum RoutingTier: String, Sendable {
    case known, unknown, exhausted
}

public struct QuotaWindow: Sendable, Equatable {
    public var id: String
    /// Consumed share of the window, 0...100.
    public var usedPercent: Double
    public var resetAtMs: Double?
    public var windowMinutes: Double?
}

public struct SampleWindow: Sendable, Equatable {
    public var used: Double
    public var resetAtMs: Double?
}

public struct QuotaSample: Sendable, Equatable {
    public var atMs: Double
    public var windows: [String: SampleWindow]
}

public struct QuotaRouting: Sendable, Equatable {
    public var windowId: String?
    public var tier: RoutingTier
    public var resetAtMs: Double?
    public var rank: Int
}

public struct QuotaCredential: Sendable, Equatable, Identifiable {
    public var id: String { authId }
    public var authIndex: String
    public var authId: String
    public var name: String
    public var provider: String
    public var label: String
    public var email: String
    public var planType: String
    public var priority: Double
    public var disabled: Bool
    public var unavailable: Bool
    public var observedAtMs: Double?
    public var windows: [QuotaWindow]
    public var routing: QuotaRouting
    public var samples: [QuotaSample]
}

public struct QuotaHistory: Sendable, Equatable {
    public var generatedAtMs: Double
    public var routingStrategy: String
    public var recording: Bool
    public var retentionHours: Double
    public var credentials: [QuotaCredential]

    public static func decode(_ data: Data) throws -> QuotaHistory {
        let record = J.obj(try J.parse(data)) ?? [:]
        let credentials = J.arr(record["credentials"]).compactMap(Self.credential)
        return QuotaHistory(
            generatedAtMs: J.dateMs(record["generated_at"]) ?? Date().timeIntervalSince1970 * 1000,
            routingStrategy: J.str(record["routing_strategy"]).isEmpty ? "round-robin" : J.str(record["routing_strategy"]),
            recording: J.bool(record["recording"]),
            retentionHours: J.num(record["retention_hours"]) ?? 0,
            credentials: credentials
        )
    }

    private static func window(_ raw: Any) -> QuotaWindow? {
        guard let raw = J.obj(raw) else { return nil }
        let id = J.str(raw["id"])
        guard !id.isEmpty else { return nil }
        return QuotaWindow(
            id: id,
            usedPercent: J.num(raw["used_percent"]) ?? 0,
            resetAtMs: J.dateMs(raw["reset_at"]),
            windowMinutes: J.num(raw["window_minutes"])
        )
    }

    private static func sample(_ raw: Any) -> QuotaSample? {
        guard let raw = J.obj(raw), let atMs = J.num(raw["t"]), let windowsRaw = J.obj(raw["w"]) else { return nil }
        var windows: [String: SampleWindow] = [:]
        for (id, value) in windowsRaw {
            guard let value = J.obj(value), let used = J.num(value["u"]) else { continue }
            let reset = J.num(value["r"])
            windows[id] = SampleWindow(used: used, resetAtMs: reset.flatMap { $0 > 0 ? $0 * 1000 : nil })
        }
        return QuotaSample(atMs: atMs, windows: windows)
    }

    private static func credential(_ raw: Any) -> QuotaCredential? {
        guard let raw = J.obj(raw) else { return nil }
        let authId = J.str(raw["auth_id"])
        guard !authId.isEmpty else { return nil }
        let routing = J.obj(raw["routing"]) ?? [:]
        let tierRaw = J.str(routing["tier"])
        let windowId = J.str(routing["window_id"])
        return QuotaCredential(
            authIndex: J.str(raw["auth_index"]),
            authId: authId,
            name: J.str(raw["name"]).isEmpty ? authId : J.str(raw["name"]),
            provider: J.str(raw["provider"]).lowercased(),
            label: J.str(raw["label"]),
            email: J.str(raw["email"]),
            planType: J.str(raw["plan_type"]).lowercased(),
            priority: J.num(raw["priority"]) ?? 0,
            disabled: J.bool(raw["disabled"]),
            unavailable: J.bool(raw["unavailable"]),
            observedAtMs: J.dateMs(raw["observed_at"]),
            windows: J.arr(raw["windows"]).compactMap(window),
            routing: QuotaRouting(
                windowId: windowId.isEmpty ? nil : windowId,
                tier: tierRaw == "known" || tierRaw == "exhausted" ? RoutingTier(rawValue: tierRaw)! : .unknown,
                resetAtMs: J.dateMs(routing["reset_at"]),
                rank: Int(J.num(routing["rank"]) ?? 0)
            ),
            samples: J.arr(raw["samples"]).compactMap(sample).sorted { $0.atMs < $1.atMs }
        )
    }
}
