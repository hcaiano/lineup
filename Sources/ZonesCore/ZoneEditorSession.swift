import Foundation

/// The layout editor's transaction state, pure and deterministic (no AppKit).
///
/// A session couples one CANDIDATE base config (the prepared/normalized config the editor
/// opened from) with the connected screens and the user's per-display draft trees. Its
/// invariants make the editor's display and Save agree:
///
/// - `numbering` is always built from `proposal`, so the (global number, display, local
///   zone) tuples the canvases show are by construction the tuples Save would commit.
/// - Drafts are keyed by the screen's EXACT key and are NEVER migrated across keys: an
///   ambiguous identity (lookalike displays sharing a legacy alias) must never inherit
///   another display's draft.
/// - Drafts survive `rebase` even when their screen is no longer connected, so a display
///   disconnect cannot silently destroy the user's work; the draft reenters the proposal
///   (and the numbering) until the draft is cleared or the editor closes without saving.
/// - The session is candidate-only state: it never persists anything, and `proposal`
///   equality with the committed config is the caller's no-write signal.
public struct ZoneEditorSession {
    /// The candidate base config the session was opened from (or last rebased to).
    public private(set) var base: LineupConfig
    /// The connected screens at open/rebase time, in the caller's display order.
    public private(set) var screens: [ScreenInfo]
    /// Draft trees by exact screen key, with the `ScreenInfo` captured when the draft was
    /// set (so a disconnected draft can still be materialized into the proposal).
    private var drafts: [String: (info: ScreenInfo, node: Node)] = [:]

    public init(base: LineupConfig, screens: [ScreenInfo]) {
        self.base = base
        self.screens = screens
    }

    /// Record the user's draft tree for a screen. Returns whether the draft map changed.
    @discardableResult
    public mutating func setDraft(_ node: Node, for info: ScreenInfo) -> Bool {
        if let existing = drafts[info.key], existing.node == node { return false }
        drafts[info.key] = (info, node)
        return true
    }

    /// Drop a screen's draft (its entry returns to the base layout).
    public mutating func clearDraft(for key: String) {
        drafts[key] = nil
    }

    /// The user's draft tree for a screen key, if one was set.
    public func draft(for key: String) -> Node? {
        drafts[key]?.node
    }

    /// The connected keys at open/rebase time, in display order (unique).
    public var connectedKeys: [String] {
        screens.map(\.key)
    }

    /// Rebase onto a fresh candidate base and the CURRENT connected screens while keeping
    /// every draft by its exact key. Returns whether the topology actually changed (base
    /// config or the ordered connected key set), so the caller can surface a refresh only
    /// when the user needs to review new numbering.
    @discardableResult
    public mutating func rebase(base newBase: LineupConfig, screens newScreens: [ScreenInfo]) -> Bool {
        let changed = base != newBase || screens.map(\.key) != newScreens.map(\.key)
        base = newBase
        screens = newScreens
        return changed
    }

    /// The COMPLETE config Save would persist: the base candidate plus every draft. Entries
    /// that exist keep their metadata and order (only the layout is replaced); a draft with
    /// no saved entry is materialized through `setting(layout:for:now:)` with `now: nil`,
    /// which cannot destroy metadata because it only runs when nothing exists to preserve.
    /// Orders are then normalized against the CURRENT connected keys — a no-op for an
    /// already-normalized base, and the exact operation the runtime write path performs.
    public var proposal: LineupConfig {
        var out = base
        for (key, draft) in drafts {
            if out.screens[key] != nil {
                out.screens[key]?.layout = draft.node
            } else {
                out = out.setting(layout: draft.node, for: draft.info, now: nil)
            }
        }
        return ZoneOrderNormalizer.normalizeOrders(in: out, connectedKeys: connectedKeys)
    }

    /// The displayed global numbering: derived from `proposal`, so what the canvases show
    /// is what Save would commit. Disconnected saved displays keep their reserved ranges.
    public var numbering: ZoneNumbering {
        ZoneNumbering(config: proposal)
    }
}
