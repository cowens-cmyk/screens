import Foundation

/// A JSON value for the Assistant's Messages API traffic. Tool inputs and
/// content blocks have no fixed shape, so they travel as this rather than as
/// per-block Codable types. Encoding sorts keys: the request prefix has to
/// be byte-identical from turn to turn for prompt caching to hit.
public indirect enum AssistantJSON: Sendable, Equatable, Hashable {
    case object([String: AssistantJSON])
    case array([AssistantJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public subscript(key: String) -> AssistantJSON? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    /// A whole number; 3.0 counts, 3.5 does not.
    public var int: Int? {
        guard let value = number, value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }

    public var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    public var array: [AssistantJSON]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var object: [String: AssistantJSON]? {
        if case .object(let value) = self { value } else { nil }
    }

    public var isNull: Bool { self == .null }

    /// Compact JSON with sorted keys.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var jsonString: String { String(decoding: encoded(), as: UTF8.self) }

    public static func parse(_ data: Data) throws -> AssistantJSON {
        try JSONDecoder().decode(AssistantJSON.self, from: data)
    }

    public static func parse(_ text: String) throws -> AssistantJSON {
        try parse(Data(text.utf8))
    }

    /// Returns a copy with `value` set at `key`; non-objects are returned as they are.
    public func setting(_ key: String, _ value: AssistantJSON) -> AssistantJSON {
        guard case .object(var fields) = self else { return self }
        fields[key] = value
        return .object(fields)
    }
}

extension AssistantJSON: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AssistantJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AssistantJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let fields): try container.encode(fields)
        case .array(let items): try container.encode(items)
        case .string(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers go out without a fraction ("10", not "10.0").
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension AssistantJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: AssistantJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, AssistantJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public extension AssistantJSON {
    init(_ value: String?) { self = value.map { .string($0) } ?? .null }
    init(_ value: Int?) { self = value.map { .number(Double($0)) } ?? .null }
    init(_ value: Double?) { self = value.map { .number($0) } ?? .null }
    init(_ value: Bool?) { self = value.map { .bool($0) } ?? .null }
    init(_ values: [String]) { self = .array(values.map { .string($0) }) }
}
