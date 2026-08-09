import Foundation

/// A loss-tolerant JSON tree.
///
/// Tool settings are stored in `config.json` as OPAQUE JSON so that (a) adding a tool needs no
/// change to the envelope, and (b) an OLDER build round-trips a NEWER build's unknown sections
/// instead of silently deleting them. Only the owning tool ever decodes its own section.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    /// A whole number, kept as an integer so a 64-bit id survives a round trip. `Double` cannot
    /// represent an odd integer above 2^53: `9007199254740993` came back as `...92`, and an
    /// older build re-writing a newer build's section would silently corrupt it.
    case int(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            // Tried BEFORE Double: JSONDecoder only hands back an Int64 for a source token that
            // really is a whole number in range, so a fractional or huge value still falls
            // through to the Double case below.
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: - Bridging to typed models

    /// Encode a tool's settings model into an opaque section value.
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode this section back into the owning tool's model.
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Convenience accessors (tests + diagnostics; tools use `decoded`)

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public var isEmptyObject: Bool { objectValue?.isEmpty == true }
}

/// A coding key made from any string, so a `Codable` type can read and re-emit the keys it does
/// not know about (see `LineupAppConfig.extra`).
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue) }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// Every key that is NOT one of `known`, decoded as opaque JSON.
    func unknownValues(besides known: Set<String>) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            out[key.stringValue] = try decode(JSONValue.self, forKey: key)
        }
        return out
    }
}

extension KeyedEncodingContainer where Key == AnyCodingKey {
    mutating func encodeExtra(_ extra: [String: JSONValue]) throws {
        for (key, value) in extra { try encode(value, forKey: AnyCodingKey(key)) }
    }
}
