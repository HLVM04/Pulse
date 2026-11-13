import Foundation

/// Lenient readers for `JSONSerialization` output. The backends are read
/// defensively: a missing or oddly typed field falls back instead of failing
/// the whole response.
enum J {
    static func obj(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func arr(_ value: Any?) -> [Any] { value as? [Any] ?? [] }

    static func str(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func num(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let string = value as? String, let double = Double(string.trimmingCharacters(in: .whitespaces)),
           double.isFinite {
            return double
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return false
    }

    /// Milliseconds since 1970 for an ISO 8601 string, or nil.
    static func dateMs(_ value: Any?) -> Double? {
        guard let string = value as? String, let date = ISODate.parse(string) else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISODate.parse(string)
    }

    static func parse(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

public enum ISODate {
    /// Parses RFC 3339 timestamps, including Go's nanosecond fractions
    /// ("2026-11-13T10:21:08.055540558Z") that Foundation will not read as-is.
    public static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacing(/\.(\d{1,3})\d*/) { match in ".\(match.1)" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }
}
