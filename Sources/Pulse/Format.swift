import Foundation

/// Text formatting shared by the panel and notifications. 24-hour clock and
/// day-first dates follow the system locale.
enum Format {
    static func percent(_ units: Double) -> String { "\(Int(units.rounded()))%" }

    /// "Sat 19:00", or "Wed 25 Nov 15:41" when it is six days or more away.
    static func when(_ ms: Double, now nowMs: Double) -> String {
        format(ms, ms - nowMs > 6 * 86_400_000 ? "EEE d MMM HH:mm" : "EEE HH:mm")
    }

    /// Like `when`, but a far-off instant drops its time: "Wed 25 Nov".
    static func whenShort(_ ms: Double, now nowMs: Double) -> String {
        format(ms, ms - nowMs > 6 * 86_400_000 ? "EEE d MMM" : "EEE HH:mm")
    }

    /// "27 Nov"
    static func date(_ ms: Double) -> String { format(ms, "d MMM") }

    /// "Tue 10"
    static func dayLabel(_ ms: Double) -> String { format(ms, "EEE d") }

    private static func format(_ ms: Double, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// "in 10d 12h", "in 3h 20m", "in 12m"
    static func until(_ ms: Double, now nowMs: Double) -> String {
        let minutes = max(0, Int(((ms - nowMs) / 60_000).rounded()))
        if minutes >= 24 * 60 { return "in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "in \(minutes / 60)h \(minutes % 60)m" }
        return "in \(minutes)m"
    }

    /// "now", "4 min", "2 h", "3 d"
    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    static func strategy(_ raw: String) -> String {
        let words = raw.split(separator: "-").map(String.init)
        guard let first = words.first else { return raw }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }
}
