import Foundation
import ZonesCore

public enum TilesSettingsError: Error, Equatable, Sendable {
    case missingSchemaVersion
    case unsupportedSchema(Int)
    case invalidSchemaVersion(Int)
    case malformed
}

/// The intentionally small, user-editable Tiles settings section.  Workspace
/// count and allocation policy are product constants, not persisted options.
public struct TilesSettings: Codable, Equatable {
    public static let currentSchema = 1
    /// The one supported visual rhythm.  The setting only controls whether
    /// this spacing is on; arbitrary gap tuning is intentionally out of scope.
    public static let tileSpacingPoints: CGFloat = 8

    public var schemaVersion: Int
    /// Keep the visual rhythm of tiled windows enabled by default.  This is a
    /// single opinionated switch instead of separate inner/outer gap knobs.
    public var tileSpacingEnabled: Bool
    public var nextWorkspace: ShortcutBinding?
    public var nextWindow: ShortcutBinding?
    public var moveWindowToNextWorkspace: ShortcutBinding?
    public var focusTileLeft: ShortcutBinding?
    public var focusTileRight: ShortcutBinding?
    public var focusTileUp: ShortcutBinding?
    public var focusTileDown: ShortcutBinding?
    public var moveWindowLeft: ShortcutBinding?
    public var moveWindowRight: ShortcutBinding?
    public var moveWindowUp: ShortcutBinding?
    public var moveWindowDown: ShortcutBinding?
    public var toggleSplitOrientation: ShortcutBinding?

    public init(schemaVersion: Int = TilesSettings.currentSchema,
                tileSpacingEnabled: Bool = true,
                nextWorkspace: ShortcutBinding? = nil,
                nextWindow: ShortcutBinding? = nil,
                moveWindowToNextWorkspace: ShortcutBinding? = nil,
                focusTileLeft: ShortcutBinding? = nil,
                focusTileRight: ShortcutBinding? = nil,
                focusTileUp: ShortcutBinding? = nil,
                focusTileDown: ShortcutBinding? = nil,
                moveWindowLeft: ShortcutBinding? = nil,
                moveWindowRight: ShortcutBinding? = nil,
                moveWindowUp: ShortcutBinding? = nil,
                moveWindowDown: ShortcutBinding? = nil,
                toggleSplitOrientation: ShortcutBinding? = nil) {
        self.schemaVersion = schemaVersion
        self.tileSpacingEnabled = tileSpacingEnabled
        self.nextWorkspace = nextWorkspace
        self.nextWindow = nextWindow
        self.moveWindowToNextWorkspace = moveWindowToNextWorkspace
        self.focusTileLeft = focusTileLeft
        self.focusTileRight = focusTileRight
        self.focusTileUp = focusTileUp
        self.focusTileDown = focusTileDown
        self.moveWindowLeft = moveWindowLeft
        self.moveWindowRight = moveWindowRight
        self.moveWindowUp = moveWindowUp
        self.moveWindowDown = moveWindowDown
        self.toggleSplitOrientation = toggleSplitOrientation
    }

    public static let `default` = TilesSettings()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case tileSpacingEnabled
        case nextWorkspace
        case nextWindow
        case moveWindowToNextWorkspace
        case focusTileLeft
        case focusTileRight
        case focusTileUp
        case focusTileDown
        case moveWindowLeft
        case moveWindowRight
        case moveWindowUp
        case moveWindowDown
        case toggleSplitOrientation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.schemaVersion) else {
            throw TilesSettingsError.missingSchemaVersion
        }
        let schema = try container.decode(Int.self, forKey: .schemaVersion)
        guard schema == Self.currentSchema else {
            if schema > Self.currentSchema { throw TilesSettingsError.unsupportedSchema(schema) }
            throw TilesSettingsError.invalidSchemaVersion(schema)
        }
        self.schemaVersion = schema
        self.tileSpacingEnabled = try container.decodeIfPresent(Bool.self, forKey: .tileSpacingEnabled) ?? true
        self.nextWorkspace = try container.decodeIfPresent(ShortcutBinding.self, forKey: .nextWorkspace)
        self.nextWindow = try container.decodeIfPresent(ShortcutBinding.self, forKey: .nextWindow)
        self.moveWindowToNextWorkspace = try container.decodeIfPresent(ShortcutBinding.self, forKey: .moveWindowToNextWorkspace)
        self.focusTileLeft = try container.decodeIfPresent(ShortcutBinding.self, forKey: .focusTileLeft)
        self.focusTileRight = try container.decodeIfPresent(ShortcutBinding.self, forKey: .focusTileRight)
        self.focusTileUp = try container.decodeIfPresent(ShortcutBinding.self, forKey: .focusTileUp)
        self.focusTileDown = try container.decodeIfPresent(ShortcutBinding.self, forKey: .focusTileDown)
        self.moveWindowLeft = try container.decodeIfPresent(ShortcutBinding.self, forKey: .moveWindowLeft)
        self.moveWindowRight = try container.decodeIfPresent(ShortcutBinding.self, forKey: .moveWindowRight)
        self.moveWindowUp = try container.decodeIfPresent(ShortcutBinding.self, forKey: .moveWindowUp)
        self.moveWindowDown = try container.decodeIfPresent(ShortcutBinding.self, forKey: .moveWindowDown)
        self.toggleSplitOrientation = try container.decodeIfPresent(ShortcutBinding.self, forKey: .toggleSplitOrientation)
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tileSpacingEnabled, forKey: .tileSpacingEnabled)
        // Encode nulls explicitly.  This keeps the stable section shape and
        // makes an unassigned recorder distinguishable from a missing field.
        try container.encode(nextWorkspace, forKey: .nextWorkspace)
        try container.encode(nextWindow, forKey: .nextWindow)
        try container.encode(moveWindowToNextWorkspace, forKey: .moveWindowToNextWorkspace)
        try container.encode(focusTileLeft, forKey: .focusTileLeft)
        try container.encode(focusTileRight, forKey: .focusTileRight)
        try container.encode(focusTileUp, forKey: .focusTileUp)
        try container.encode(focusTileDown, forKey: .focusTileDown)
        try container.encode(moveWindowLeft, forKey: .moveWindowLeft)
        try container.encode(moveWindowRight, forKey: .moveWindowRight)
        try container.encode(moveWindowUp, forKey: .moveWindowUp)
        try container.encode(moveWindowDown, forKey: .moveWindowDown)
        try container.encode(toggleSplitOrientation, forKey: .toggleSplitOrientation)
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchema else {
            if schemaVersion > Self.currentSchema {
                throw TilesSettingsError.unsupportedSchema(schemaVersion)
            }
            throw TilesSettingsError.invalidSchemaVersion(schemaVersion)
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> TilesSettings {
        try JSONDecoder().decode(TilesSettings.self, from: data)
    }

    /// A non-throwing boundary helper for settings stores.  A rejected/future
    /// section can be retained by the shell as raw JSON while live settings
    /// stay at defaults and perform no window mutations.
    public static func decodeSafely(_ data: Data) -> Result<TilesSettings, TilesSettingsError> {
        do {
            return .success(try decode(data))
        } catch let error as TilesSettingsError {
            return .failure(error)
        } catch {
            return .failure(.malformed)
        }
    }
}
