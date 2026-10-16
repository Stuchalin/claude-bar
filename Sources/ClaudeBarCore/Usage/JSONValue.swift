import Foundation

/// A JSON value decoded without ever failing on a single field.
///
/// Values that Foundation cannot represent (numbers outside `Double`'s range such as `1e400`)
/// become `.unsupported` instead of failing the whole document, so one bad field never drops the
/// rest. Only a syntactically invalid document fails to decode.
enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    case unsupported

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = value.isFinite ? .number(value) : .unsupported
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .unsupported
        }
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { object[key] } else { nil }
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(object) = self { object } else { nil }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(array) = self { array } else { nil }
    }

    /// A finite number; `nil` for any other kind of value.
    var finiteNumber: Double? {
        if case let .number(number) = self, number.isFinite { number } else { nil }
    }

    var stringValue: String? {
        if case let .string(string) = self { string } else { nil }
    }

    var boolValue: Bool? {
        if case let .bool(bool) = self { bool } else { nil }
    }
}
