import Foundation

/// The Lineup 2.0 unified config envelope: `~/.config/lineup/config.json`.
///
/// This is a NEW file, deliberately not an evolution of `zones.json`:
///
/// 1. **Downgrade safety.** 2.0 ships to existing users as an automatic Sparkle update.
///    `zones.json` is never written, renamed, or deleted by 2.0, so rolling back to 1.x
///    finds a valid schema-3 file and just works.
/// 2. **Blast radius.** Sharing the file would force this envelope into `LineupConfig`,
///    the most safety-critical type in the repo.
/// 3. `LineupConfig.loadOrMigrate` is already the mature, tested reader for `zones.json` —
///    exactly the right thing to use as the *import source*.
///
/// Cost: `zones.json` lingers on disk forever. That is intentional; see `LegacyImport`.
public struct LineupAppConfig: Codable, Equatable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var general: GeneralConfig
    /// key == `ToolID.rawValue`. Sections are OPAQUE JSON so a future tool needs zero changes
    /// here AND an older build round-trips a newer build's unknown sections instead of
    /// deleting them.
    public var tools: [String: ToolSection]

    public init(schemaVersion: Int = LineupAppConfig.currentSchema,
                general: GeneralConfig = GeneralConfig(),
                tools: [String: ToolSection] = [:]) {
        self.schemaVersion = schemaVersion
        self.general = general
        self.tools = tools
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, general, tools }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? LineupAppConfig.currentSchema
        general = try c.decodeIfPresent(GeneralConfig.self, forKey: .general) ?? GeneralConfig()
        tools = try c.decodeIfPresent([String: ToolSection].self, forKey: .tools) ?? [:]
    }

    // MARK: - Section access

    public func section(for id: ToolID) -> ToolSection? { tools[id.rawValue] }

    /// `nil` when the tool has no section yet — the caller falls back to its own defaults.
    public func settings<T: Decodable>(_ type: T.Type, for id: ToolID) throws -> T? {
        guard let section = tools[id.rawValue] else { return nil }
        return try section.settings.decoded(type)
    }

    /// Write a tool's settings, preserving its `enabled` flag and every sibling section.
    public mutating func setSettings<T: Encodable>(_ value: T, for id: ToolID) throws {
        let encoded = try JSONValue.encoding(value)
        if var existing = tools[id.rawValue] {
            existing.settings = encoded
            tools[id.rawValue] = existing
        } else {
            tools[id.rawValue] = ToolSection(enabled: false, settings: encoded)
        }
    }

    /// `nil` when the tool has no section yet — the caller falls back to `Tool.defaultEnabled`.
    public func isEnabled(_ id: ToolID) -> Bool? { tools[id.rawValue]?.enabled }

    public mutating func setEnabled(_ enabled: Bool, for id: ToolID) {
        if var existing = tools[id.rawValue] {
            existing.enabled = enabled
            tools[id.rawValue] = existing
        } else {
            tools[id.rawValue] = ToolSection(enabled: enabled, settings: .object([:]))
        }
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
}

/// App-wide settings that belong to the shell rather than to any one tool.
public struct GeneralConfig: Codable, Equatable {
    public var showMenuBarIcon: Bool
    /// Import bookkeeping. The two flags are INDEPENDENT so a failed Cycler import never
    /// blocks the Zones import, or vice versa.
    public var didImportLegacyZones: Bool
    public var didImportLegacyCycler: Bool
    /// Gates the one-time 1.x -> 2.0 "What's New" window.
    public var didShowWhatsNew2: Bool

    public init(showMenuBarIcon: Bool = true,
                didImportLegacyZones: Bool = false,
                didImportLegacyCycler: Bool = false,
                didShowWhatsNew2: Bool = false) {
        self.showMenuBarIcon = showMenuBarIcon
        self.didImportLegacyZones = didImportLegacyZones
        self.didImportLegacyCycler = didImportLegacyCycler
        self.didShowWhatsNew2 = didShowWhatsNew2
    }

    private enum CodingKeys: String, CodingKey {
        case showMenuBarIcon, didImportLegacyZones, didImportLegacyCycler, didShowWhatsNew2
    }

    // Every key is optional so a file written by an older 2.x build keeps loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        didImportLegacyZones = try c.decodeIfPresent(Bool.self, forKey: .didImportLegacyZones) ?? false
        didImportLegacyCycler = try c.decodeIfPresent(Bool.self, forKey: .didImportLegacyCycler) ?? false
        didShowWhatsNew2 = try c.decodeIfPresent(Bool.self, forKey: .didShowWhatsNew2) ?? false
    }
}

/// One tool's slot in the envelope: whether it runs, plus its own opaque settings blob.
public struct ToolSection: Codable, Equatable {
    public var enabled: Bool
    /// Decoded by the owning tool only. Two-level versioning: the envelope has
    /// `schemaVersion`; each tool's blob is versioned by its own model (Zones carries
    /// `LineupConfig`'s schema 3 in here).
    public var settings: JSONValue

    public init(enabled: Bool, settings: JSONValue = .object([:])) {
        self.enabled = enabled
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case enabled, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        settings = try c.decodeIfPresent(JSONValue.self, forKey: .settings) ?? .object([:])
    }
}
