import Foundation

/// A key-code + modifiers activation shortcut, stored directly as repository primitives
/// (`keyCode: Int`, `modifiers: UInt32`). No Carbon/AppKit/semantic-modifier types live in
/// HintsCore; the Input lane maps platform constants at its boundary.
///
/// Decode is strict about JSON types (wrong types throw, which blocks Hints behavior) and
/// lenient about ranges (negative/oversized values normalize to the unassigned/empty form
/// so a poisoned value never reserves a global combination). Unknown object members a
/// newer schema might add are preserved verbatim and never overwrite the known fields on
/// encode.
public struct HintShortcut: Codable, Equatable, Hashable, Sendable {
    /// `-1` represents unassigned; valid Carbon virtual key codes are non-negative.
    public static let unassignedKeyCode = -1

    public var keyCode: Int
    public var modifiers: UInt32
    /// Unknown object members beyond `keyCode`/`modifiers`, preserved verbatim.
    public var extra: [String: HintJSONValue]

    public init(keyCode: Int, modifiers: UInt32 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.extra = [:]
    }

    /// Assigned iff the key code is in the carrier range AND the modifiers are nonzero —
    /// the same complete predicate normalization uses. Post-init mutation is governed at
    /// the SETTINGS encode boundary: an unassigned (mutated invalid) carrier never emits
    /// the known fields, and its nested unknown members are preserved as unknown-only data.
    public var isAssigned: Bool {
        keyCode >= 0 && keyCode <= Int(Int64(UInt32.max)) && modifiers != 0
    }

    /// Lenient normalization unifier used by decoders and initializers. A shortcut is
    /// ASSIGNED only when both halves pass: the key code must be a nonnegative value that
    /// fits the UInt32 carrier (a valid Carbon virtual key code fits comfortably), AND the
    /// modifiers must be nonzero — a bare global combination with no modifiers is never
    /// preserved. Anything else makes the WHOLE shortcut unassigned rather than
    /// preserving a poisonous half.
    public func normalizedLeniently() -> HintShortcut? {
        guard keyCode >= 0, keyCode <= Int(Int64(UInt32.max)), modifiers != 0 else { return nil }
        return self
    }

    fileprivate static let knownKeys: Set<String> = ["keyCode", "modifiers"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: HintAnyCodingKey.self)
        if container.contains(HintAnyCodingKey.init("keyCode")) {
            keyCode = try container.decode(Int.self, forKey: HintAnyCodingKey.init("keyCode"))
        } else {
            keyCode = HintShortcut.unassignedKeyCode
        }
        if container.contains(HintAnyCodingKey.init("modifiers")) {
            // Int64 carrier first: a value outside UInt32 range is a lenient fallback
            // (modifiers clear), while a wrong JSON type still throws below.
            let stored = try container.decode(Int64.self, forKey: HintAnyCodingKey.init("modifiers"))
            modifiers = (stored >= 0 && stored <= Int64(UInt32.max)) ? UInt32(stored) : 0
        } else {
            modifiers = 0
        }
        extra = try container.unknownValues(besides: HintShortcut.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: HintAnyCodingKey.self)
        try container.encode(keyCode, forKey: HintAnyCodingKey.init("keyCode"))
        if modifiers != 0 {
            try container.encode(modifiers, forKey: HintAnyCodingKey.init("modifiers"))
        }
        try container.encodeUnknown(extra, besides: HintShortcut.knownKeys)
    }
}

/// Tool-local, versioned Hints settings stored inside the opaque `tools.hints` config
/// section (`ToolSection.settings`). Enablement is NOT owned here: the authoritative
/// `enabled` flag lives in the repository `ToolSection` for every tool; this type owns
/// only Hints-specific configuration.
///
/// Contract (frozen Phase 0 defaults, remediated in Gate 2):
/// - the version is owned and encoded; a missing version decodes as the current schema;
///   a malformed version type throws; a version greater than the current one fails closed
///   with `unsupportedVersion` so AppCore retains the opaque blob and callers must block
///   Hints writes and side effects;
/// - known fields use typed decode: wrong JSON types throw (malformed section blocks
///   Hints behavior);
/// - unknown current-schema fields, including nested shortcut members, are preserved and
///   can never overwrite known fields on encode; nested unknown members even survive on a
///   shortcut whose effective assignment is invalid (they re-emerge as an unknown-only
///   `activationShortcut` object);
/// - "unassigned" activation shortcut is an absent `activationShortcut` key, an explicit
///   null, or a shortcut that fails assignment (negative/oversized key code, or zero/
///   missing/oversized modifiers): an unassigned carrier never emits known fields, so a
///   disabled tool never reserves a global combination — including a bare modifierless one;
/// the version is owned and encoded AFTER the unknowns note; per nested-merge rules the
/// assigned shortcut's own extra values win over newly merged preserved ones.
public struct HintsSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// Stable single source of the release alphabet; `HintLabelMaker` and settings agree.
    public static let defaultAlphabet = HintLabelMaker.defaultAlphabet

    public var activationShortcut: HintShortcut?
    public var alphabet: String
    /// Tool-local schema version, owned and encoded (always current on write).
    public private(set) var version: Int
    /// Unknown top-level fields (current schema), preserved verbatim across round-trips.
    public var extra: [String: HintJSONValue]

    public init(activationShortcut: HintShortcut? = nil, alphabet: String = HintLabelMaker.defaultAlphabet) {
        // The carrier is stored verbatim; encode-time assignment gating governs output.
        // An invalid carrier with nested unknown members stays so those members survive
        // as unknown-only data; one without members is simply never emitted.
        self.activationShortcut = activationShortcut
        self.alphabet = HintsSettings.validatedAlphabet(alphabet)
        self.version = HintsSettings.currentVersion
        self.extra = [:]
    }

    /// Assignment-time helper: stores a shortcut and merges the previous UNASSIGNED
    /// carrier's nested unknown members into it. Unknown members never shadow known
    /// fields (encoding always excludes known keys from `extra`), and when both sides
    /// carry the same unknown name the incoming (currently assigned) shortcut wins.
    public mutating func assignShortcut(_ shortcut: HintShortcut) {
        var incoming = shortcut
        if let previous = activationShortcut, !previous.isAssigned, !previous.extra.isEmpty {
            for (key, value) in previous.extra where incoming.extra[key] == nil {
                incoming.extra[key] = value
            }
        }
        activationShortcut = incoming
    }

    /// Lenient alphabet validation: the value must be exactly what `HintLabelMaker`
    /// accepts (nonempty, ASCII letters, case-insensitively unique); anything invalid —
    /// including an empty string — falls back to the frozen default instead. Keeps the
    /// stored value as given so valid user casing round-trips.
    public static func validatedAlphabet(_ alphabet: String) -> String {
        if let maker = try? HintLabelMaker(alphabet: alphabet), !maker.normalizedAlphabet.isEmpty {
            return alphabet
        }
        return HintLabelMaker.defaultAlphabet
    }

    public static let unassigned = HintsSettings()

    private static let knownKeys: Set<String> = ["version", "activationShortcut", "alphabet"]

    public enum SettingsError: Error, Equatable, Sendable {
        /// The section encodes a newer Hints schema than this build understands. Callers
        /// must fail closed: no Hints side effects, no Hints writes, opaque blob retained.
        case unsupportedVersion(Int)
        /// A known field carried the wrong JSON type (count-only diagnosis: field name).
        case malformedKnownValue(String)
    }

    private enum KnownField: String, CaseIterable {
        case version
        case activationShortcut
        case alphabet
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: HintAnyCodingKey.self)

        let versionKey = HintAnyCodingKey.init(KnownField.version.rawValue)
        if container.contains(versionKey) {
            version = try container.decode(Int.self, forKey: versionKey)
            guard version <= HintsSettings.currentVersion else {
                throw SettingsError.unsupportedVersion(version)
            }
            if version <= 0 { version = HintsSettings.currentVersion }
        } else {
            version = HintsSettings.currentVersion
        }

        let shortcutKey = HintAnyCodingKey.init(KnownField.activationShortcut.rawValue)
        // The carrier is stored verbatim even when assignment fails: nested unknown
        // members live independently from effective assignment and must survive.
        activationShortcut = try container.decodeIfPresent(HintShortcut.self, forKey: shortcutKey)

        let alphabetKey = HintAnyCodingKey.init(KnownField.alphabet.rawValue)
        if container.contains(alphabetKey) {
            alphabet = HintsSettings.validatedAlphabet(try container.decode(String.self, forKey: alphabetKey))
        } else {
            alphabet = HintLabelMaker.defaultAlphabet
        }

        extra = try container.unknownValues(besides: HintsSettings.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: HintAnyCodingKey.self)
        try container.encode(HintsSettings.currentVersion, forKey: HintAnyCodingKey.init(KnownField.version.rawValue))
        let shortcutKey = HintAnyCodingKey.init(KnownField.activationShortcut.rawValue)
        if let carrier = activationShortcut {
            if carrier.isAssigned {
                // Assigned: emit the known fields (from the assigned carrier) plus any
                // nested unknown members it carries. Unknown members may never replace
                // known fields (the helpers already exclude known keys).
                try container.encode(carrier, forKey: shortcutKey)
            } else if !carrier.extra.isEmpty {
                // Unassigned but carrying nested unknown members: emit ONLY the unknown
                // members inside the activationShortcut object. No keyCode/modifiers are
                // re-emitted, so the next decode stays unassigned while preserving the
                // newer schema's data.
                var object = container.nestedContainer(keyedBy: HintAnyCodingKey.self, forKey: shortcutKey)
                try object.encodeUnknown(carrier.extra, besides: HintShortcut.knownKeys)
            }
            // Unassigned without members: the key is omitted entirely.
        }
        try container.encode(alphabet, forKey: HintAnyCodingKey.init(KnownField.alphabet.rawValue))
        try container.encodeUnknown(extra, besides: HintsSettings.knownKeys)
    }
}
