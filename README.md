<div align="center">

<img src="Icon/icon-1024.png" width="128" alt="Lineup icon">

# Lineup

**Snap your windows into place on any Mac.**

</div>

---

Lineup keeps your windows where you want them. You draw a few zones on your screen, then drop any
window into one with a quick drag or a keyboard shortcut. Every monitor remembers its own setup.

- **Design your own zones.** Two columns, three columns, a big main area with a stack beside it.
  Set it up to match the way you work.
- **Every screen remembers its layout.** Your laptop and your desk monitor can be arranged
  differently, and Lineup switches between them on its own.
- **It stays out of the way.** Lineup sits in your menu bar and barely uses any power while you work.

## Install

1. Download the **Lineup DMG** (a file like `Lineup-1.4.0.dmg`) from the
   [Releases page](https://github.com/hcaiano/lineup/releases/latest).
2. Open it and drag **Lineup** into your **Applications** folder.
3. The first time you open Lineup, macOS stops it because it doesn't recognize the developer yet.
   To let it through (you only do this once):
   - Double-click **Lineup**. You'll see a warning. Click **Done**.
   - Open **System Settings**, go to **Privacy & Security**, and scroll down to **Security**.
   - Click **Open Anyway** next to the message about Lineup, then confirm with your fingerprint or
     password.
   - The warning appears one more time. Click **Open**, and Lineup starts.
4. Lineup needs your permission to move windows. When it asks, open **System Settings → Privacy &
   Security → Accessibility** and switch **Lineup** on. If you already use Magnet or Rectangle, turn
   it off so the shortcuts don't fight each other.

## Design your layout

Click the Lineup icon in your menu bar and choose **Edit Layout**. Your screen dims and your zones
appear right where they'll live.

<div align="center">
<img src="docs/editor.png" width="900" alt="The Lineup layout editor: three numbered zones over a screen, with buttons on the hovered zone to split it side by side, split it top and bottom, or merge it.">
</div>

- **Hover over a zone** to see its buttons. Split it side by side, split it top and bottom, or merge
  it back together. The buttons show you the shape you'll get, so there's nothing to read.
- **Drag a divider handle** to resize. Every zone shows its size in pixels and updates live while
  you drag. Near a common spot — the middle, a third, a quarter, or where two zones become equal —
  the divider gently locks on and shows a badge (½, ⅓, =). Keep dragging and it lets go, so any
  custom size is still yours. Split as many times as you like.
- Using more than one monitor? The editor appears on each screen with that screen's own layout.
- Click **Save** when it looks right, or **Cancel** to throw the changes away.

Each zone has a number. Those numbers are how the keyboard shortcuts find them.

## Move windows around

There are two ways to drop a window into a zone.

**Drag and drop.** Hold **Shift** while you drag a window. The zone under your cursor lights up. Let
go to drop the window in. You can turn this off in Settings.

Want two apps stacked in one zone? While shift-dragging, aim near the zone's **top or bottom
edge** and the highlight switches to that half. Drop, then place the second app in the other half
the same way. The highlight always shows exactly where the window will land.

**Keyboard shortcuts.** Lineup comes with a few ready to go. They use a "Hyper" key, which is
Control, Option, Shift and Command pressed together. Pressing four keys at once is a stretch, so
most people turn a single key (often Caps Lock) into Hyper. Free apps like
[Raycast](https://www.raycast.com) or [Karabiner](https://karabiner-elements.pqrs.org) set this up
in a minute. If you'd rather not bother, the drag-and-drop above needs no setup at all.

| Press | What happens |
| --- | --- |
| Hyper + Left or Right | Move to that side. Press again to cycle through half, a third, two thirds. |
| Hyper + Up | Fill the screen |
| Hyper + Down | Center the window. Press again to cycle the centered widths. |
| Hyper + [ or ] | Snap to the left or right half |

The shortcuts that snap to a numbered zone start empty, so they won't clash with anything you
already use. Add the ones you want in Settings.

## Settings

Open **Settings** from the menu bar.

- **Shortcuts** lets you set or change any shortcut. Click **Record** and press the keys you want.
- **General** has the drag-and-drop switch, an option to start Lineup when your Mac turns on, and
  your permission status.

## Good to know

- Lineup moves and resizes windows the same way you would by hand. A few apps that insist on a fixed
  size (like Terminal) might not land exactly on the line. Most apps fit perfectly.
- Lineup only touches the monitors you have plugged in right now. Unplug one and its layout waits
  safely until you connect it again.

## License

Lineup is free and open source under the [MIT license](LICENSE).
