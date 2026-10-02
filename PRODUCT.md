# Product

## Register

product

## Users

Mac users who want their windows arranged without thinking about it. Two groups: Henrique (power
user, ultrawide monitor, keyboard-driven) and his non-technical friends (first macOS utility they
install by hand; they will not read documentation). Context: the app runs all day in the menu bar;
the only UI most users ever see is the on-screen layout editor (once) and the drag-snap highlight
(daily).

## Product Purpose

Lineup combines independently enabled tools for window layouts, app cycling, a Hyperkey, world
clocks and text capture. Zones snaps windows into per-screen zones the user draws themselves. It
replaces Magnet/Rectangle with something you can shape: recursive zone layouts per display, snapping by shift-drag or global
shortcuts. Success: a first-time user builds a multi-zone layout in the on-screen editor with no
instructions, and the app then disappears into muscle memory.

## Keyboard Remap

Keyboard Remap is an optional tool, off by default. Settings lets users select the built-in
keyboard or an external keyboard, add physical source and destination keys, and swap two keys.
The built-in keyboard preset swaps the ISO section key and the grave accent key. Shift follows
the destination key. Key labels show the symbols for the selected keyboard layout; changing
that layout changes labels, while saved rules keep the same physical HID usages.

Rules apply only to their selected keyboard. A disconnected keyboard retains its settings and
receives them again when it reconnects. External keyboards use hardware identifiers rather than
their product name alone. An ambiguous match waits for the user to choose a distinguishable
device.

Hyperkey and Keyboard Remap share one owner of keyboard maps. Disabling either tool removes
only its contribution. Conflicting or unreadable external maps block the affected operation and
show recovery in Settings, while other tools remain usable. Quitting releases Lineup's own
pairs. Recovery after an interruption preserves external changes made after Lineup applied its
rules. Keyboard Remap needs no event tap or additional permission.

## World Clock

World Clock is an optional menu-bar tool for checking colleagues' times and comparing nearby
hours. Its own status item opens a compact native panel, independently of the main Lineup icon.
The default is off. With no saved places, the panel shows Local and an add button.

Local follows the Mac's time zone and sits among the other clocks in chronological order, from
earlier to later local time. Sort by UTC offset at the selected instant, including daylight saving;
Local comes first among equal offsets, then cities retain their saved order. Unavailable zones go last.
Cities can be searched offline, renamed and removed inside the panel. Manual reordering only
changes the order of cities with equal offsets. One pinned place replaces the status icon with its name and live time; unpinning
restores the icon. The panel's ±24-hour time scroll changes every row to the same selected instant.
Reopening always returns to Now; the pinned status time remains real during simulation.

Follow the system appearance and hour format. Use aligned rows, readable numeric hours and one
blue for selection. Use a pin rather than a heart. Keep the time controls visible when a long list
scrolls. Show day changes explicitly. Solar estimates belong only to cities with coordinates;
the next event follows the simulated time. No calendar, location permission or network service.

## Menu bar organization

Menu Bar is an optional tool for macOS 27. It adds one arrow to the menu bar, and the arrow is the
boundary: icons the user Command-drags to its left hide when it collapses, and icons to its right
stay visible. Clicking the arrow shows the hidden icons in place, beside the arrow, and they hide
again after 10 seconds. Auto-hide waits while the pointer is on the menu bar or a hidden app's menu
or popover is open. The group starts collapsed at launch and after wake.

Lineup never moves the pointer or posts input events, including to arrange icons. Settings shows
the two groups read-only, with app icons and accessible names, without requiring Screen
Recording. macOS 27 hides whole apps, so an app with an icon on each side stays visible. Never
hide system items. Disabling the tool, quitting and crashes restore the flags changed by Lineup;
apps the user already hid in macOS settings stay hidden.

Hiding changes only the selected apps' native visibility flags. System controls, capture
indicators and Notification Center keep working. Executable-tracked trays such as Synergy use
the same group as their app. A recovery journal and separate process restore flags after a crash.
Settings has one show/hide action and one named row per app in each group. Access is a one-time
setup step; recovery appears only when needed. Secondary options stay in More options.

## Update Tracks

- Stable is the default and receives tested public releases.
- Nightly is a public opt-in in General settings. It receives newer builds that may be less
  reliable.
- Both tracks keep one app identity, config file, update feed and permission grants.
- Changing from a newer Nightly build to Stable stops Nightly updates. It waits for a newer Stable
  release; it does not install an older Stable build as a downgrade.

## Text Capture

Text Capture is an independent, opt-in tool. Invoke it from the menu bar, Settings, or an assigned
global shortcut; drag a region on one display; paste the copied plain text in another app. Escape
cancels selection. The selection overlay must never appear in the captured image.

Recognition runs locally using Portuguese and English support in macOS. A brief visible and
VoiceOver-announced notice confirms a copy. Empty results, capture or recognition failures, and cancellation preserve
the clipboard. Screen Recording is requested only on capture, with recovery in Settings. Display
changes and tool shutdown invalidate pending results. There is no capture history, automatic
paste, translation, or network processing.

## Brand Personality

Native, precise, calm. One fixed brand blue (#2F6BFF, `Brand.blue` in
`Sources/lineup/App/Brand.swift`) carries selection and controls; everything else defers to macOS
conventions (system fonts, vibrancy, standard controls). Feature artwork uses one color per tool
within the shared [enamel icon family](Design/FeatureIcons/README.md). The app should feel like
Apple shipped it.

Lineup currently reuses the selected Zones artwork as its application icon and the existing
pane-grid silhouette in the menu bar. New logo work is deferred. The source and export contract
live in the [app icon standard](Design/AppIcon/README.md). A future layered replacement follows
Apple's native Icon Composer workflow.

In Settings, enabled features retain their artwork's color. Disabled features are fully grayscale
in both the sidebar and pane header, using the same `ToolIcon` renderer. The treatment follows
the persisted enabled flag; a tool awaiting permission retains its enabled appearance.

## Anti-references

- Amateur floating chrome: bare SF Symbol buttons in white boxes, mismatched sizes, arbitrary
  placement. The editor overlay must read as one designed surface, not controls sprinkled on glass.
- Electron-app density and web-style cards. No faux-material design on macOS.
- Red as an accent anywhere (explicit user rule). Warnings are orange; everything else is the blue.
- "AI-made" tells in copy or UI: em dashes, generic icon-plus-label grids, hedging microcopy.

## Design Principles

1. **The screen is the canvas.** The editor draws on the user's actual display; chrome floats only
   where it must, centered and reachable (a 49" ultrawide is the stress test).
2. **Show the result, not the words.** Split/merge controls depict the shape they produce; labels
   support, never substitute. Non-native English speakers must understand them.
3. **Numbers users can act on.** Pixel readouts, placed where the eye already is; no unit soup.
4. **Defer to the platform.** AppKit controls, system behaviors, native About/Settings idioms.
5. **One blue for controls.** Selection, highlight and control accents use `Brand.blue`.
   Feature artwork uses its assigned hue, with a shared composition and material.

## Accessibility & Inclusion

Every control carries an accessibility label (SF Symbol `accessibilityDescription`, button titles).
Hover-revealed controls are also click-pinned so trackpad/switch users get a stable target. Esc
always cancels; Return always confirms. Color is never the only signal (active zones also get
thicker strokes). No motion beyond system defaults, so no reduced-motion variants are required.

## Keep Awake

Keep Awake is an independent, opt-in tool for timed idle-sleep prevention. Users start and stop
sessions from the menu bar or Settings. The active menu-bar label and countdown show the current
state. Keeping the display on is a separate preference, off by default.

Sessions last 15, 30, 60, or 120 minutes. Changing duration restarts the timer; changing the display
option preserves its deadline. Explicit sleep ends the session. Sessions never resume at wake or
app launch. The tool does not change permanent power settings, screen locking, or closed-lid behavior.
