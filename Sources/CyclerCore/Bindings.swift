import Foundation
import HyperkeyCore

// Hyperkey is its own tool in Lineup 2.0; these types moved to HyperkeyCore. The aliases keep
// `CyclerConfig.hyperKey` (the LEGACY ~/.config/cycler/bindings.json shape) decodable and keep
// every existing CyclerCore test compiling unchanged. Do not remove.
public typealias TriggerKey = HyperkeyCore.TriggerKey
public typealias HyperKeySettings = HyperkeyCore.HyperKeySettings

/// A single hotkey: a Carbon key code + modifier mask that, when pressed, drives one or more apps.
///
/// `bundleIdentifiers` is an ordered, non-empty list of target apps:
/// - One app: press to bring it forward, press again to cycle its windows (the original behaviour).
/// - Two or more apps (an "app group"): press to cycle between the apps in this order, giving up
///   per-window cycling. See `AppGroupCycle` for the pure decision logic.
///
/// `keyCode` is a Carbon virtual key (kVK_*). `modifiers` is a Carbon modifier mask (the value
/// `HotkeyManager.hyper` produces for ⌃⌥⇧⌘). Storing raw Carbon values keeps the config in the
/// same vocabulary the hotkey registration uses, so there's no NSEvent<->Carbon translation here.
public struct AppBinding: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var modifiers: UInt32
    public var bundleIdentifiers: [String]

    /// Convenience for a single-app binding (the common case, and what existing call sites use).
    public init(keyCode: Int, modifiers: UInt32, bundleIdentifier: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.bundleIdentifiers = [bundleIdentifier]
    }

    /// Multi-app (or single-app) binding. `bundleIdentifiers` must be non-empty.
    public init(keyCode: Int, modifiers: UInt32, bundleIdentifiers: [String]) {
        precondition(!bundleIdentifiers.isEmpty, "bundleIdentifiers must not be empty")
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.bundleIdentifiers = bundleIdentifiers
    }

    /// The first target — the app a single-app binding drives, or a group's first member.
    public var bundleIdentifier: String { bundleIdentifiers[0] }

    /// Two or more apps means "cycle between apps" instead of "cycle one app's windows".
    public var isGroup: Bool { bundleIdentifiers.count > 1 }

    // MARK: - Codable

    // Canonical on-disk shape is `bundleIdentifiers: [String]`. Legacy files wrote a single
    // `bundleIdentifier: String`; we still decode those, but always re-encode the array shape.
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, bundleIdentifiers, bundleIdentifier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(Int.self, forKey: .keyCode)
        modifiers = try c.decode(UInt32.self, forKey: .modifiers)
        if let ids = try c.decodeIfPresent([String].self, forKey: .bundleIdentifiers) {
            guard !ids.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bundleIdentifiers, in: c,
                    debugDescription: "bundleIdentifiers must not be empty")
            }
            bundleIdentifiers = ids
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier) {
            bundleIdentifiers = [legacy]
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .bundleIdentifiers, in: c,
                debugDescription: "a binding needs bundleIdentifiers (or legacy bundleIdentifier)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(modifiers, forKey: .modifiers)
        try c.encode(bundleIdentifiers, forKey: .bundleIdentifiers)
    }
}


/// The on-disk config: the user's per-app bindings. Loaded from
/// `~/.config/cycler/bindings.json`. A missing or empty file is valid (no shortcuts bound yet).
public struct CyclerConfig: Codable, Equatable, Sendable {
    public var bindings: [AppBinding]
    public var hyperKey: HyperKeySettings
    public var showMenuBarIcon: Bool

    public init(bindings: [AppBinding] = [],
                hyperKey: HyperKeySettings = .disabled,
                showMenuBarIcon: Bool = true) {
        self.bindings = bindings
        self.hyperKey = hyperKey
        self.showMenuBarIcon = showMenuBarIcon
    }

    // Settings added after the original binding format are optional so existing files keep their
    // established behavior instead of failing to load.
    private enum CodingKeys: String, CodingKey {
        case bindings, hyperKey, showMenuBarIcon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindings = try c.decode([AppBinding].self, forKey: .bindings)
        hyperKey = try c.decodeIfPresent(HyperKeySettings.self, forKey: .hyperKey) ?? .disabled
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bindings, forKey: .bindings)
        try c.encode(hyperKey, forKey: .hyperKey)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
    }

    /// Decode from raw JSON bytes. Throws on malformed JSON (the caller surfaces it and keeps an
    /// empty config rather than clobbering the file — see Sources/AppCore/LegacyImport.swift).
    public static func decode(_ data: Data) throws -> CyclerConfig {
        try JSONDecoder().decode(CyclerConfig.self, from: data)
    }

    /// Encode to pretty, stable JSON for writing back to disk.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// Coalesce repeated shortcut combos into app groups. The first binding for a shortcut keeps
    /// its position and app order; later duplicates append any new apps to that group.
    public func coalescingDuplicateShortcuts() -> CyclerConfig {
        var indexByShortcut: [BindingShortcut: Int] = [:]
        var merged: [AppBinding] = []

        for binding in bindings {
            let shortcut = BindingShortcut(keyCode: binding.keyCode, modifiers: binding.modifiers)
            guard let existingIndex = indexByShortcut[shortcut] else {
                indexByShortcut[shortcut] = merged.count
                merged.append(binding)
                continue
            }

            var existing = merged[existingIndex]
            var seen = Set(existing.bundleIdentifiers)
            for bundleIdentifier in binding.bundleIdentifiers where !seen.contains(bundleIdentifier) {
                existing.bundleIdentifiers.append(bundleIdentifier)
                seen.insert(bundleIdentifier)
            }
            merged[existingIndex] = existing
        }

        return CyclerConfig(bindings: merged, hyperKey: hyperKey, showMenuBarIcon: showMenuBarIcon)
    }
}

private struct BindingShortcut: Hashable {
    var keyCode: Int
    var modifiers: UInt32
}
