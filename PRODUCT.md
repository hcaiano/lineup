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

Changes apply to the next scroll. Reversal changes only the sign of each scroll: speed and inertia
stay as macOS delivers them, gesture events such as zoom, rotation and space swipes are never
touched, and no event is added or removed. A gesture keeps one device through its inertia.
Scrolling that cannot be attributed to a mouse or trackpad, including input posted by other apps,
keeps the macOS direction. Missing Accessibility leaves scrolling unchanged
and shows recovery in Settings. Disabling the tool or quitting ends interception immediately.
Smoothing, acceleration, button remapping and per-app rules are out of scope.

## Brand Personality

Native, precise, calm. One fixed brand blue (#2F6BFF, `Brand.blue` in
`Sources/lineup/App/Brand.swift`) carries selection and controls in Settings and the layout editor.
The menu-bar popover and its controls inherit the system accent and appearance. Other styling
defers to macOS conventions (system fonts, vibrancy, standard controls). Feature artwork uses one color per tool
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
- Red as a custom app accent. Warnings are orange. Settings and editor controls use the brand
  blue; native menu-bar controls follow the person's system accent.
- "AI-made" tells in copy or UI: em dashes, generic icon-plus-label grids, hedging microcopy.

## Design Principles

1. **The screen is the canvas.** The editor draws on the user's actual display; chrome floats only
   where it must, centered and reachable (a 49" ultrawide is the stress test).
2. **Show the result, not the words.** Split/merge controls depict the shape they produce; labels
   support, never substitute. Non-native English speakers must understand them.
3. **Numbers users can act on.** Pixel readouts, placed where the eye already is; no unit soup.
4. **Defer to the platform.** AppKit controls, system behaviors, native About/Settings idioms.
5. **One blue for app styling.** Settings and editor controls use `Brand.blue`; native menu-bar
   controls inherit the system accent. Feature artwork uses its assigned hue, with a shared
   composition and material.

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
