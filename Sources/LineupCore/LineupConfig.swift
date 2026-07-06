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
    /// `tieBreaker` (e.g. CGDisplay unitNumber + displayID) disambiguates two otherwise
    /// identical fallback displays (same model, serial 0, same label). Always best-effort
    /// (keyIsStable=false) — the UUID path is preferred when available.
    public static func fallback(vendor: Int, model: Int, serial: Int, width: Int, height: Int, name: String, tieBreaker: String? = nil) -> String {
        var key = "fallback:\(vendor):\(model):\(serial):\(width)x\(height):\(name)"
        if let t = tieBreaker, !t.isEmpty { key += ":\(t)" }
        return key
    }

    /// Previous fallback builds used either the unsalted composite or a bare unit number
    /// suffix. New tagged fallback keys should still read those layouts, but direct keys win.
    public static func fallbackAliases(for key: String) -> [String] {
        guard key.hasPrefix("fallback:") else { return [] }

        let unsalted: String
        let unit: String?
        if let displayRange = key.range(of: ":display:", options: .backwards) {
            let beforeDisplay = String(key[..<displayRange.lowerBound])
            if let unitRange = beforeDisplay.range(of: ":unit:", options: .backwards) {
                unsalted = String(beforeDisplay[..<unitRange.lowerBound])
                unit = String(beforeDisplay[unitRange.upperBound...])
            } else {
                unsalted = beforeDisplay
                unit = nil
            }
        } else if let frameRange = key.range(of: ":frame:", options: .backwards) {
            let beforeFrame = String(key[..<frameRange.lowerBound])
            if let unitRange = beforeFrame.range(of: ":unit:", options: .backwards) {
                unsalted = String(beforeFrame[..<unitRange.lowerBound])
                unit = String(beforeFrame[unitRange.upperBound...])
            } else {
                unsalted = beforeFrame
                unit = nil
            }
        } else {
            return []
        }

        var aliases: [String] = []
        if let unit, !unit.isEmpty { aliases.append("\(unsalted):\(unit)") }
        aliases.append(unsalted)
        return aliases.reduce(into: []) { result, alias in
            if alias != key && !result.contains(alias) { result.append(alias) }
        }
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

/// The result of `loadOrMigrate`, made explicit so the runtime can distinguish a genuinely
/// fresh config (writable) from a deferred legacy migration (writes must be blocked so a
/// save can't overwrite the still-present legacy file).
public enum LoadOutcome: Equatable {
    case loaded(LineupConfig)    // schema-3 read and validated
    case migrated(LineupConfig)  // legacy upgraded; caller should persist
    case fresh(LineupConfig)     // no file present; fresh defaults (writable)
    case deferred                // legacy present but its display is absent; DON'T write
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
    /// Global shortcuts (optional; nil means "use the app's defaults"). Backward-compatible:
    /// a schema-3 file written before shortcuts existed decodes with this absent.
    public var shortcuts: Shortcuts?
    /// Whether modifier-drag-to-snap is enabled. Optional/backward-compatible like `shortcuts`:
    /// a config written before this existed decodes as nil, which the app treats as the
    /// default (on). When the user turns it off, persisting `false` keeps the global mouse
    /// monitor uninstalled at the next launch.
    public var dragSnapEnabled: Bool?
    /// Carbon modifier mask for drag-snap activation. Optional/backward-compatible:
    /// nil means the legacy/default Shift-drag behavior. The app normalizes unsupported
    /// masks to Shift when reading this, so hand-edited configs don't break dragging.
    public var dragSnapModifiers: Int?
    /// Optional Carbon virtual key code for drag-snap activation. nil means modifier-only,
    /// which preserves the legacy Shift-drag behavior and the first configurable-modifier
    /// builds.
    public var dragSnapKeyCode: Int?

    public init(schemaVersion: Int = LineupConfig.currentSchema,
                screens: [String: ScreenLayout] = [:],
                defaultLayout: Node = .halves,
                shortcuts: Shortcuts? = nil,
                dragSnapEnabled: Bool? = nil,
                dragSnapModifiers: Int? = nil,
                dragSnapKeyCode: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.screens = screens
        self.defaultLayout = defaultLayout
        self.shortcuts = shortcuts
        self.dragSnapEnabled = dragSnapEnabled
        self.dragSnapModifiers = dragSnapModifiers
        self.dragSnapKeyCode = dragSnapKeyCode
    }

    /// The layout for a screen, falling back to `defaultLayout` (halves) when unconfigured.
    public func layout(forKey key: String) -> Node {
        if let layout = screens[key]?.layout { return layout }
        for alias in ScreenKey.fallbackAliases(for: key) {
            if let layout = screens[alias]?.layout { return layout }
        }
        return defaultLayout
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

    /// Physical width a legacy config implies, from its pixel half-divider (`value * 2`),
    /// or nil when it can't be inferred (non-pixel half-divider). Used to migrate the
    /// seams onto the display they were actually drawn on.
    public static func inferredLegacyWidth(_ old: ColumnConfig) -> Int? {
        guard old.halfDivider.unit == .pixels else { return nil }
        return Int((old.halfDivider.value * 2).rounded())
    }

    /// Load schema-3 config, migrating a legacy column config in place. `resolveLegacyTarget`
    /// returns the screen the legacy seams belong on, or nil to DEFER (leave the legacy file
    /// untouched and retry next launch — e.g. the original display is disconnected). `backup`
    /// must succeed (it can throw) before any schema-3 write; on migration we never persist
    /// unless the original bytes were safely backed up.
    public static func loadOrMigrate(
        from url: URL,
        now: String,
        backup: (Data) throws -> Void,
        resolveLegacyTarget: (ColumnConfig) -> ScreenInfo?
    ) throws -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fresh(LineupConfig())
        }
        let data = try Data(contentsOf: url)

        // Decodes as a LineupConfig? Gate on schema version, then validate.
        if let cfg = try? JSONDecoder().decode(LineupConfig.self, from: data) {
            if cfg.schemaVersion > currentSchema {
                throw LineupConfigError.unsupportedSchema(cfg.schemaVersion)
            }
            if cfg.schemaVersion == currentSchema {
                try cfg.validate()
                return .loaded(cfg)
            }
            // schemaVersion < current with this shape shouldn't occur; fall through.
        }
        // Legacy ColumnConfig (dividers + halfDivider)?
        if let old = try? JSONDecoder().decode(ColumnConfig.self, from: data) {
            guard let target = resolveLegacyTarget(old) else {
                return .deferred // legacy present, target display absent: don't touch the file
            }
            try backup(data) // must succeed before we risk replacing the only legacy copy
            let root = Node.columns(old.dividers) // exact pixel values preserved as the seams
            var cfg = LineupConfig()
            cfg.screens[target.key] = ScreenLayout(
                label: target.label, pixelsWide: target.pixelsWide,
                pixelsHigh: target.pixelsHigh, keyIsStable: target.keyIsStable,
                lastSeenAt: now, layout: root)
            return .migrated(cfg)
        }
        // Present but unrecognized/corrupt — surface it; NEVER overwrite a user's layout
        // with a fresh default just because a read failed.
        throw LineupConfigError.unreadable
    }
}
