import CoreGraphics
import Foundation

/// Identity + metadata for a physical display, as seen at runtime. `key` is the stable
/// config key (a `CGDisplayCreateUUIDFromDisplayID` string, or a composite fallback).
public struct ScreenInfo: Equatable {
    public var key: String
    public var label: String
    public var pixelsWide: Int
    public var pixelsHigh: Int
    public var keyIsStable: Bool

    public init(key: String, label: String, pixelsWide: Int, pixelsHigh: Int, keyIsStable: Bool) {
        self.key = key
        self.label = label
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
        self.keyIsStable = keyIsStable
    }
}

/// Composite, best-effort screen key used only when the display UUID is unavailable
/// (virtual/headless displays). Never key on resolution alone — it collides on two
/// identical monitors.
public enum ScreenKey {
    /// `tieBreaker` (e.g. CGDisplay unitNumber / displayID) disambiguates two otherwise
    /// identical fallback displays (same model, serial 0, same label). Always best-effort
    /// (keyIsStable=false) — the UUID path is preferred when available.
    public static func fallback(vendor: Int, model: Int, serial: Int, width: Int, height: Int, name: String, tieBreaker: String? = nil) -> String {
        var key = "fallback:\(vendor):\(model):\(serial):\(width)x\(height):\(name)"
        if let t = tieBreaker, !t.isEmpty { key += ":\(t)" }
        return key
    }
}

public enum LineupConfigError: Error, Equatable {
    /// A present config file couldn't be recognized/decoded — surfaced rather than
    /// silently replaced, so a user's layout is never clobbered by a corrupt read.
    case unreadable
    /// The file is a newer schema than this build understands. Don't load (and risk
    /// writing it back lossily) — surface it instead.
    case unsupportedSchema(Int)
}

/// One screen's saved layout plus identifying metadata (for the Settings UI + debugging).
public struct ScreenLayout: Codable, Equatable {
    public var label: String
    public var pixelsWide: Int
    public var pixelsHigh: Int
    public var keyIsStable: Bool
    public var lastSeenAt: String?
    public var layout: Node

    public init(label: String, pixelsWide: Int, pixelsHigh: Int, keyIsStable: Bool, lastSeenAt: String?, layout: Node) {
        self.label = label
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
        self.keyIsStable = keyIsStable
        self.lastSeenAt = lastSeenAt
        self.layout = layout
    }
}

/// The whole on-disk config (schema 3): a per-display map of layouts plus a default for
/// screens not yet configured. Shortcuts (global) are added in a later phase.
public struct LineupConfig: Codable, Equatable {
    public static let currentSchema = 3

    public var schemaVersion: Int
    public var screens: [String: ScreenLayout]
    public var defaultLayout: Node

    public init(schemaVersion: Int = LineupConfig.currentSchema,
                screens: [String: ScreenLayout] = [:],
                defaultLayout: Node = .halves) {
        self.schemaVersion = schemaVersion
        self.screens = screens
        self.defaultLayout = defaultLayout
    }

    /// The layout for a screen, falling back to `defaultLayout` (halves) when unconfigured.
    public func layout(forKey key: String) -> Node {
        screens[key]?.layout ?? defaultLayout
    }

    /// Validate every stored layout (structure + unit rules). Throws on the first invalid.
    public func validate() throws {
        try defaultLayout.validate()
        for layout in screens.values.map(\.layout) { try layout.validate() }
    }

    /// Return a copy with `screen`'s layout set/updated (keeps metadata fresh).
    public func setting(layout: Node, for screen: ScreenInfo, now: String?) -> LineupConfig {
        var copy = self
        copy.screens[screen.key] = ScreenLayout(
            label: screen.label, pixelsWide: screen.pixelsWide, pixelsHigh: screen.pixelsHigh,
            keyIsStable: screen.keyIsStable, lastSeenAt: now, layout: layout)
        return copy
    }

    public func write(to url: URL) throws {
        try validate() // never persist an invalid layout — throws before touching the file
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Load schema-3 config, migrating a legacy column config in place. On migration the
    /// legacy dividers become the current screen's root vertical split, and `backup` is
    /// called with the original bytes (write a timestamped copy) before any schema-3 write.
    public static func loadOrMigrate(
        from url: URL,
        currentScreen: ScreenInfo,
        now: String,
        backup: (Data) throws -> Void
    ) throws -> (config: LineupConfig, migrated: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (LineupConfig(), false)
        }
        let data = try Data(contentsOf: url)

        // Decodes as a LineupConfig? Gate on schema version, then validate.
        if let cfg = try? JSONDecoder().decode(LineupConfig.self, from: data) {
            if cfg.schemaVersion > currentSchema {
                throw LineupConfigError.unsupportedSchema(cfg.schemaVersion)
            }
            if cfg.schemaVersion == currentSchema {
                try cfg.validate()
                return (cfg, false)
            }
            // schemaVersion < current with this shape shouldn't occur; fall through.
        }
        // Legacy ColumnConfig (dividers + halfDivider)?
        if let old = try? JSONDecoder().decode(ColumnConfig.self, from: data) {
            try backup(data)
            let root = Node.columns(old.dividers) // exact pixel values preserved as the seams
            var cfg = LineupConfig()
            cfg.screens[currentScreen.key] = ScreenLayout(
                label: currentScreen.label, pixelsWide: currentScreen.pixelsWide,
                pixelsHigh: currentScreen.pixelsHigh, keyIsStable: currentScreen.keyIsStable,
                lastSeenAt: now, layout: root)
            return (cfg, true)
        }
        // Present but unrecognized/corrupt — surface it; NEVER overwrite a user's layout
        // with a fresh default just because a read failed.
        throw LineupConfigError.unreadable
    }
}
