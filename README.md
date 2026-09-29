<div align="center">

<img src="Icon/icon-1024.png" width="128" alt="Lineup icon">

# Lineup

**A native macOS menu-bar suite for window layouts, keyboard shortcuts and world clocks.**

[Download](https://lineup.caiano.com) · [Build from source](BUILDING.md) ·
[Contribute](CONTRIBUTING.md)

</div>

![Lineup layout editor with three custom zones](docs/editor.png)

Lineup combines five tools. Enable only the tools you need:

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
  place's live time to the menu bar. City search and sunrise/sunset estimates work offline.
- **Keep Awake:** Prevent idle sleep for 15 minutes, 30 minutes, 1 hour, or 2 hours.
  Choose separately whether the display should stay on.

Lineup is built with Swift, AppKit, and SwiftUI. It requires macOS 13 or later.

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

Enable World Clock in Settings to add its clock icon to the menu bar. It starts disabled and
does not require Accessibility, Input Monitoring or location access. Its icon is independent of
the main Lineup icon's visibility preference.

- Click **+** to search cities or IANA time zones, such as `Europe/Lisbon`. Search accepts alternate
  names and ignores accents. Cities include their region and country to distinguish namesakes.
- Clocks run from earlier to later local time, with **Local** in its chronological position.
  Local follows the Mac's time zone; ordering follows the selected instant, including daylight saving.
- Use **Edit** to rename or remove places, or reorder cities that share the same time.
- Click a **pin** to replace the clock icon with one place's name and live time. Pinning another
  place replaces the previous pin; unpinning or removing it restores the icon. Local can be pinned.
- Drag or scroll the time ruler, or use its arrow keys, to move in 15-minute steps across ±24
  hours. The local time field accepts an exact time on the selected day. **Now**, or closing and
  reopening the panel, restores live time. A pinned menu-bar time always remains live.
- Hours follow the Mac's 12/24-hour preference. Day labels and differences use the selected
  instant, including daylight-saving transitions and fractional-hour zones.
- Each city shows its next sunrise or sunset at the selected instant. `+1d` means the next city
  date. Solar times are approximate; polar day/night appears when there is no nearby event.
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

## Keep Awake

Enable Keep Awake in Settings, then choose a duration from its menu-bar submenu or start a
session in Settings. The menu bar shows "Awake" while a session is active. Open its submenu
to see the remaining time or stop early.

"Keep display on" is off by default. Turning it on or off during a session keeps the original
deadline. Choosing another duration starts a new session. Expiration, stopping, disabling the
tool, sleeping the Mac, or quitting Lineup releases its power requests. Waking or restarting
Lineup never resumes a session. Only the duration and display preference are saved.

Keep Awake needs no extra permissions and does not change permanent macOS power settings.
You can still lock the screen or explicitly sleep the Mac. Closed-lid operation is not supported.

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
