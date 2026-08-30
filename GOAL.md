# Lineup — Production-Readiness & Design Goal

> [!NOTE]
> This is the historical brief for the Lineup 2.0 redesign. Use [PRODUCT.md](PRODUCT.md) and the
> current code as the source of truth for new work.
>
> The Tiles phase in `docs/tiles-implementation-plan.md` supersedes only the old capability
> non-goals below. It adds automatic tiling, four Lineup workspaces, and stacked window cycling
> while preserving Zones as the only layout editor.
**One-liner:** Lineup is a tiny, native macOS menu-bar window manager that snaps windows into
per-screen, user-defined zones — built for ultrawide monitors (Samsung G9) but useful to anyone.
This phase makes it **beautiful, minimal, discoverable, and production-ready** for a public GitHub
release that non-technical friends can install and "get" in under a minute.

> Give this prompt to Claude **and** Codex. Claude implements; Codex reviews adversarially. Both
> agents share this goal and must keep the design **consistent**. Iterate until it's genuinely
> polished — not "works," but "feels like a finished product."

## The problem with the current build (feedback to fix)

1. **Layout editing isn't where users look for it.** People open the on-screen **overlay** expecting
   to shape their layout there, and there's no way to do it — editing is buried in a detailed
   Settings window. The overlay should be the **primary, direct-manipulation editor**.
2. **Too many default shortcuts.** Defaulting Hyper+1…9 to zones collides with shortcuts people
   already use. Ship **minimal defaults**; leave zone shortcuts **empty**.
3. **Cluttered menu-bar dropdown.** It shows things that don't need to be there ("Accessibility:
   granted", the full shortcut list, the config path). Show **only what's needed or actionable**.
4. **Menu-bar icon is a placeholder square**, not a logo. Needs a real, crisp, monochrome mark.
5. **Color is red.** Switch the accent to **blue** everywhere (overlays, highlights, selection),
   and make the app icon **blue** to match.

## Target design

### Interaction model
- **On-screen Layout Editor (the overlay) is the main way to build a layout.** Full-screen, over
  the actual display. Each zone shows, on hover, inline controls to split it side-by-side, split it
  top/bottom, and merge/delete. Dividers drag to resize. Done/Esc to finish. WYSIWYG,
  PowerToys/FancyZones-style. This replaces the old "drag two red lines" overlay as the primary tool.
- **Split direction must be VISUAL, not worded.** Don't rely on the English words "columns/rows" —
  non-native speakers confuse them. Use icons that show the *result*: a button whose glyph is a box
  split by a **vertical** line (→ two side-by-side) and one split by a **horizontal** line (→ two
  stacked). Optionally show a faint live preview of where the new divider lands on hover.
- **KNOWN BUG this must fix (root cause of the confusion):** today the overlay and the Settings
  editor are *different code paths*. The overlay only renders the root split's direct children, so a
  nested layout (e.g. `left column + right-region-split-in-two` = 3 zones) shows as **1 divider / 2
  regions** in the overlay while Settings correctly shows 3. One editor over the real per-screen
  layout eliminates this entirely.
- **Settings window stays** but becomes secondary: Shortcuts (recorder) + General. The Layout tab can
  remain as an alternate/advanced view or be removed if the overlay fully covers it — agree which.
- **Per-screen layouts** (already built) stay: each display has its own layout; the editor edits the
  display it's shown on, with an obvious way to pick another display.

### Defaults & shortcuts
- **Quick actions** (Hyper + ←/→/↑/↓/[/]) keep sensible defaults — they're the Magnet muscle-memory
  this replaces and rarely collide.
- **Zone shortcuts (Zone 1…N) default to UNASSIGNED.** Users opt in via the recorder.
- The Shortcuts UI should make "unassigned" obviously fine, not an error.

### Menu-bar dropdown (minimal)
Show, in order: **Edit Layout…**, **Settings…**, separator, **Shift-drag to snap** (toggle),
**Launch at login** (toggle), separator, **Quit**. Surface a warning row + action **only when
something is wrong** (Accessibility not granted → Grant; hotkeys failed → Retry; config error →
Reset). Hide "granted/OK" states and the config path and the shortcut list.

### Visual identity
- **Accent = blue.** Replace red in the alignment overlay; unify the drag-snap highlight, editor
  selection, and zone numbering on one blue. Pick one accent (lean on `controlAccentColor` where it
  should follow the system, a fixed brand blue where it shouldn't) and use it consistently.
- **Menu-bar logo:** a real monochrome **template** image (system-tinted, works in light/dark, crisp
  at ~18px) — a simple, recognizable "lineup/zones" mark, not the ▦ glyph.
- **App icon:** keep the gradient-glass squircle but shift it **blue** (and align the mark with the
  menu-bar logo so they read as the same brand).

### Production polish
- Clean, native-feeling AppKit (spacing, alignment, hover states, empty states).
- README rewritten for a public release: what it is, 60-second install, screenshots/GIF, the editor
  + shortcuts + per-screen story, the seam-alignment use case, known limitations, license.
- Publish the project under the **Apache License 2.0**.
- No rough edges: no debug strings, no dead UI, accessible labels, sane window sizes.

## Non-goals (this phase)
- No new window-management capabilities beyond what exists (zones, shift-drag, cycling, recorder).
- No editable cycle-step list. No multi-level grid beyond the recursive split tree already built.

## Definition of done
- Opening the **overlay** lets a first-time user build a multi-zone layout with no instructions.
- Menu-bar dropdown shows ≤ ~6 rows in the healthy state.
- Zero default zone shortcuts; quick-action defaults present and non-colliding.
- One consistent **blue** accent across overlay, highlight, editor, icon; menu-bar logo is a real mark.
- README + LICENSE ready; `swift run lineup-tests` green; release build + signed bundle clean.
- Codex has reviewed and accepted every change; the design reads as **one coherent product**.

## Process
- Pair via herdr (`/herdr-pair`). Claude drives implementation phase-by-phase; Codex reviews each.
- Keep the **pure core tested**; keep AppKit changes reviewed for the data-safety + read-only
  contracts already established. Update `task_plan.md` / `progress.md` as we go.
- Iterate until both agents agree it's production-ready — "perfect," per Henrique.
