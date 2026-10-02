import Foundation
import KeyboardRemapCore

/// The shared config envelope is unchanged. This section versions only physical-key rules.
public struct KeyboardRemapSettings: Codable, Equatable {
    public struct Pair: Codable, Equatable, Identifiable {
        public let id: String
        public var source: UInt64
        public var destination: UInt64
        private var extra: [String: JSONValue] = [:]

        public init(id: String = UUID().uuidString, source: UInt64, destination: UInt64) {
            self.id = id
            self.source = source
            self.destination = destination
        }

        public var mapping: KeyMapping { KeyMapping(source: source, destination: destination) }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            id = try c.decode(String.self, forKey: AnyCodingKey("id"))
            source = try c.decode(UInt64.self, forKey: AnyCodingKey("source"))
            destination = try c.decode(UInt64.self, forKey: AnyCodingKey("destination"))
            extra = try c.unknownValues(besides: ["id", "source", "destination"])
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            try c.encode(id, forKey: AnyCodingKey("id"))
            try c.encode(source, forKey: AnyCodingKey("source"))
            try c.encode(destination, forKey: AnyCodingKey("destination"))
            try c.encodeExtra(extra)
        }
    }

    public struct Rule: Codable, Equatable, Identifiable {
        public let id: String
        public let selector: KeyboardSelector
        public var mappings: [Pair]
        private var extra: [String: JSONValue] = [:]
        private var rawSelector: JSONValue?

        public init(id: String = UUID().uuidString, selector: KeyboardSelector, mappings: [Pair] = []) {
            self.id = id
            self.selector = selector
            self.mappings = mappings
        }

        public var ruleSet: KeyboardRuleSet {
            KeyboardRuleSet(selector: selector, mappings: mappings.map(\.mapping))
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            id = try c.decode(String.self, forKey: AnyCodingKey("id"))
            let raw = try c.decode(JSONValue.self, forKey: AnyCodingKey("selector"))
            selector = try raw.decoded(KeyboardSelector.self)
            rawSelector = raw
            mappings = try c.decode([Pair].self, forKey: AnyCodingKey("mappings"))
            extra = try c.unknownValues(besides: ["id", "selector", "mappings"])
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            try c.encode(id, forKey: AnyCodingKey("id"))
            // A selector never changes on an existing rule. Keep metadata a newer app understands.
            let known = try JSONValue.encoding(selector)
            try c.encode(Self.merge(rawSelector, known), forKey: AnyCodingKey("selector"))
            try c.encode(mappings, forKey: AnyCodingKey("mappings"))
            try c.encodeExtra(extra)
        }

        private static func merge(_ original: JSONValue?, _ known: JSONValue) -> JSONValue {
            guard case .object(let fields) = known else { return known }
            var preserved = original?.objectValue ?? [:]
            for (key, value) in fields { preserved[key] = merge(preserved[key], value) }
            return .object(preserved)
        }
    }

    public var rules: [Rule]
    /// Interpretation of displayed symbols only. Physical HID rules do not depend on this source.
    public var inputSourceID: String?
    private var extra: [String: JSONValue] = [:]

    public init(rules: [Rule] = [], inputSourceID: String? = nil) {
        self.rules = rules
        self.inputSourceID = inputSourceID
    }

    public var ruleSets: [KeyboardRuleSet] { rules.map(\.ruleSet) }

    public var isValid: Bool {
        guard Set(rules.map(\.id)).count == rules.count else { return false }
        for (index, rule) in rules.enumerated() {
            guard !rule.id.isEmpty,
                  rule.selector.isValid,
                  !rules.dropFirst(index + 1).contains(where: { $0.selector == rule.selector }),
                  Set(rule.mappings.map(\.id)).count == rule.mappings.count,
                  Set(rule.mappings.map(\.source)).count == rule.mappings.count else { return false }
            for pair in rule.mappings {
                guard !pair.id.isEmpty, pair.source != pair.destination,
                      pair.mapping.isValid else { return false }
            }
        }
        return inputSourceID == nil || inputSourceID?.isEmpty == false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let version = try c.decode(Int.self, forKey: AnyCodingKey("version"))
        guard version == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Keyboard Remap settings require a compatible version of Lineup."))
        }
        rules = try c.decode([Rule].self, forKey: AnyCodingKey("rules"))
        inputSourceID = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("inputSourceID"))
        extra = try c.unknownValues(besides: ["version", "rules", "inputSourceID"])
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Keyboard Remap contains invalid or duplicate physical-key rules."))
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(rules, .init(codingPath: encoder.codingPath,
                debugDescription: "Keyboard Remap contains invalid or duplicate physical-key rules."))
        }
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(1, forKey: AnyCodingKey("version"))
        try c.encode(rules, forKey: AnyCodingKey("rules"))
        try c.encodeIfPresent(inputSourceID, forKey: AnyCodingKey("inputSourceID"))
        try c.encodeExtra(extra)
    }
}
