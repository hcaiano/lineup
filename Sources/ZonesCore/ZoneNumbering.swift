import Foundation

/// Stable global zone numbering across saved displays (pure; no AppKit / no runtime state).
///
/// Zone shortcuts are global (`zone:1`…`zone:N`) but layouts are per-display. To keep a
/// given zone on a given display reachable at the same global number even when displays are
/// connected/reordered, every saved `ScreenLayout` carries a persisted `shortcutOrder`
/// (1-based display position). The normalizer repairs/assigns those orders deterministically;
/// the `ZoneNumbering` map turns a global 1-based zone number into (display key, local zone).
///
/// All functions here are deterministic and idempotent, and safe to run on plain decoded
/// configs — including hand-edited ones with missing, duplicate, or non-positive orders.

/// A saved display's slot in the global numbering: metadata + the 1-based global number of
/// its first zone (meaningful only when `zoneCount > 0`; zero-zone layouts consume nothing).
public struct ZoneNumberingDisplay: Equatable {
    public var key: String
    public var label: String
    public var order: Int            // persisted 1-based display order
    public var zoneCount: Int
    /// Global 1-based number of local zone 0; nil when the layout has no zones.
    public var firstZoneNumber: Int?

    public init(key: String, label: String, order: Int, zoneCount: Int, firstZoneNumber: Int?) {
        self.key = key
        self.label = label
        self.order = order
        self.zoneCount = zoneCount
        self.firstZoneNumber = firstZoneNumber
    }
}

/// The global numbering map over ALL saved screen layouts, sorted by persisted display
/// order. Disconnected-but-saved layouts keep their place (and reserve their zone ranges);
/// zero-zone layouts are present as metadata but consume no numbers. Invalid global numbers
/// resolve to nil.
public struct ZoneNumbering: Equatable {
    public var displays: [ZoneNumberingDisplay]
    /// Total number of globally addressable zones (zero-zone layouts excluded).
    public var totalZones: Int

    /// Build from the saved layouts. Only layouts with a valid (positive) persisted order
    /// participate; entries are sorted by (order, label, key) so equal/hand-edited orders
    /// still produce a deterministic map. Runtime code should run
    /// `ZoneOrderNormalizer.normalizeOrders` first so every layout has a stable order.
    public init(config: LineupConfig) {
        let ordered = config.screens
            .filter { $0.value.shortcutOrder != nil && $0.value.shortcutOrder! > 0 }
            .map { (key: $0.key, layout: $0.value) }
            .sorted { a, b in
                let oa = a.layout.shortcutOrder!, ob = b.layout.shortcutOrder!
                if oa != ob { return oa < ob }
                if a.layout.label != b.layout.label { return a.layout.label < b.layout.label }
                return a.key < b.key
            }
        var out: [ZoneNumberingDisplay] = []
        var next = 1
        for entry in ordered {
            let count = ZoneNumbering.leafCount(entry.layout.layout)
            let first = count > 0 ? next : nil
            out.append(ZoneNumberingDisplay(
                key: entry.key, label: entry.layout.label,
                order: entry.layout.shortcutOrder!, zoneCount: count, firstZoneNumber: first))
            next += count
        }
        self.displays = out
        self.totalZones = next - 1
    }

    /// Map a global 1-based zone number to its display key + local zero-based zone index.
    /// Zero-zone layouts are skipped (they consume no numbers); numbers outside the total
    /// range resolve to nil.
    public func resolve(globalNumber: Int) -> (key: String, zoneIndex: Int)? {
        guard globalNumber >= 1 else { return nil }
        // No gaps exist: zero-zone layouts advance the counter by zero, so the nonzero
        // ranges tile 1...totalZones contiguously.
        for display in displays {
            guard display.zoneCount > 0, let first = display.firstZoneNumber else { continue }
            if globalNumber < first + display.zoneCount {
                return (display.key, globalNumber - first)
            }
        }
        return nil
    }

    /// Number of leaf zones in a layout tree, without needing frames/geometry.
    public static func leafCount(_ node: Node) -> Int {
        switch node {
        case .leaf: return 1
        case let .split(_, _, children): return children.reduce(0) { $0 + leafCount($1) }
        }
    }
}

/// Deterministic assignment/repair of the per-display `shortcutOrder` used by
/// `ZoneNumbering`.
///
/// Priority order (the order screens are visited, both when keeping persisted values and
/// when assigning fresh ones):
/// 1. connected screens, in the supplied initial order;
/// 2. remaining (disconnected) saved screens, sorted by (label, key) as a stable fallback.
///
/// Rules:
/// - A persisted order is KEPT only if it is positive and not already claimed by an
///   earlier-in-priority screen; anything else (missing, zero/negative, duplicated) is
///   repaired.
/// - Repaired screens APPEND after ALL retained displays: they take `maxRetained + 1`,
///   `maxRetained + 2`, … in priority order (or 1, 2, … when nothing was retained). A
///   repaired entry therefore never sorts before a retained display, and sparse retained
///   orders (e.g. 1 and 3) are never filled in — inserting a new display cannot shift an
///   existing display's global zone range. Because valid unique persisted orders are
///   always kept (regardless of connectivity), later rearrangement of the connected-screen
///   order never renumbers an already-ordered set.
/// - Int.max overflow (a hand-edited config can persist order Int.max): if repaired
///   entries remain and the largest retained order leaves no room (`maxRetained >
///   Int.max - repairedCount`), the retained winners are REBASED to contiguous 1...N in
///   their existing sorted display order (sorted by persisted order, then label, then key
///   — the same order `ZoneNumbering` uses), which preserves their relative global
///   target/range ordering, and repaired entries append contiguously after N. This is the
///   one case where retained raw values change, and it is reachable only from an absurd
///   hand-edited config, never from anything this normalizer or the app persists.
/// - A fully valid, unique configuration — including one retaining order Int.max — is
///   returned UNCHANGED: the append arithmetic runs only when repairs are needed, so no
///   `Int.max + 1` is ever computed on a no-repair pass.
/// - Idempotent: a second pass over the normalized config changes nothing.
public enum ZoneOrderNormalizer {
    public static func normalizeOrders(in config: LineupConfig, connectedKeys: [String]) -> LineupConfig {
        // Priority-ordered list of (key, layout) over all saved screens.
        var priority: [(key: String, layout: ScreenLayout)] = []
        for key in connectedKeys where !priority.contains(where: { $0.key == key }) {
            if let layout = config.screens[key] { priority.append((key, layout)) }
        }
        let rest = config.screens
            .filter { entry in !priority.contains(where: { $0.key == entry.key }) }
            .map { (key: $0.key, layout: $0.value) }
            .sorted { a, b in
                if a.layout.label != b.layout.label { return a.layout.label < b.layout.label }
                return a.key < b.key
            }
        priority.append(contentsOf: rest)

        // Pass 1: retain valid, unique persisted orders (in priority order).
        var claimed = Set<Int>()
        var orders = [String: Int]()
        var repaired: [(key: String, layout: ScreenLayout)] = []
        for entry in priority {
            if let order = entry.layout.shortcutOrder, order > 0, !claimed.contains(order) {
                claimed.insert(order)
                orders[entry.key] = order
            } else {
                repaired.append(entry)
            }
        }

        // Overflow guard: when retained orders leave no appendable room (Int.max), rebase
        // the retained winners to 1...N in their existing sorted display order. That order
        // is exactly ZoneNumbering's sort, so their relative global ranges are unchanged.
        let maxRetained = orders.values.max()
        if let max = maxRetained, !repaired.isEmpty, max > Int.max - repaired.count {
            let winners = priority
                .filter { orders[$0.key] != nil }
                .sorted { a, b in
                    let oa = orders[a.key]!, ob = orders[b.key]!
                    if oa != ob { return oa < ob }
                    if a.layout.label != b.layout.label { return a.layout.label < b.layout.label }
                    return a.key < b.key
                }
            claimed.removeAll()
            orders.removeAll()
            for (index, entry) in winners.enumerated() {
                orders[entry.key] = index + 1
                claimed.insert(index + 1)
            }
        }

        // Pass 2: repaired entries append after every retained display, in priority order.
        // Only computed when there is something to repair: a fully valid configuration —
        // including one retaining order Int.max — must return unchanged with no arithmetic
        // that could overflow (`Int.max + 1`).
        if !repaired.isEmpty {
            // Safe by the guard above: after the rebase, max <= Int.max - repaired.count,
            // so appendFrom + the largest index never exceeds Int.max.
            let appendFrom = (orders.values.max() ?? 0) + 1
            for (index, entry) in repaired.enumerated() {
                orders[entry.key] = appendFrom + index
            }
        }

        // Apply the complete assignment map directly; every saved screen appears exactly
        // once in `priority`, so all other ScreenLayout data passes through untouched.
        var out = config
        for (key, order) in orders { out.screens[key]?.shortcutOrder = order }
        return out
    }
}
