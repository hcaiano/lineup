# World Clock

World Clock compares the user's local time with saved places in the Lineup
panel. It has offline city search, rename, remove and a ±24-hour time scroll.
It starts off. With no saved places it shows Local and an `Add a City` button.

## Sub-features

- `clock-enable` turns the tool on in Settings and adds its panel tab.
- `clock-empty` shows Local plus an empty-state prompt with `Add a City`.
- `clock-add` searches cities offline, shows each result's current time and saves one.
- `clock-order` sorts places by UTC offset, with Local first among equal offsets.
- `clock-edit` renames, removes and reorders places in edit mode.
- `clock-scroll` moves every row to the same simulated instant, and reopening returns to Now.
- `clock-separate` adds an optional separate menu-bar item, which can show a
  pinned place's time.

## How to get to it (user POV)

- Panel: click the Lineup icon, then the World Clock tab (the clock).
- Settings: `World Clock` in the sidebar has the enable toggle,
  `Open World Clock` and `Separate clock`.
- The separate clock item in the menu bar, when it is on.

## Driving it with verify-lineup

Preconditions:

- Baseline from [README.md](./README.md). The Welcome window is dismissed.
- World Clock is off and has no saved places.

- **Enable.** In Settings, run `$V ax click role=AXStaticText desc="World Clock"`
  and `$V ax click role=AXCheckBox desc="Enable World Clock"`. The pane shows
  `No places yet`.
- **Open from Settings.** Run `$V ax click role=AXButton desc="Open World Clock"`.
  The panel opens on the tab `id="clock"`, with `AXHeading desc="World Clock"`
  and a row `Local, <weekday>, <date>, <time>`.
- **Add a place.** Run `$V ax click role=AXButton desc="Add a City" --scope menubar`
  and `$V ax type Lisbon`. Results are buttons such as
  `desc="Lisbon, Lisbon, Portugal, 3:52 PM"`. Run
  `$V ax click role=AXButton desc~="Lisbon, Lisbon, Portugal" --scope menubar`.
  The panel returns to the clocks, with a row that starts with `Lisbon, Today, +1h`.
- **Persisted.** `$V config` shows `tools.worldClock.settings.places[0].timeZoneID`
  as `Europe/Lisbon`.
- **Time scroll.** Run `$V ax read role=AXSlider desc~="Time scroll" --scope menubar`
  (it prints `0`). Drag its knob, the `AXValueIndicator` inside the slider,
  to the right: `$V ax drag --from <knob center> --to <80 points right> --steps 20`,
  with points read from `$V ax tree --scope menubar --depth 12`. The slider reads
  about `51` (15-minute steps), every row's time moves by the same amount,
  and `Now` becomes `+12h 45m from now`.
- **Back to Now.** Close the panel with Escape and reopen it. The slider reads `0` again.
- **Rename.** Run `$V ax click role=AXButton desc=Edit --scope menubar`. Each place
  gets `AXButton desc="Remove <name>"` and `AXTextField desc="Name for <name>"`.
  Run `$V ax click role=AXTextField desc="Name for Lisbon" --scope menubar`,
  `$V ax type " HQ"` and `$V ax click role=AXButton desc=Done --scope menubar`.
  The row starts with `Lisbon HQ`, and `$V config` shows `"name": "Lisbon HQ"`.
- **Remove.** In edit mode, run `$V ax click role=AXButton desc="Remove Lisbon HQ" --scope menubar`.
  The row disappears and `places` is empty. Removing the last place also
  leaves edit mode, so `Done` is gone and `Add a City` returns.
- **Proof.** Record from Enable to the saved Lineup row as `world-clock-add`,
  then `$V shot world-clock-places`.

## Gotchas

- `World Clock` matches the Settings row, the panel tab and the panel heading.
  Use `--scope menubar` with `role=` for the panel.
- Command-A, Command-V and the other edit shortcuts do nothing in the panel's
  text fields (found on 2026-10-16: Lineup has no Edit menu). Type the text,
  and clear a field with `$V ax key delete` presses.
- Search waits for typing to settle. Use `$V ax wait role=AXButton desc~="Lisbon, Lisbon" --scope menubar`
  before you click a result.
- The first Escape leaves search or edit mode, and a second Escape closes the panel.
- Times depend on the VM clock and time zone (the host's). Assert relative
  facts such as `+1h` and `Europe/Lisbon`, not a fixed clock time.
- `Separate clock` adds a second menu-bar item. `$V ax ... --scope menubar`
  then sees two `AXMenuBarItem`s, so pass `--index 0` for the Lineup icon.
