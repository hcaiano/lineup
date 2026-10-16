# Zones

Zones snaps and resizes other apps' windows into zones the user draws per
display. Users snap with global shortcuts (halves, full screen, center,
numbered zones) or by holding a key while dragging a window over a zone. It is
on by default and starts with two vertical zones per display.

## Sub-features

- `zones-shortcut` moves the frontmost window with the window shortcuts
  (Left half `⌃⌥⇧⌘[`, Right half `⌃⌥⇧⌘]`, Full screen `⌃⌥⇧⌘↑`, Center `⌃⌥⇧⌘↓`,
  Restore `⌃⌥⇧⌘⌫`).
- `zones-drag` snaps a window into the zone under the pointer while Shift is held during a drag.
- `zones-overlay` shows the zones during a Shift-drag.
- `zones-editor` draws and saves a layout from `Edit Layout…`.
- `zones-numbered` assigns and uses a shortcut per numbered zone.
- `zones-disable` stops every shortcut and drag snap when the tool is off.

## How to get to it (user POV)

- Press a window shortcut while another app's window is frontmost.
- Hold Shift while dragging a window by its title bar over a zone.
- Settings: `Zones` in the sidebar, with `Edit Layout…`, `Drag to snap`,
  `Key to hold` and the shortcut buttons.

## Driving it with verify-lineup

Preconditions:

- Baseline from [README.md](./README.md). The Welcome window is dismissed.
- Zones is on, the layout is two vertical zones, and a TextEdit document is
  frontmost: `$V sh 'open -a TextEdit'`, `$V ax key escape` (closes the open
  panel), then `$V ax key cmd+n`.

- **Start frame.** Run `$V ax tree --app com.apple.TextEdit --scope windows --depth 0`.
  The frontmost `AXWindow` has a frame such as `242,115,603,505`.
- **Right half.** Run `$V ax key 'ctrl+opt+shift+cmd+]'`. The same window's
  frame becomes `960,30,960,1079`.
- **Left half.** Run `$V ax key 'ctrl+opt+shift+cmd+['`. The frame starts at `0,30`.
- **Shift-drag.** Drag the title bar into the left zone with Shift held. Run
  `$V ax drag --from 1200,40 --to 400,600 --mods shift --steps 30`, using the
  window's title-bar point from its frame. The frame becomes `0,30,960,1079`.
- **Settings.** Run `$V ax click role=AXStaticText desc=Zones` in Settings. The
  pane shows `Enable Zones` as `1`, `Drag snap bind` as `Shift`, and each
  window shortcut as a button such as `desc="Right half shortcut" value="⌃⌥⇧⌘]"`.
- **Disabled.** Turn off `Enable Zones` (`$V ax raise role=AXWindow title="Lineup Settings"`,
  then `$V ax click role=AXCheckBox desc="Enable Zones"`, which reads `0`). Raise
  the TextEdit window and press the Right half shortcut again. The frame does
  not change. Turn Zones back on afterwards.
- **Proof.** Record the shortcut and drag journey as `zones-snap`, and note
  each frame with `$V note`. The window frame is the side effect.

## Gotchas

- Shortcuts act on the frontmost window of another app. Close the Lineup panel
  first, or the key goes to the popover. When Settings was used last, bring the
  target forward first: `$V ax raise --app com.apple.TextEdit role=AXWindow title=Untitled`.
- In zsh, quote combos with `[` or `]`.
- The VM has one display, and its menu bar and Dock take part of the screen.
  Frames end at `y=1109`, not 1200, because the Dock reserves the rest.
- TextEdit opens a document picker on its first launch. Press Escape, then
  Command-N, as the preconditions do.
- A frame read right after the action can still show the old frame. Poll the
  tree or add `sleep 1`.
- Several displays, display reconnection and per-display layouts are
  host-only (see [README.md](./README.md#host-only-not-mapped-yet)).
