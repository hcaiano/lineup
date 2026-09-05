import Foundation

/// Minimal local JSON value owned by HintsCore: capability-analogous to (but independent of)
/// AppCore's `JSONValue`. HintsCore must never depend on AppCore, so unknown/top-level and
/// nested settings fields are preserved through this type plus dynamic coding keys.
///
/// Attention point mirrored from AppCore: on Apple platforms NSNumber bridging means the
/// bool/int ordering in `init(from:)` decides how a bare number on the wire is typed. Known
/// Hints settings fields are always decoded from typed containers (never through
/// `HintJSONValue`), so `true`-vs-`1` lenience cannot reach them; only unknown preservation
/// payloads ride this enum.
public indirect enum HintJSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([HintJSONValue])
    case object([String: HintJSONValue])
}

extension HintJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([HintJSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: HintJSONValue].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Stable dynamic coding key for hand-rolled `Codable` containers, matching AppCore's
/// `AnyCodingKey` contract with a HintsCore-local owner.
struct HintAnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ name: String) { self.init(stringValue: name) }

    static func named(_ name: String) -> HintAnyCodingKey { HintAnyCodingKey(name) }
}

// MARK: - Known/unknown container helpers shared by Hints settings types

extension KeyedDecodingContainer where Key == HintAnyCodingKey {
    /// Unknown keys decoded verbatim, excluding the known-key set.
    func unknownValues(besides known: Set<String>) throws -> [String: HintJSONValue] {
        var extra: [String: HintJSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            extra[key.stringValue] = try decode(HintJSONValue.self, forKey: key)
        }
        return extra
    }
}

extension KeyedEncodingContainer where Key == HintAnyCodingKey {
    /// Re-emit unknown fields, never overwriting a known key this build still owns.
    mutating func encodeUnknown(_ extra: [String: HintJSONValue], besides known: Set<String>) throws {
        for (key, value) in extra where !known.contains(key) {
            try encode(value, forKey: HintAnyCodingKey(key))
        }
    }
}
