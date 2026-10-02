<div align="center">

<img src="Icon/icon-1024.png" width="128" alt="Lineup icon">

# Lineup

**A native macOS menu-bar suite for window layouts, keyboard shortcuts and world clocks.**

[Download](https://lineup.caiano.com) · [Build from source](BUILDING.md) ·
[Contribute](CONTRIBUTING.md)

</div>

![Lineup layout editor with three custom zones](docs/editor.png)

Lineup combines eight tools. Enable only the tools you need:

- **Zones:** Draw a window layout on each display. Move windows with Shift-drag or a shortcut.
  Zone shortcuts are numbered across ALL your displays: each display's Settings group shows its
  global zone range, and `zone:N` moves the focused window to that global zone on its owning
  display — even across displays. Numbers belong to saved displays, so unplugging one keeps its
  range reserved (those shortcuts wait safely instead of moving a different display's windows).
  Note that adding or removing zones on an earlier display shifts the numbering of every later
  display, since each display's range follows the one before it.
- **Cycler:** Cycle through apps and windows with shortcuts, including app groups and
  reverse cycling.
- **Hyperkey:** Turn Caps Lock or another key into Control + Option + Shift + Command.
- **World Clock:** Compare cities with your local time, scroll through nearby hours, and pin a
  place's live time to an optional separate menu-bar item. City search and sunrise/sunset
  estimates work offline.
- **Keep Awake:** Prevent idle sleep for 15 minutes, 30 minutes, 1 hour, or 2 hours.
  Choose separately whether the display should stay on.
- **Text Capture:** Select a region on any display and copy its text, recognized locally in
  Portuguese and English.
- **Menu Bar:** Hide the icons you place left of an arrow, and show them with one click.
  Requires macOS 27 and is off by default.
- **Display Control:** Adjust confirmed hardware brightness and speaker volume per compatible
  display. Optional brightness keys can adjust one display or a calibrated group; volume keys
  have their own destination.

Lineup is built with Swift, AppKit, and SwiftUI. It requires macOS 13 or later.

## Controls in one place

Click the Lineup menu-bar icon to open its panel. The top row has an icon tab for each enabled
tool. Select Display Control for hardware brightness and volume sliders, Keep Awake for duration
and Start/Stop controls, or World Clock to manage places and compare times. Zones has **Edit
Layout…** and the drag-to-snap switch; Cycler lists your app shortcuts, and clicking one opens that
app; Hyperkey shows which key sends Hyper; Text Capture starts a capture and shows its shortcut.
Settings and other app actions are in the same top row. Right-click the icon for the native menu
and its tool submenus.

The first opening selects Display Control when available. Later openings remember your last tab
until Lineup quits. Disabling the selected tool switches to the first remaining tab. Select tabs
with Command-1 through Command-8, or cycle with Control-Tab and Control-Shift-Tab.

Click outside, click the Lineup icon again, or press Escape to close the panel. In World Clock,
Escape first leaves search or editing. Closing the panel leaves enabled tools and any Keep Awake
session running.

## Remembering app placement

Zones remembers the last successful placement for each app, including zone shortcuts, directional
shortcuts and Shift-drag edge or corner placements. Quit and relaunch that app while Zones is running
to put its first regular window back in the saved destination. Splash screens and sheets are skipped.
Additional windows stay where the app opens them. Moving or resizing a window yourself, or using
Restore, leaves the remembered destination unchanged.

This happens once per app launch. Enabling Zones or restarting Lineup does not move windows of apps
that are already running. Turning Zones off stops pending restorations. Missing Accessibility access
or a failed move does not cause repeated placement attempts.

Destinations use the saved display identity, not shortcut numbers. If that display is disconnected,
the window stays where macOS opens it and the association is kept for a later launch. A changed
layout is also skipped. Saving layout edits clears remembered placements for that display; place an
app again to teach its new destination. Editing another display or changing display order does not
affect it. Learning also waits while an old layout import is pending; reconnect that display first.
Associations live in the shared `~/.config/lineup/config.json` file.

## World Clock

Enable World Clock in Settings to access it from the Lineup panel. It starts disabled and does
not require Accessibility, Input Monitoring or location access. Turn on **Separate clock**
in World Clock settings for its own clock icon or a pinned live time. New clock configurations
use the Lineup panel alone; previously saved configurations keep their separate item. That item
is independent of the main Lineup icon's visibility preference, and hiding it keeps places and
the pin saved.

Select the **World Clock** tab in the Lineup panel, or click the separate clock item:

- Click **+** to search cities or IANA time zones, such as `Europe/Lisbon`. Search accepts alternate
  names and ignores accents. Results show each place's region and current time to distinguish
  namesakes.
- Clocks run from earlier to later local time, with **Local** in its chronological position.
  Local follows the Mac's time zone; ordering follows the selected instant, including daylight saving.
- Use **Edit** to rename or remove places, or reorder cities that share the same time.
- While **Separate clock** is on, choose which place it shows in World Clock settings, from a
  clock's right-click menu, or with the pin in **Edit**. Pinning another place replaces the
  previous pin; unpinning or removing it restores that item's icon. Local can be pinned.
- Drag or scroll the time ruler, or use its arrow keys, to move in 15-minute steps across ±24
  hours. The local time field accepts an exact time on the selected day. **Now**, or closing and
  reopening the clock, restores live time. The pinned menu-bar time always remains live.
- Hours follow the Mac's 12/24-hour preference. Day labels and differences use the selected
  instant, including daylight-saving transitions and fractional-hour zones.
- Each city shows a sun or moon for day or night at the selected instant. Hover over it for the
  estimated next sunrise or sunset; polar day/night appears when there is no nearby event.
  Local and bare time zones have no solar data because they do not identify coordinates.

The bundled [GeoNames](https://www.geonames.org/) catalog covers cities with more than 15,000
inhabitants and capitals. Smaller places may be absent; add a nearby city or its time zone.
The catalog is distributed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Settings includes attribution links. No search or solar request leaves the Mac.

## Install

1. Download the current version from [lineup.caiano.com](https://lineup.caiano.com).
2. Move Lineup to Applications and open it.
3. Allow Accessibility access when macOS asks. Lineup needs it to inspect and move windows.
4. If you enable Hyperkey, allow Input Monitoring when macOS asks. The other tools do not request
   this permission.

## Display control

Enable Display Control in Settings. Click the Lineup icon to use its brightness and volume
sliders in the **Display Control** tab, or use its right-click menu submenu or Settings. Each
display shows only supported controls. An unavailable value stays unavailable until a valid read succeeds. Use
**Detect Displays** in Settings, or **Detect Again** in the panel when a display shows no
controls, after reconnecting a display, changing its cable or dock, or enabling DDC/CI in its own
menu.

Brightness and volume keys start off. Turn on either group in Display Control settings and grant
Accessibility when asked. Both default to the display under the pointer; choose a specific display
if preferred. While a key group is on, each display's checkbox can exclude it from that group.
An explicitly selected display that is disconnected receives no commands, and another display
does not replace it. A held key stays with the display selected at the start of that press.
Hold Option-Shift with a brightness or volume key for smaller adjustments. Other modified keys
retain their existing behavior. Confirmed changes show the classic macOS brightness or volume
overlay on the affected display. Lineup uses feedback with native material if that system interface
is unavailable or a change fails; a pending request is never shown as a confirmed level.
Mute restores only a level observed during the current connection; if it started at zero, use
Volume Up to unmute.

To adjust several displays with brightness keys, enable **Sync brightness across displays** in
Settings. The display under the pointer is the reference by default, or choose a fixed reference.
Its brightness sets the shared level for compatible displays included in the key group. Moving
the pointer during a held key does not change the reference or group. A disconnected selected
reference blocks the group. Volume keys keep their own destination, and each manual slider still
changes only its display.

With sync on, adjust each display's **Minimum brightness** and **Maximum brightness** to match
your displays by eye. They start at 0% and 100%; the maximum must be at least 5% and exceed the
minimum. For example, a 10% minimum and 80% maximum send 45% when the shared level is 50%.
Lineup does not measure apparent brightness. Editing either bound changes no hardware level;
it takes effect on the next synced brightness key press. Calibration does not affect individual
sliders or brightness keys while sync is off. **Calibrate…** in the panel opens these settings.

**Black screen below minimum** is an optional setting under Brightness keys and starts off.
When enabled, press Brightness Down again at minimum to make the display black without powering
it off. With sync on, shared 0% covers only the displays included in that group, at their configured
hardware minimums. Brightness Up clears the cover and increases brightness normally. **Restore**
next to a display clears its cover; Escape clears all covers. Restore and Escape leave hardware
brightness unchanged, so use Brightness Up if the hardware level itself is too dark. **Black screen**
appears separately from the monitor's confirmed percentage.

Manual sliders need no extra permission. Saved preferences never reapply brightness or volume
at launch. Disabling the tool or quitting stops key interception and cancels pending commands.
Sleep and connection changes cancel work; wake and reconnection trigger fresh detection.
Black screens are not saved and clear on sleep, connection or preference changes, loss of
Accessibility permission, shortcut recording, Secure Input, disabling or quitting. Lineup refuses
to cover a display if it cannot register the emergency Escape shortcut.

Compatibility depends on the monitor and connection. Built-in and supported Apple displays use
native brightness. External displays use DDC/CI for brightness and volume when valid hardware
reads succeed. DisplayLink, some HDMI paths, docks, adapters, and displays without DDC/CI can leave
controls unavailable. Two displays that expose indistinguishable hardware identities are refused
when their DDC services cannot be matched safely. See
[MonitorControl's compatibility notes](https://github.com/MonitorControl/MonitorControl#supported-displays).
The optional black cover changes no gamma, display power or arrangement. Lineup does not use
gradual software dimming as a fallback and does not change resolution or HDR.

## Keep Awake

Enable Keep Awake in Settings, then choose a duration and press **Start** in the Lineup panel.
The same panel shows the remaining time, **Stop**, and **Keep display on**. The right-click menu
submenu and Settings also provide session controls. The Lineup menu-bar item shows "Awake"
while a session is active.

"Keep display on" is off by default. Turning it on or off during a session keeps the original
deadline. Choosing another duration starts a new session. Expiration, stopping, disabling the
tool, sleeping the Mac, or quitting Lineup releases its power requests. Waking or restarting
Lineup never resumes a session. Only the duration and display preference are saved.

Keep Awake needs no extra permissions and does not change permanent macOS power settings.
You can still lock the screen or explicitly sleep the Mac. Closed-lid operation is not supported.

## Copy text from the screen

1. Open Settings → Text Capture and enable the tool. It starts off, with no shortcut assigned.
2. Choose **Capture Text…** in the menu bar or Settings. You can also record a global shortcut
   in its settings. Conflicts with other Lineup tools or apps are reported there.
3. On the first capture, allow Screen Recording in macOS. Enabling the tool alone never asks for
   this permission. If access was denied or revoked, use **Open Screen Recording Settings…** in
   Text Capture or General → Permissions. Quit and reopen Lineup if macOS asks, then try again.
4. Drag around text on one display and release to copy it. Press Escape to cancel selection.
   A drag crossing a display edge is limited to the display where it started.
5. After **Text copied**, paste with Command-V in the destination app. Nothing is pasted automatically.

Empty captures, failed recognition, and cancellation leave the clipboard unchanged. Select a
larger region if small text is missed. The engine reads rows from top to bottom and fragments from
left to right; complex columns and tables may need separate captures. Portuguese and English
language support must both be available in the local macOS recognition engine. If either is
unavailable, Text Capture explains this without replacing the clipboard.

Invoking capture again during selection or recognition does not start another job. Use **Cancel
Text Capture** in the menu to stop pending work. Display changes, disabling the tool, and quitting
Lineup also cancel it. Captures stay in memory and are released after use; Lineup does not keep a
capture history, log the recognized text, or send it to a service. The copied text remains on the
system clipboard until another app or copy action replaces it.

## Organize the menu bar

On macOS 27, enable **Menu Bar** in Settings. It adds an arrow to the menu bar. Accessibility is
needed to see which side of the arrow each icon is on. Screen Recording and Full Disk Access are
not required.

Hold Command (⌘) and drag icons in the menu bar: icons to the left of the arrow hide when it
collapses, and icons to its right stay visible. Click the arrow to show the hidden icons in place;
they hide again after 10 seconds, but not while the pointer is on the menu bar or one of their
menus is open. The group starts collapsed. Lineup never moves your pointer or drags icons for you.
**Settings › Menu Bar** shows both groups.
Press Return in that pane to show or hide the icons without moving your pointer.

macOS 27 hides whole apps: an app with an icon on each side of the arrow stays visible. System
icons such as the clock and Control Center always stay visible. Disabling Menu Bar, quitting and
crashes restore the visibility flags changed by Lineup. Apps already hidden in macOS settings
stay hidden. Quit other menu bar managers before using Lineup to avoid competing changes.

The system clock, Notification Center and capture indicators stay usable while the group is
hidden. Synergy's tray can belong to either group. If Settings requests **Allow Menu Bar Access**,
choose the indicated settings file; Lineup changes only the visibility of your selected apps.

This tool uses a private macOS 27 interface. If macOS no longer offers it, the arrow stays but
nothing hides, and Settings says so. Menu Bar is unavailable on other macOS versions; the other
tools still support macOS 13+.

## Update tracks

Stable is the default and receives tested public releases. Nightly is a public opt-in in General
settings for newer builds that may be less reliable. Returning to Stable stops Nightly updates and
waits for a newer Stable release; Lineup does not install an older Stable version as a downgrade.

## Build from source

```sh
git clone https://github.com/hcaiano/lineup.git
cd lineup
swift build
swift run lineup-tests
```

Building needs the macOS 26 SDK or later. Command Line Tools 26 are enough; with the macOS 27 SDK,
the app needs full Xcode 27. See [BUILDING.md](BUILDING.md) to assemble the app, keep a stable
local Accessibility grant, and understand the project layout.

## Contribute

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you report a bug or open a pull request. New features
and behavior changes should start in [Discussions](https://github.com/hcaiano/lineup/discussions).

## License

Lineup is available under the [Apache License 2.0](LICENSE). Releases before 2.0.0 remain under
their [MIT License](LICENSE-1.x).
