# Product

## Register

product

## Users

Mac users who want their windows arranged without thinking about it. Two groups: Henrique (power
user, ultrawide monitor, keyboard-driven) and his non-technical friends (first macOS utility they
install by hand; they will not read documentation). The app runs all day in the menu bar, with
everyday controls in its panel. Zones users build their layout once in the on-screen editor and
see the drag-snap highlight during daily use.

## Product Purpose

Lineup combines independently enabled tools for window layouts, app cycling, a Hyperkey, world
clocks, sleep prevention, text capture, menu bar organization and display controls. Zones snaps
windows into per-screen zones the user draws themselves. It
replaces Magnet/Rectangle with something you can shape: recursive zone layouts per display, snapping by shift-drag or global
shortcuts. Success: a first-time user builds a multi-zone layout in the on-screen editor with no
instructions, and the app then disappears into muscle memory.

## Menu-bar controls

Clicking the Lineup icon opens one compact native popover with icon tabs for enabled quick controls:
Display Control, Keep Awake, World Clock and Text Capture, in that order.
Each tab shows that tool's controls directly, under the tool's name. Display Control has brightness
and volume sliders; Keep Awake has session controls; World Clock has its complete clock, place
search and time scroll. Text Capture has its capture button and shortcut, or a way to add one.
Starting a capture closes the panel first. Zones, Cycler, Hyperkey, Keyboard Remap, Menu Bar and
Scroll remain in Settings and keep running independently of the panel. With no quick controls
enabled, the panel offers Settings without claiming that every tool is off.
Settings and app actions remain in the top row. Right-clicking the icon opens a compact native menu
with Settings, Check for Updates, About and Quit. It also shows actionable problems from any
running tool. Tool controls, healthy status rows and the Open at Login preference do not appear in
that menu or the panel's app actions; Open at Login remains in General settings.

The panel shows only what the person needs in the moment. Preferences, explanations and
compatibility details belong in Settings. The panel hugs its content, so its height follows the
selected tab.

The panel has no arrow above it. macOS draws its border and material. Native segmented tabs, sliders and toggles
follow the system accent and appearance, including Liquid Glass on macOS 26 and later. Respect
Light/Dark Mode, the person's Liquid Glass preference, Reduce Transparency and Increase Contrast. Earlier
macOS versions retain their native AppKit appearance. Do not paint an extra panel background or
force a transparency level.

The first opening selects Display Control when enabled, otherwise the first available quick control.
Reopening remembers the last selected tab for the current app session. Opening a quick control
from Settings selects its tab. Disabling the selected tool removes its tab and selects the first
remaining quick control. Use Command-1 through Command-9 to select the first nine tabs, or Control-Tab and
Control-Shift-Tab to move forward and backward.

Closing the panel leaves Keep Awake sessions and enabled tools running. Content scrolls within
the available display height. Escape closes the panel. In World Clock, it first leaves place
search or editing; another Escape closes the panel. Clicking outside or clicking the Lineup icon
again also closes it.

World Clock can additionally show its own menu-bar icon or a pinned place's live time. New clock
configurations use the Lineup panel alone; existing saved configurations keep the separate item
until the user changes that preference. Showing or hiding this extra item never changes tool
enablement, saved places or the pin.

Explicitly reopening an already-running Lineup from Raycast, Spotlight, Finder or the Dock opens
Settings, whether the main menu-bar icon is visible or hidden. If the Settings window already
exists, Lineup brings that same window to the front.

## Display control

Display Control is an independent tool, off by default. Its controls in the Lineup popover and
Settings show each connected display, its hardware controls and confirmed brightness or speaker volume.
Native Apple brightness and external DDC/CI are supported when the current connection exposes
them. The popover shows only supported controls; a display with none says so and offers detection
again. Settings shows every control with the reason one is unsupported. An unreadable value has no
slider or invented level. Retry detection after enabling DDC/CI on a monitor or changing its cable
or dock. Keyboard preferences live in Settings; destination pickers and per-display exclusions
appear only while their key group is on.

Brightness and volume keys are separate, opt-in choices. Both default to the display under the
pointer; each can instead use one explicitly selected display. Per-display preferences can
exclude either key group. A disconnected selected display waits without redirecting keys to
another display. A held key keeps its initial display even if the pointer moves. Option-Shift
with a brightness or volume key makes a fine adjustment. Other modifier combinations and
Settings shortcut recording retain their existing behavior.

**Sync brightness across displays** is off by default and affects only brightness keys. The
destination picker becomes the reference display, still under the pointer by default. Its level
sets the shared adjustment for compatible displays included in the brightness key group. A held
press keeps the initial reference and participating displays. Connection or routing changes
cancel its remaining commands. A disconnected selected reference blocks the group.

With sync on, each compatible display has **Minimum brightness** and **Maximum brightness**,
defaulting to 0% and 100%. The maximum ranges from 5% to 100% and must exceed the minimum.
Shared levels scale across this range: a 10% minimum and 80% maximum send 45% at a shared 50%.
Users match their displays by eye; Lineup does not measure apparent brightness. Changing either
bound writes only the preference and applies on the next brightness key press. Manual sliders
remain individual, single-display brightness keys ignore calibration, and volume keys remain
independent.

**Black screen below minimum** is off by default and appears while brightness keys are enabled.
Pressing Brightness Down again at minimum covers the display with black while keeping it powered
on. With sync enabled, this happens at shared 0% for the participating displays; their configured
hardware minimums remain unchanged. Brightness Up clears the cover and makes the normal upward
adjustment. The display's **Restore** button clears only its cover; Escape clears all covers.
Neither recovery control raises hardware brightness. The panel and Settings show **Black screen**
separately from confirmed hardware percentages. This state is never saved.

Confirmed key adjustments use the classic macOS brightness or volume overlay on the affected
display. An unavailable system interface or a failure uses Lineup's feedback with native material.
Pending changes never present a requested level as confirmed.
Mute sets the monitor's volume to zero and restores a level observed during that connection;
if no previous level is known, Volume Up unmutes it.

Manual controls need no keyboard permission. Only optional media keys use Accessibility, through
the shared permission and media-key services. Denial or revocation leaves manual controls working.
Saved data contains routing, sync, calibration and black-screen preferences, never current brightness or
volume levels. Startup and detection only read current levels. Sleep, display changes, disabling
and quitting cancel pending writes and clear black covers. Preference changes, lost input
permission, shortcut recording, Secure Input and a failed brightness reading also clear them, so a
display Lineup can no longer read is never left hidden. A cover is refused if its
emergency Escape shortcut cannot be registered. Wake and reconnection detect capabilities again.
The optional black cover does not change gamma, display power or arrangement. Gradual software
dimming, resolution changes, HDR and virtual-display controls are outside this tool's current scope.

## Hyperkey

Secure Input temporarily pauses Hyperkey shortcuts. If Caps Lock is already remapped for
Hyperkey, that remap stays in place during the pause so the key cannot turn on native Caps Lock.
Shortcuts resume automatically when Secure Input ends. Disabling Hyperkey, quitting Lineup or
choosing a different trigger releases Lineup's Caps Lock remap.

A blocked Hyperkey shows a click-through notice at the top right of the selected display for
four seconds, following the system's light or dark appearance. A new attempt with a mapped Caps
Lock or function-key trigger shows it again. Repeated attempts while it is visible do not extend
its deadline. The reminder needs an available global shortcut; modifier-only triggers cannot
show it during Secure Input. The menu warning and
Hyperkey Settings retain the status and recovery instructions. For Secure Input, a possible app
name is a hint, not confirmed attribution; an unavailable hint says "App unknown." Leave password
fields first. If the pause persists, quit and reopen the suspected app or the app holding Secure
Input. Hyperkey resumes automatically.

## Keyboard Remap

Keyboard Remap is an optional tool, off by default. Settings lets users select the built-in
keyboard or an external keyboard, add physical source and destination keys, and swap two keys.
The built-in keyboard preset appears below the keyboard selection and swaps the ISO section key
and the grave accent key. Shift follows the destination key. Known keys show symbols and physical
names without HID codes. The collapsed Key labels option selects the layout used for those
symbols; it changes labels without changing the macOS input layout or saved physical keys.

Rules apply only to their selected keyboard. A disconnected keyboard retains its settings and
receives them again when it reconnects. Settings shows its disconnected status beside the
keyboard selection. External keyboards use hardware identifiers rather than
their product name alone. An ambiguous match waits for the user to choose a distinguishable
device.

Hyperkey and Keyboard Remap share one owner of keyboard maps. Disabling either tool removes
only its contribution. Conflicting or unreadable external maps block the affected operation and
show recovery in Settings, while other tools remain usable. Quitting releases Lineup's own
pairs. Recovery after an interruption preserves external changes made after Lineup applied its
rules. Keyboard Remap needs no event tap or additional permission.

## World Clock

World Clock is an optional menu-bar tool for checking colleagues' times and comparing nearby
hours. Its tab in the Lineup panel shows all saved places, place management and time comparison
directly. An optional separate status item opens that same clock view,
independently of the main Lineup icon's visibility preference. The tool starts off. With no saved
places, the clock shows Local and an add button.

Local follows the Mac's time zone and sits among the other clocks in chronological order, from
earlier to later local time. Sort by UTC offset at the selected instant, including daylight saving;
Local comes first among equal offsets, then cities retain their saved order. Unavailable zones go last.
Cities can be searched offline, renamed and removed inside the complete view; search results
show each place's current time. Manual reordering only changes the order of cities with equal
offsets. With the separate menu-bar item enabled, one pinned place replaces its icon with its name
and live time; unpinning restores the icon. Choose the pinned place in Settings, from a clock
row's context menu, or in edit mode. Pin controls appear only while the separate item is on.
The ±24-hour time scroll changes every row to the same selected instant. Reopening the clock
always returns to Now; the pinned status time remains real during simulation.

Follow the system appearance and hour format. Use aligned rows, readable numeric hours and one
blue for selection. Use a pin rather than a heart. Keep the time controls visible when a long list
scrolls. Show day changes explicitly. Cities with coordinates show a sun or moon for day or night;
the estimated next sunrise or sunset appears on hover and follows the simulated time. No calendar,
location permission or network service.

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
- Update notes explain new features and fixes in readable headings and lists with clickable
  links. Nightly notes include changes since the last Stable release, so users who skip builds
  can see the complete upgrade.

## Text Capture

Text Capture is an independent, opt-in tool. Invoke it from the menu bar, Settings, or an assigned
global shortcut; drag a region on one display; paste the copied plain text in another app. Escape
cancels selection. The selection overlay must never appear in the captured image.

Recognition runs locally using Portuguese and English support in macOS. A brief visible and
VoiceOver-announced notice confirms a copy. Empty results, capture or recognition failures, and cancellation preserve
the clipboard. Screen Recording is requested only on capture, with recovery in Settings. Display
changes and tool shutdown invalidate pending results. There is no capture history, automatic
paste, translation, or network processing.

## Scroll

Scroll is an independent, opt-in tool for people who want a different direction on each device,
most often a traditional mouse wheel with a natural trackpad. Settings reverses
the mouse and the trackpad separately; vertical and horizontal choices apply to each reversed
device. The defaults reverse vertical mouse scrolling and keep the trackpad unchanged; horizontal
reversal starts off because apps turn horizontal scrolling into page navigation. Settings
explains the result relative to the current macOS Natural scrolling preference, which Lineup only
reads.

Changes apply to the next scroll. With Constant scrolling off, reversal changes only the sign of each scroll: speed and inertia
stay as macOS delivers them, gesture events such as zoom, rotation and space swipes are never
touched, and no event is added or removed. A gesture keeps one device through its inertia.
Scrolling that cannot be attributed to a mouse or trackpad, including input posted by other apps,
keeps the macOS direction. Missing Accessibility leaves scrolling unchanged
and shows recovery in Settings. Disabling the tool or quitting ends interception immediately.
**Constant scrolling** is an optional mouse-wheel setting, off by default. It removes acceleration
from vertical, non-continuous wheel events by assigning the same number of lines to each event.
**Lines per step** ranges from 1 to 10 and starts at 3. It works independently of direction reversal;
when both are selected, the constant step follows the chosen direction. Horizontal scrolling,
continuous Magic Mouse input, trackpads and gesture momentum retain their existing behavior.
Unknown devices and app-posted events remain unchanged. No events are synthesized or delayed.
Smoothing, button remapping and per-app rules are out of scope.

## Brand Personality

Native, precise, calm. One fixed brand blue (#2F6BFF, `Brand.blue` in
`Sources/lineup/App/Brand.swift`) carries selection and controls in Settings and the layout editor.
The menu-bar popover and its controls inherit the system accent and appearance. Zones' on-screen
handle, Share zone targets and window suggestions follow the system appearance with neutral system
colors and the system accent; only snap previews keep the brand blue. Other styling
defers to macOS conventions (system fonts, vibrancy, standard controls). Feature artwork uses one color per tool
within the shared [cheerful icon family](Design/FeatureIcons/README.md), with clean luminous hues, gentle color
gradients, bold planar symbols and uniform feature exports without outer padding. The app should feel like
Apple shipped it.

Lineup keeps the selected three-pane symbol for its application icon and the existing
pane-grid silhouette in the menu bar. The app icon has its own native macOS Icon Composer
source and platform framing, separate from feature imagesets. The source and export contract
live in the [app icon standard](Design/AppIcon/README.md).

In Settings, enabled features retain their artwork's color. Disabled features are fully grayscale
in both the sidebar and pane header, using the same `ToolIcon` renderer. The treatment follows
the persisted enabled flag; a tool awaiting permission retains its enabled appearance.

## Anti-references

- Amateur floating chrome: bare SF Symbol buttons in white boxes, mismatched sizes, arbitrary
  placement. The editor overlay must read as one designed surface, not controls sprinkled on glass.
- Electron-app density and web-style cards. No faux-material design on macOS.
- Red as a custom app accent. Warnings are orange. Settings and editor controls use the brand
  blue; native menu-bar controls and Zones' on-screen controls follow the person's system accent.
- "AI-made" tells in copy or UI: em dashes, generic icon-plus-label grids, hedging microcopy.

## Design Principles

1. **The screen is the canvas.** The editor draws on the user's actual display; chrome floats only
   where it must, centered and reachable (a 49" ultrawide is the stress test).
2. **Show the result, not the words.** Split/merge controls depict the shape they produce; labels
   support, never substitute. Non-native English speakers must understand them.
3. **Numbers users can act on.** Pixel readouts, placed where the eye already is; no unit soup.
4. **Defer to the platform.** AppKit controls, system behaviors, native About/Settings idioms.
5. **One blue for app styling.** Settings and editor controls use `Brand.blue`; native menu-bar
   controls and Zones' on-screen controls inherit the system accent, and snap previews stay blue.
   Feature artwork uses its assigned hue, with a shared composition and material.

## Accessibility & Inclusion

Every control carries an accessibility label (SF Symbol `accessibilityDescription`, button titles).
Hover-revealed controls are also click-pinned so trackpad/switch users get a stable target. Esc
always cancels; Return always confirms. Color is never the only signal (active zones also get
thicker strokes). No motion beyond system defaults, so no reduced-motion variants are required.

## Keep Awake

Keep Awake is an independent, opt-in tool for timed idle-sleep prevention. Users start and stop
sessions in the Lineup panel, the right-click menu or Settings. The panel exposes duration,
Start/Stop and the display option together; an active session leads with its countdown and end
time. The Lineup icon's active menu-bar label and the panel countdown show the current state. Keeping the display on is a separate
preference, off by default.

Sessions last 15, 30, 60, or 120 minutes. Changing duration restarts the timer; changing the display
option preserves its deadline. Explicit sleep ends the session. Sessions never resume at wake or
app launch. The tool does not change permanent power settings, screen locking, or closed-lid behavior.

## Zones window controls

**Maximize or return** keeps the existing `full` shortcut. Press it again to return to the
frame immediately before maximizing. Both directions move the window the same best-effort way as
other shortcuts, so a window that cannot resize is centered and still returns. A return that does
not land keeps the original return frame for another press, including when the app raises its
minimum size while maximized and Lineup moves it partway. **Restore previous size** keeps the separate first-snap
history. Moving the window yourself, another snap, or a display change ends the temporary return.
Maximizing or returning never teaches a saved app launch position.

Hold the configured drag bind and pause the pointer on the line between two zones. After about
0.3 seconds, that line and a small handle appear. The line is a thin neutral rule and the handle a
narrow knob on it, like an overlay scroll bar, in light, dark and mixed content. The handle sits a
short distance from the pointer along the line, so a click or drag where the pointer already is
still reaches the window.
Crossing lines on the way somewhere else shows nothing, and how long the bind was held before does
not count. A key release, modifier change, scroll or click during the pause cancels it. Pressing
the bind while the pointer is already still shows nothing until the pointer moves. Ordinary
modifier-drag snapping never waits for this pause.

Move into the handle to use it. Entering widens the knob and brightens the line. The handle stays
where it appeared while the pointer moves along the line near it. Moving off the line, or more than
120 points along it, hides the handle; pausing again shows it at the new place. In a nested layout
the line shown is the one the handle moves.
Dragging shows the final frames of affected snapped windows that are visible on this desktop.
Each preview is drawn slightly inside its final frame so the line stays visible; the windows still
land exactly on those frames. When the line locks onto a guide, the knob fills in and a small label
beside the handle names the fraction, such as ½. Release applies the frames and saves the layout
once.
Releasing the bind during the drag cancels it. Clicking the handle pins it. You can then release the
bind, use the relevant arrow keys for one display pixel or Shift-arrow for ten, and press Return.
Escape, a click elsewhere, or switching apps cancels a pinned handle. Return on an unchanged handle
closes it without saving. Other nested lines stay anchored. The painted line and previews never
intercept clicks. Windows on another desktop keep their Restore history but are not moved. If a relevant
window cannot be identified or read, the divider change is refused without moving windows or
saving the layout. Holding an arrow or Return activation key does not adjust or confirm a pin.
Release that key before using it for a new manual adjustment or confirmation.

Ordinary modifier-drag keeps whole-zone, edge-half, and corner-quarter targets. A whole zone with
one eligible, explicitly snapped window also shows **Share zone** targets above its center.
Their glyphs show the right or bottom half your window takes. The targets sit on a small surface
that follows the system appearance. The active tile fills in and names **Side by side** or
**Stacked**; the blue preview shows where your window goes while the other window has a quieter
preview.
Deliberately enter the side-by-side or stacked target to preview both windows. Sharing assigns
complementary halves of the same zone, preserving its number and saved layout. Only those two
windows move. Shared halves follow later divider edits. Closed, minimized and other-desktop
records never count as occupants; two visible occupants or a partial one cannot share. Release
checks the same rule again, and Escape during the drag cancels it.
Share targets stay hidden while any remembered eligible window cannot be matched unambiguously
on screen. Ordinary single-window snaps remain available.

**Suggest windows for empty zones** is off by default. Enabling it explains and requests Screen
Recording, then saves only with access available. After a successful modifier-drag, Lineup looks for
a genuinely vacant zone on that display; untracked visible windows also block vacancy. When one
exists and other visible windows can go there, a compact chooser appears at that zone, on the side
nearest where you dropped the window. It never takes keyboard focus or activates Lineup, so typing
keeps going to your app. Nothing appears while windows are being read, when there is no window to
suggest or when reading fails. The chooser lists at most 32 concrete visible regular windows from the
current desktop, including other connected displays, but never the window you just dropped. Each
shows its app icon first and gets at most one preview, scaled down but never enlarged; a failed
preview says **Preview unavailable**. The chooser is at most 532 by 440 points and sits inside the
zone whenever the zone holds one card column; a narrow zone gets a narrower chooser with whole
columns. A zone too small for one column keeps the chooser over it, moved off the window you dropped
when there is room.
One click on a window moves it into the zone. Selecting rechecks its identity and the destination
first. Nothing else moves, and other empty zones are not filled. Pointer motion moves a quiet
selection ring. Clicking inside the chooser gives it the keyboard: the arrow keys move the ring,
drawn in the system accent while the chooser has focus, and Return acts on the focused control, so
Return on Close closes. Hover preserves Close focus and never scrolls; arrows scroll the selected
card into view without wrapping. Escape, Close, any click elsewhere or a new drag dismisses it,
even while windows are still being read. It closes on its own eight seconds after it appears and
checks again every eight seconds; it stays while previews load, while it has the keyboard, or while
the pointer is on it and has moved or scrolled since the last key press. A pointer resting on it
while you type elsewhere lets it close. Previews are taken only after a drop that has windows to
suggest, and stay in memory only while the chooser is shown. No app-wide activation or desktop
change occurs.
Revoking Screen Recording retains the preference, suppresses suggestions, and exposes recovery in
Settings. Startup, dragging, and capture failure never request this permission.

Coordinated moves require exact frame readback. A refused move or failed divider save attempts to
restore every touched window in reverse order and keeps the previous config and snap history.
Accessibility cannot provide cross-app atomicity. When a window refuses its new frame, windows
change while moving, or the layout cannot be saved, Lineup puts the windows back and shows a brief
note near the pointer that names the app when it can. The note never takes focus. If a window
cannot be put back, the note says so and **Retry Restore** stays in the Lineup menu and Zones
settings, blocking further coordinated moves. Retry Restore forgets a window only after its app
has quit or the window no longer exists; an unreadable or unresponsive window stays listed. Disabling Zones makes one bounded restoration attempt and
releases its retained window references. Display or desktop changes, sleep, permission loss,
shortcut recording, relevant settings edits, and opening the layout editor cancel temporary UI.
