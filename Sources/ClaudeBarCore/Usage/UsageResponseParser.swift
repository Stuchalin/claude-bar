import Foundation

/// Maps the usage JSON to a `UsageSnapshot` per the plan's response-mapping precedence.
///
/// Decoding is tolerant: unknown fields are ignored, a missing or malformed metric becomes
/// unavailable (never 0), non-finite and negative numbers are rejected, and one bad optional
/// row never drops the others.
enum UsageResponseParser {
    enum Failure: Error, Equatable, Sendable {
        /// Not JSON, or JSON whose top level is not an object.
        case notJSONObject
        /// A JSON object without any of the usage fields.
        case unrecognizedShape
    }

    static let knownTopLevelKeys = [
        "five_hour", "seven_day", "limits", "extra_usage", "seven_day_sonnet", "seven_day_opus",
    ]

    static func parse(_ data: Data, fetchedAt: Date) throws(Failure) -> UsageSnapshot {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), let object = root.objectValue else {
            throw .notJSONObject
        }
        guard knownTopLevelKeys.contains(where: { object[$0] != nil }) else { throw .unrecognizedShape }

        let limitRows = (object["limits"]?.arrayValue ?? []).compactMap(\.objectValue)

        let session = window(object["five_hour"], field: "five_hour", duration: UsageWindow.sessionDuration)
            ?? limitsWindow(limitRows, kind: "session", duration: UsageWindow.sessionDuration)
        let weekly = window(object["seven_day"], field: "seven_day", duration: UsageWindow.weeklyDuration)
            ?? limitsWindow(limitRows, kind: "weekly_all", duration: UsageWindow.weeklyDuration)

        return UsageSnapshot(
            session: session,
            weekly: weekly,
            scopedWeeklies: scopedWeeklies(limitRows: limitRows, root: object),
            extraUsage: extraUsage(object["extra_usage"]),
            fetchedAt: fetchedAt
        )
    }

    // MARK: - Windows

    /// A top-level window object (`five_hour`, `seven_day`, …) with a valid `utilization`.
    static func window(_ value: JSONValue?, field: String, duration: TimeInterval) -> UsageWindow? {
        guard let object = value?.objectValue, let used = nonNegative(object["utilization"]) else { return nil }
        return UsageWindow(
            usedPercent: used,
            reset: reset(object["resets_at"], used: used),
            duration: duration,
            source: .window(field: field)
        )
    }

    /// The first `limits[]` row of `kind` with a valid `percent`.
    static func limitsWindow(_ rows: [[String: JSONValue]], kind: String, duration: TimeInterval) -> UsageWindow? {
        for row in rows where row["kind"]?.stringValue == kind {
            if let window = limitsRowWindow(row, kind: kind, duration: duration) { return window }
        }
        return nil
    }

    static func limitsRowWindow(_ row: [String: JSONValue], kind: String, duration: TimeInterval) -> UsageWindow? {
        guard let used = nonNegative(row["percent"]) else { return nil }
        return UsageWindow(
            usedPercent: used,
            reset: reset(row["resets_at"], used: used),
            duration: duration,
            source: .limitsRow(kind: kind)
        )
    }

    /// A finite, non-negative number (percentages, cents).
    static func nonNegative(_ value: JSONValue?) -> Double? {
        guard let number = value?.finiteNumber, number >= 0 else { return nil }
        return number
    }

    /// `null` with zero usage means "not started"; anything else unparseable is "unknown".
    static func reset(_ value: JSONValue?, used: Double) -> ResetState {
        switch value {
        case .null:
            used == 0 ? .notStarted : .unknown
        case let .string(raw):
            ISO8601.parse(raw).map(ResetState.at) ?? .unknown
        default:
            .unknown
        }
    }

    // MARK: - Scoped weeklies

    static func scopedWeeklies(limitRows: [[String: JSONValue]], root: [String: JSONValue]) -> [ScopedWeeklyLimit] {
        let scopedRows = limitRows.filter { $0["kind"]?.stringValue == "weekly_scoped" }
        let candidates = scopedRows.isEmpty ? legacyScoped(root) : scopedRows.compactMap(scopedRow)

        var keyCounts: [String: Int] = [:]
        for candidate in candidates { keyCounts[candidate.key, default: 0] += 1 }

        return candidates.map { candidate in
            guard keyCounts[candidate.key, default: 0] > 1 else { return candidate }
            return ScopedWeeklyLimit(
                key: candidate.key,
                displayName: candidate.displayName,
                isActive: candidate.isActive,
                reading: .ambiguous
            )
        }
    }

    /// A `weekly_scoped` row, or `nil` when it has neither a model id nor a display name.
    static func scopedRow(_ row: [String: JSONValue]) -> ScopedWeeklyLimit? {
        let model = row["scope"]?["model"]
        let modelID = model?["id"]?.stringValue.flatMap(trimmedNonEmpty)
        let displayName = model?["display_name"]?.stringValue.flatMap(trimmedNonEmpty)

        let key: String
        if let modelID {
            key = "id:\(modelID)"
        } else if let displayName {
            key = "name:\(normalizedName(displayName))"
        } else {
            return nil
        }

        let window = limitsRowWindow(row, kind: "weekly_scoped", duration: UsageWindow.weeklyDuration)
        return ScopedWeeklyLimit(
            key: key,
            displayName: displayName,
            isActive: row["is_active"]?.boolValue == true,
            reading: window.map(ScopedWeeklyLimit.Reading.available) ?? .unavailable
        )
    }

    /// Legacy per-model weekly fields, used only when `limits[]` has no `weekly_scoped` rows.
    static let legacyScopedFields = [("seven_day_sonnet", "Sonnet"), ("seven_day_opus", "Opus")]

    static func legacyScoped(_ root: [String: JSONValue]) -> [ScopedWeeklyLimit] {
        legacyScopedFields.compactMap { field, name in
            guard let value = root[field], value != .null else { return nil }
            let window = window(value, field: field, duration: UsageWindow.weeklyDuration)
            return ScopedWeeklyLimit(
                key: "legacy:\(field)",
                displayName: name,
                isActive: true,
                reading: window.map(ScopedWeeklyLimit.Reading.available) ?? .unavailable
            )
        }
    }

    static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Conservative normalization: trims and collapses whitespace runs; case and punctuation are kept.
    static func normalizedName(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Extra usage

    static func extraUsage(_ value: JSONValue?) -> ExtraUsageState {
        guard let object = value?.objectValue, let enabled = object["is_enabled"]?.boolValue else {
            return .unavailable
        }
        guard enabled else { return .disabled }

        let used = nonNegative(object["used_credits"]).map { $0 / 100 }
        let cap: ExtraUsage.Cap = switch object["monthly_limit"] {
        case .null:
            .none
        case let .some(value):
            switch nonNegative(value) {
            case 0?: .zero
            case let amount?: .amount(amount / 100)
            case nil: .unknown
            }
        case nil:
            .unknown
        }
        return .enabled(ExtraUsage(
            used: used,
            cap: cap,
            currency: object["currency"]?.stringValue.flatMap(trimmedNonEmpty),
            utilization: nonNegative(object["utilization"])
        ))
    }

}

/// RFC 3339 timestamps with or without fractional seconds and with `Z` or a numeric offset.
enum ISO8601 {
    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // ISO8601DateFormatter is thread-safe but not Sendable; a formatter per call keeps this simple.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
