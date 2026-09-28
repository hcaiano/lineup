import Foundation

/// Pure preparation of a config for a set of CONNECTED screens before runtime zone
/// numbering. Deterministic and testable without AppKit: input is a base `LineupConfig`
/// plus the connected screens as `[ScreenInfo]` (already in the desired initial order —
/// the runtime supplies its spatial left-to-right/top-to-bottom ordering).
///
/// Ownership rule (durable, not spatial):
/// - An EXACT config entry for a screen's key always wins and is left untouched.
/// - Unambiguous ADOPTION: a connected screen with no exact entry MOVES (never copies) a
///   saved fallback-alias entry to its exact live key when (a) exactly ONE saved alias
///   from `ScreenKey.fallbackAliases(for:)` exists for it and (b) exactly ONE connected
///   screen claims that alias, and (c) the alias is not itself another connected screen's
///   exact key. The whole `ScreenLayout` (layout, metadata, `shortcutOrder`) is preserved
///   byte-for-byte and the old alias key is REMOVED — so once persisted, ownership of a
///   display's numbering is durable and no live display stays bound to a legacy alias.
/// - AMBIGUOUS ownership (several connected screens claim one alias, or one screen has
///   several saved aliases): the alias is NOT assigned to any live screen. It stays in
///   the config as a disconnected/reserved entry, and every claiming screen is
///   materialized under its exact key with current `ScreenInfo` metadata, the EFFECTIVE
///   `layout(forKey:)` read-through, and nil `shortcutOrder`. Old alias shortcuts then
///   safely no-op instead of retargeting an arbitrary display.
/// - Disconnected saved entries are never touched.
/// - Repeated `ScreenInfo` keys are deduplicated keeping the FIRST occurrence, so the
///   returned `connectedKeys` are unique; later duplicates are ignored deterministically.
/// The result of `prepare`: the prepared config plus each connected screen's exact key.
public struct PreparedZoneScreens: Equatable {
    /// The prepared config: exact entries for connected screens, adoptions moved,
    /// disconnected entries preserved.
    public var config: LineupConfig
    /// The EXACT config key of each connected screen, in the supplied order (unique).
    /// After preparation every live display is bound to its exact current key.
    public var connectedKeys: [String]

    public init(config: LineupConfig, connectedKeys: [String]) {
        self.config = config
        self.connectedKeys = connectedKeys
    }
}

public enum ZoneScreenPreparation {
    public static func prepare(config base: LineupConfig, screens: [ScreenInfo]) -> PreparedZoneScreens {
        // Deduplicate repeated keys, keeping the first occurrence (deterministic: input
        // order is the caller's intended initial order).
        var seen = Set<String>()
        let unique = screens.filter { seen.insert($0.key).inserted }

        var out = base
        let exactKeys = unique.map(\.key)
        let exactSet = Set(exactKeys)

        // Alias claims, computed up front so ambiguity is judged on the WHOLE set, not on
        // mutation order.
        var savedAliases: [String: [String]] = [:]  // screen key -> saved alias candidates
        var claims: [String: [String]] = [:]        // alias -> claiming connected screen keys
        for screen in unique {
            let saved = ScreenKey.fallbackAliases(for: screen.key).filter { base.screens[$0] != nil }
            savedAliases[screen.key] = saved
            for alias in saved { claims[alias, default: []].append(screen.key) }
        }

        for screen in unique {
            // Exact entries always win and remain untouched.
            if out.screens[screen.key] != nil { continue }
            var adopted = false
            if let saved = savedAliases[screen.key], saved.count == 1, let alias = saved.first,
               claims[alias]?.count == 1,               // exactly one connected screen claims it
               !exactSet.contains(alias) {              // never steal another connected screen's exact entry
                if let entry = out.screens[alias] {
                    out.screens[screen.key] = entry      // MOVE: layout, metadata and order preserved
                    out.screens[alias] = nil
                    adopted = true
                }
            }
            if !adopted {
                out.screens[screen.key] = ScreenLayout(
                    label: screen.label, pixelsWide: screen.pixelsWide, pixelsHigh: screen.pixelsHigh,
                    keyIsStable: screen.keyIsStable, lastSeenAt: nil,
                    layout: base.layout(forKey: screen.key), shortcutOrder: nil)
            }
        }
        return PreparedZoneScreens(config: out, connectedKeys: exactKeys)
    }
}
