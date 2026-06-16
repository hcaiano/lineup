<div align="center">

<img src="Icon/icon-1024.png" width="128" alt="Lineup icon">

# Lineup

**Draw your own window zones on macOS.**

Free, menu-bar window management built around the custom layouts you design yourself.

[![Latest release](https://img.shields.io/github/v/release/hcaiano/lineup?label=download&color=2F6BFF)](https://github.com/hcaiano/lineup/releases/latest)
&nbsp;[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-2F6BFF)](https://github.com/hcaiano/lineup/releases/latest)
&nbsp;[![MIT license](https://img.shields.io/github/license/hcaiano/lineup?color=2F6BFF)](LICENSE)

</div>

---

Lineup lets you draw the zones you actually use: a wide main column with a stack beside it, three
uneven columns, a grid, whatever fits your work. Drop any window into one with a quick drag or a
keyboard shortcut, and every monitor remembers its own setup.

<div align="center">
<img src="docs/editor.png" width="900" alt="The Lineup layout editor: numbered zones drawn over a screen, with controls on a zone to split it side by side, split it top and bottom, or merge it.">
</div>

- **Design your own zones.** Split a screen into columns, rows, or nested areas and size each one
  exactly. Not just halves and thirds.
- **Every screen remembers its layout.** Your laptop and your desk monitor each stay arranged the
  way they should be, and Lineup switches between them on its own.
- **It stays out of the way.** Lineup lives in your menu bar and barely uses any power.

### A few setups it's good for

- **Ultrawide:** a wide main column for your editor, a column of notes, and chat tucked on the side.
- **Laptop plus monitor:** a different layout on each, switched automatically as you dock and undock.
- **Research or writing:** repeatable zones you drop the same windows into every day.

## Install

1. Download the `.dmg` from the [Releases page](https://github.com/hcaiano/lineup/releases/latest).
2. Open it and drag **Lineup** into your **Applications** folder.
3. The first time you open it, macOS checks the app before letting it run. If it asks:
   - Double-click **Lineup**, and if you see a warning, click **Done**.
   - Open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway**
     next to the Lineup message, and confirm with your fingerprint or password.
   - The prompt appears once more. Click **Open**, and Lineup starts.
4. Lineup needs permission to move windows. When it asks, open **System Settings → Privacy &
   Security → Accessibility** and switch **Lineup** on. If you already use another window manager,
   turn its shortcuts off so they don't fight with Lineup's.

## Design your layout

Click the Lineup icon in your menu bar and choose **Edit Layout**. Your screen dims and your zones
appear right where they'll live.

- **Hover over a zone** to see its buttons. Split it side by side, split it top and bottom, or merge
  it back together. The buttons show the shape you'll get, so there's nothing to read.
- **Drag a divider handle** to resize. Every zone shows its size in pixels, live, as you drag. Near a
  common spot (the middle, a third, a quarter, or where two zones become equal) the divider gently
  locks on and shows a badge (½, ⅓, =). Keep dragging and it lets go, so any custom size is still
  yours. Split as many times as you like.
- Using more than one monitor? The editor opens on each screen with that screen's own layout.
- Click **Save** when it looks right, or **Cancel** to throw the changes away.

Each zone has a number. Those numbers are how the keyboard shortcuts find them.

## Move windows around

There are two ways to drop a window into a zone.

**Drag and drop.** Hold **Shift** while you drag a window. The zone under your cursor lights up. Let
go to drop the window in. You can turn this off in Settings.

Want two apps sharing one zone? While shift-dragging, aim near any **edge** of the zone and the
highlight switches to that half: top or bottom edge for stacked, left or right edge for side by
side. Aim near a **corner** and you get that quarter, so four apps fit in one zone. The highlight
always shows exactly where the window will land.

Changed your mind? Just drag the window out again. The moment it leaves the zone it returns to the
size it had before, right under your cursor.

**Keyboard shortcuts.** Lineup comes with a few ready to go. They use a "Hyper" key, which is
Control, Option, Shift and Command pressed together. Pressing four keys at once is a stretch, so most
people turn a single key (often Caps Lock) into Hyper. Free apps like
[Raycast](https://www.raycast.com) or [Karabiner](https://karabiner-elements.pqrs.org) set this up in
a minute. If you'd rather not bother, the drag-and-drop above needs no setup at all.

| Press | What happens |
| --- | --- |
| Hyper + Left or Right | Move to that side. Press again to cycle through half, a third, two thirds. |
| Hyper + Up | Fill the screen |
| Hyper + Down | Center the window. Press again to cycle the centered widths. |
| Hyper + [ or ] | Snap to the left or right half |
| Hyper + Delete | Put the window back where it was before you snapped it |

The shortcuts that snap to a numbered zone start empty, so they won't clash with anything you already
use. Add the ones you want in Settings.

## Settings

Open **Settings** from the menu bar.

- **Shortcuts** lets you set or change any shortcut. Click **Record** and press the keys you want.
- **General** has the drag-and-drop switch, an option to start Lineup when your Mac turns on, and your
  permission status.

## Good to know

- Lineup needs Accessibility permission to move windows. You grant it once, in System Settings.
- It moves and resizes windows the same way you would by hand. A few apps insist on a fixed or
  minimum size (like Terminal); Lineup centers those neatly in the zone instead of forcing them.
- It only touches the monitors you have plugged in right now. Unplug one and its layout waits safely
  until you connect it again.

## Support

Lineup is free, and it stays free. If it earns a spot in your daily setup and you'd like to chip in,
you can [buy me a coffee](https://buymeacoffee.com/caiano). It keeps the updates coming.

## License

Lineup is free and open source under the [MIT license](LICENSE).
