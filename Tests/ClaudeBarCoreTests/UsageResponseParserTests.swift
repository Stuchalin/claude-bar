@testable import ClaudeBarCore
import Foundation
import Testing

private let fetchedAt = Date(timeIntervalSince1970: 1_792_700_000)
/// 2026-10-23T14:59:59Z
private let weeklyReset: TimeInterval = 1_792_767_599
/// 2026-10-23T15:00:00Z
private let scopedReset: TimeInterval = 1_792_767_600

private func parse(_ json: String) throws -> UsageSnapshot {
    try UsageResponseParser.parse(Data(json.utf8), fetchedAt: fetchedAt)
}

private func resetDate(_ state: ResetState?) -> TimeInterval? {
    if case let .at(date) = state { date.timeIntervalSince1970 } else { nil }
}

@Suite("Usage response: real fixture")
struct UsageRealFixtureTests {
    @Test("sanitized real response parses into the expected snapshot")
    func realResponse() throws {
        let snapshot = try parse(UsageFixtures.realResponse)

        #expect(snapshot.fetchedAt == fetchedAt)
        #expect(snapshot.session == UsageWindow(
            usedPercent: 0, reset: .notStarted, duration: UsageWindow.sessionDuration,
            source: .window(field: "five_hour")
        ))

        let weekly = try #require(snapshot.weekly)
        #expect(weekly.usedPercent == 1)
        #expect(weekly.duration == UsageWindow.weeklyDuration)
        #expect(weekly.source == .window(field: "seven_day"))
        let weeklyResetAt = try #require(resetDate(weekly.reset))
        #expect(abs(weeklyResetAt - (weeklyReset + 0.549053)) < 0.001)

        #expect(snapshot.scopedWeeklies == [
            ScopedWeeklyLimit(
                key: "name:Fable", displayName: "Fable", isActive: false,
                reading: .available(UsageWindow(
                    usedPercent: 0, reset: .at(Date(timeIntervalSince1970: scopedReset)),
                    duration: UsageWindow.weeklyDuration, source: .limitsRow(kind: "weekly_scoped")
                ))
            ),
        ])
        #expect(snapshot.extraUsage == .disabled)
    }
}

@Suite("Usage response: session and weekly")
struct UsageWindowParsingTests {
    static let sessionRow = #"{"kind":"session","percent":42,"resets_at":"2026-10-23T15:00:00Z"}"#
    static let weeklyRow = #"{"kind":"weekly_all","percent":17,"resets_at":"2026-10-23T15:00:00Z"}"#

    @Test("five_hour and seven_day win over limits[] rows")
    func canonicalWins() throws {
        let snapshot = try parse("""
        {"five_hour":{"utilization":10,"resets_at":"2026-10-23T14:59:59Z"},
         "seven_day":{"utilization":20,"resets_at":"2026-10-23T14:59:59Z"},
         "limits":[\(Self.sessionRow),\(Self.weeklyRow)]}
        """)
        #expect(snapshot.session?.usedPercent == 10)
        #expect(snapshot.session?.source == .window(field: "five_hour"))
        #expect(snapshot.weekly?.usedPercent == 20)
        #expect(snapshot.weekly?.source == .window(field: "seven_day"))
    }

    @Test(
        "an invalid canonical window falls back to its limits[] row",
        arguments: [
            "null",
            #""not an object""#,
            #"{"resets_at":"2026-10-23T14:59:59Z"}"#,
            #"{"utilization":null}"#,
            #"{"utilization":"12"}"#,
            #"{"utilization":true}"#,
            #"{"utilization":-1}"#,
            #"{"utilization":1e400}"#,
        ]
    )
    func fallsBackToLimits(window: String) throws {
        let snapshot = try parse("""
        {"five_hour":\(window),"seven_day":\(window),"limits":[\(Self.sessionRow),\(Self.weeklyRow)]}
        """)
        #expect(snapshot.session?.usedPercent == 42)
        #expect(snapshot.session?.source == .limitsRow(kind: "session"))
        #expect(snapshot.session?.duration == UsageWindow.sessionDuration)
        #expect(snapshot.weekly?.usedPercent == 17)
        #expect(snapshot.weekly?.source == .limitsRow(kind: "weekly_all"))
        #expect(snapshot.weekly?.duration == UsageWindow.weeklyDuration)
    }

    @Test("missing canonical windows fall back to limits[] rows")
    func missingCanonical() throws {
        let snapshot = try parse(#"{"limits":[\#(Self.sessionRow),\#(Self.weeklyRow)]}"#)
        #expect(snapshot.session?.source == .limitsRow(kind: "session"))
        #expect(snapshot.weekly?.source == .limitsRow(kind: "weekly_all"))
    }

    @Test("an invalid limits[] row is skipped for the next valid row of the same kind")
    func skipsInvalidRow() throws {
        let snapshot = try parse("""
        {"limits":[{"kind":"session","percent":"x"},\(Self.sessionRow)]}
        """)
        #expect(snapshot.session?.usedPercent == 42)
    }

    @Test("with neither source the metric is unavailable, not 0, and the other metric survives")
    func unavailable() throws {
        let snapshot = try parse("""
        {"five_hour":{"utilization":null},"seven_day":{"utilization":3,"resets_at":null},
         "limits":[{"kind":"session","percent":null},{"kind":"weekly_all","percent":"5"}]}
        """)
        #expect(snapshot.session == nil)
        #expect(snapshot.weekly?.usedPercent == 3)
    }

    @Test("a limits value that is not an array, and rows that are not objects, are tolerated")
    func malformedLimits() throws {
        #expect(try parse(#"{"limits":"nope"}"#).session == nil)
        let snapshot = try parse(#"{"limits":[1,null,"x",\#(Self.sessionRow)]}"#)
        #expect(snapshot.session?.usedPercent == 42)
    }

    @Test("utilization above 100 is kept as reported")
    func overrun() throws {
        #expect(try parse(#"{"five_hour":{"utilization":104.5,"resets_at":null}}"#).session?.usedPercent == 104.5)
    }
}

@Suite("Usage response: reset times")
struct UsageResetParsingTests {
    @Test(
        "resets_at variants",
        arguments: [
            (#""resets_at":null"#, 0.0, ResetState.notStarted),
            (#""resets_at":null"#, 5.0, ResetState.unknown),
            ("", 0.0, ResetState.unknown),
            (#""resets_at":"soon""#, 0.0, ResetState.unknown),
            (#""resets_at":"2026-10-23 14:59:59Z""#, 5.0, ResetState.unknown),
            (#""resets_at":1792767599"#, 5.0, ResetState.unknown),
        ]
    )
    func resetStates(field: String, used: Double, expected: ResetState) throws {
        let separator = field.isEmpty ? "" : ","
        let snapshot = try parse(#"{"five_hour":{"utilization":\#(used)\#(separator)\#(field)}}"#)
        #expect(snapshot.session?.reset == expected)
    }

    @Test(
        "ISO 8601 variants: fractional seconds and offsets",
        arguments: [
            ("2026-10-23T14:59:59Z", weeklyReset),
            ("2026-10-23T14:59:59+00:00", weeklyReset),
            ("2026-10-23T14:59:59.549053+00:00", weeklyReset + 0.549053),
            ("2026-10-23T14:59:59.5Z", weeklyReset + 0.5),
            ("2026-10-23T14:59:59.123456789Z", weeklyReset + 0.123456789),
            ("2026-10-23T17:59:59+03:00", weeklyReset),
            ("2026-10-23T09:29:59-05:30", weeklyReset),
            ("2026-10-23T20:29:59.250+0530", weeklyReset + 0.25),
        ]
    )
    func isoVariants(raw: String, expected: TimeInterval) throws {
        let snapshot = try parse(#"{"seven_day":{"utilization":1,"resets_at":"\#(raw)"}}"#)
        let parsed = try #require(resetDate(snapshot.weekly?.reset))
        #expect(abs(parsed - expected) < 0.001)
    }
}

@Suite("Usage response: scoped weekly limits")
struct UsageScopedParsingTests {
    static func row(id: String?, name: String?, percent: String = "10", active: String = "true") -> String {
        func json(_ value: String?) -> String { value.map { #""\#($0)""# } ?? "null" }
        return """
        {"kind":"weekly_scoped","group":"weekly","percent":\(percent),"resets_at":"2026-10-23T15:00:00Z",
         "scope":{"model":{"id":\(json(id)),"display_name":\(json(name))}},"is_active":\(active)}
        """
    }

    static func limits(_ rows: String...) -> String {
        #"{"limits":[\#(rows.joined(separator: ","))]}"#
    }

    @Test("keys use the model id, else the normalized display name; null and whitespace-only ids fall back")
    func identities() throws {
        let snapshot = try parse(Self.limits(
            Self.row(id: "claude-opus-5", name: "Opus"),
            Self.row(id: nil, name: "Fable"),
            Self.row(id: "   ", name: "  Big   Model "),
            Self.row(id: " claude-x ", name: nil),
        ))
        #expect(snapshot.scopedWeeklies.map(\.key) == ["id:claude-opus-5", "name:Fable", "name:Big Model", "id:claude-x"])
        #expect(snapshot.scopedWeeklies.map(\.displayName) == ["Opus", "Fable", "Big   Model", nil])
        #expect(snapshot.scopedWeeklies.allSatisfy { $0.window?.usedPercent == 10 })
    }

    @Test("is_active is true only for an explicit true")
    func activeFlag() throws {
        let snapshot = try parse(Self.limits(
            Self.row(id: "a", name: "A", active: "true"),
            Self.row(id: "b", name: "B", active: "false"),
            Self.row(id: "c", name: "C", active: "null"),
            Self.row(id: "d", name: "D", active: #""yes""#),
        ))
        #expect(snapshot.scopedWeeklies.map(\.isActive) == [true, false, false, false])
    }

    @Test("a row with a bad percent is unavailable without dropping the others; a row without identity is dropped")
    func badRows() throws {
        let snapshot = try parse(Self.limits(
            Self.row(id: "a", name: "A", percent: "null"),
            Self.row(id: nil, name: "   "),
            Self.row(id: "b", name: "B", percent: "1e400"),
            Self.row(id: "c", name: "C"),
        ))
        #expect(snapshot.scopedWeeklies.map(\.key) == ["id:a", "id:b", "id:c"])
        #expect(snapshot.scopedWeeklies.map(\.reading).prefix(2) == [.unavailable, .unavailable])
        #expect(snapshot.scopedWeeklies[2].window?.usedPercent == 10)
    }

    @Test("rows with colliding keys are all ambiguous and never merged; others are unaffected")
    func duplicates() throws {
        let snapshot = try parse(Self.limits(
            Self.row(id: nil, name: "Fable", percent: "10"),
            Self.row(id: nil, name: " Fable ", percent: "30"),
            Self.row(id: "m", name: "M1"),
            Self.row(id: "m", name: "M2"),
            Self.row(id: "Fable", name: "Other"),
        ))
        #expect(snapshot.scopedWeeklies.count == 5)
        #expect(snapshot.scopedWeeklies.map(\.reading).prefix(4).allSatisfy { $0 == .ambiguous })
        #expect(snapshot.scopedWeeklies.map(\.displayName).prefix(4) == ["Fable", "Fable", "M1", "M2"])
        // `id:Fable` and `name:Fable` are namespaced apart.
        #expect(snapshot.scopedWeeklies[4].key == "id:Fable")
        #expect(snapshot.scopedWeeklies[4].window?.usedPercent == 10)
    }

    @Test("without weekly_scoped rows the legacy seven_day_sonnet / seven_day_opus fields are used")
    func legacyFallback() throws {
        let snapshot = try parse("""
        {"seven_day_sonnet":{"utilization":7,"resets_at":"2026-10-23T15:00:00Z"},
         "seven_day_opus":{"utilization":"bad"},
         "limits":[{"kind":"weekly_all","percent":1}]}
        """)
        #expect(snapshot.scopedWeeklies.map(\.key) == ["legacy:seven_day_sonnet", "legacy:seven_day_opus"])
        #expect(snapshot.scopedWeeklies.map(\.displayName) == ["Sonnet", "Opus"])
        #expect(snapshot.scopedWeeklies.map(\.isActive) == [true, true])
        #expect(snapshot.scopedWeeklies[0].window?.source == .window(field: "seven_day_sonnet"))
        #expect(snapshot.scopedWeeklies[0].window?.usedPercent == 7)
        #expect(snapshot.scopedWeeklies[1].reading == .unavailable)
    }

    @Test(
        "a response with only a legacy field is recognized and uses it",
        arguments: [("seven_day_sonnet", "Sonnet"), ("seven_day_opus", "Opus")]
    )
    func legacyOnly(field: String, name: String) throws {
        let snapshot = try parse(#"{"\#(field)":{"utilization":7,"resets_at":null}}"#)
        #expect(snapshot.session == nil)
        #expect(snapshot.weekly == nil)
        #expect(snapshot.scopedWeeklies == [
            ScopedWeeklyLimit(
                key: "legacy:\(field)", displayName: name, isActive: true,
                reading: .available(UsageWindow(
                    usedPercent: 7, reset: .unknown, duration: UsageWindow.weeklyDuration,
                    source: .window(field: field)
                ))
            ),
        ])
    }

    @Test("null legacy fields add nothing")
    func legacyNull() throws {
        #expect(try parse(#"{"seven_day_sonnet":null,"seven_day_opus":null,"limits":[]}"#).scopedWeeklies.isEmpty)
    }

    @Test("legacy fields are ignored when weekly_scoped rows exist, even unusable ones")
    func legacyIgnored() throws {
        let snapshot = try parse("""
        {"seven_day_sonnet":{"utilization":7,"resets_at":null},
         "limits":[\(Self.row(id: nil, name: nil))]}
        """)
        #expect(snapshot.scopedWeeklies.isEmpty)
    }
}

@Suite("Usage response: extra usage")
struct UsageExtraParsingTests {
    static func extra(_ body: String) throws -> ExtraUsageState {
        try parse(#"{"extra_usage":\#(body)}"#).extraUsage
    }

    @Test(
        "unavailable when missing, malformed or without a boolean is_enabled",
        arguments: ["null", "[]", "{}", #"{"is_enabled":null}"#, #"{"is_enabled":"true"}"#]
    )
    func unavailable(body: String) throws {
        #expect(try Self.extra(body) == .unavailable)
    }

    @Test("missing extra_usage is unavailable")
    func missing() throws {
        #expect(try parse(#"{"seven_day":null}"#).extraUsage == .unavailable)
    }

    @Test("disabled")
    func disabled() throws {
        #expect(try Self.extra(#"{"is_enabled":false,"monthly_limit":5000,"used_credits":10}"#) == .disabled)
    }

    @Test("enabled with a cap: cents are divided by 100")
    func capped() throws {
        let state = try Self.extra(
            #"{"is_enabled":true,"monthly_limit":5000,"used_credits":1234,"utilization":24.68,"currency":" USD "}"#
        )
        #expect(state == .enabled(ExtraUsage(used: 12.34, cap: .amount(50), currency: "USD", utilization: 24.68)))
    }

    @Test(
        "cap states: none, zero, unknown",
        arguments: [
            (#""monthly_limit":null"#, ExtraUsage.Cap.none),
            (#""monthly_limit":0"#, ExtraUsage.Cap.zero),
            (#""monthly_limit":"5000""#, ExtraUsage.Cap.unknown),
            (#""monthly_limit":-1"#, ExtraUsage.Cap.unknown),
            (#""other":1"#, ExtraUsage.Cap.unknown),
        ]
    )
    func capStates(field: String, expected: ExtraUsage.Cap) throws {
        let state = try Self.extra(#"{"is_enabled":true,"used_credits":0,"currency":"EUR",\#(field)}"#)
        #expect(state == .enabled(ExtraUsage(used: 0, cap: expected, currency: "EUR", utilization: nil)))
    }

    @Test("missing currency and used amount stay nil, never defaulted", arguments: ["null", #""  ""#, "7"])
    func missingCurrency(currency: String) throws {
        let state = try Self.extra(
            #"{"is_enabled":true,"monthly_limit":100,"used_credits":null,"currency":\#(currency)}"#
        )
        #expect(state == .enabled(ExtraUsage(used: nil, cap: .amount(1), currency: nil, utilization: nil)))
    }
}

@Suite("Usage response: malformed documents")
struct UsageMalformedTests {
    @Test("non-JSON and non-object documents are rejected", arguments: ["<html>", "", "[]", "42", #""text""#])
    func notObject(body: String) {
        #expect(throws: UsageResponseParser.Failure.notJSONObject) { try parse(body) }
    }

    @Test("an object without any usage field is rejected")
    func unrecognized() {
        #expect(throws: UsageResponseParser.Failure.unrecognizedShape) { try parse(#"{"error":"nope"}"#) }
    }

    @Test("an object with only null usage fields yields an all-unavailable snapshot")
    func allNull() throws {
        let snapshot = try parse(#"{"five_hour":null,"seven_day":null,"limits":null,"extra_usage":null}"#)
        #expect(snapshot == UsageSnapshot(
            session: nil, weekly: nil, scopedWeeklies: [], extraUsage: .unavailable, fetchedAt: fetchedAt
        ))
    }
}
