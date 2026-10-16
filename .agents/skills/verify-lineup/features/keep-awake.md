# Keep Awake

Keep Awake prevents idle sleep for a timed session of 15, 30, 60 or 120
minutes. Users start and stop it in the panel or in Settings. An active
session shows a countdown and its end time in the panel, and the Lineup icon
shows the label `Awake`.

## Sub-features

- `awake-enable` turns the tool on in Settings and adds its panel tab.
- `awake-start` starts a session with the chosen duration and holds a
  `PreventUserIdleSystemSleep` power assertion named `Lineup Keep Awake`.
- `awake-countdown` shows `Time remaining`, the end time and the `Awake` menu-bar label.
- `awake-duration` restarts the timer when the duration changes during a session.
- `awake-display` keeps the display on as well, a separate option that is off by default.
- `awake-stop` ends the session, releases the assertion and restores the icon.

## How to get to it (user POV)

- Panel: click the Lineup icon, then the Keep Awake tab (the mug).
- Settings: `Keep Awake` in the sidebar, with Duration, `Keep display on` and `Start`.

## Driving it with verify-lineup

Preconditions:

- Baseline from [README.md](./README.md). The Welcome window is dismissed.
- Keep Awake is off, so the journey turns it on like a first-time user.

- **Enable.** Open Settings from the panel (`$V ax click role=AXMenuBarItem --scope menubar`,
  `$V ax click role=AXButton desc="Open Settings" --scope menubar`). Then run
  `$V ax click role=AXStaticText desc="Keep Awake"` and
  `$V ax click role=AXCheckBox desc="Enable Keep Awake"`. `$V config` shows
  `"awake": {"enabled": true`.
- **Pick a duration.** Open the panel and select the tab:
  `$V ax click role=AXMenuBarItem --scope menubar`, then
  `$V ax click role=AXRadioButton id=mug --scope menubar`. Run
  `$V ax click role=AXRadioButton desc="15 min" --scope menubar`. That segment
  reads `value="1"`. The default is `30 min`.
- **Start.** Run `$V ax click role=AXButton desc=Start --scope menubar`. The
  button becomes `Stop`, and `$V ax find role=AXStaticText desc="Time remaining" --scope menubar`
  succeeds. The menu-bar item shows `Awake`.
- **Assertion.** Run `$V sh 'pmset -g assertions | grep -i "lineup"'`. It shows
  `PreventUserIdleSystemSleep named: "Lineup Keep Awake"` with a timeout of
  about 900 seconds.
- **Display option.** Run `$V ax click role=AXCheckBox subrole=AXSwitch --scope menubar`
  (the switch next to `Keep display on`). It reads `1`. `pmset -g assertions` adds
  `PreventUserIdleDisplaySleep named: "Lineup Keep Awake"`, and `Awake until`
  keeps the same time.
- **Stop.** Run `$V ax click role=AXButton desc=Stop --scope menubar`. The button
  reads `Start`, and `pmset -g assertions | grep -c "Lineup Keep Awake"` prints `0`.
- **Settings entry.** Run `$V ax click role=AXStaticText desc="Keep Awake"` and
  `$V ax click role=AXButton desc=Start --scope windows`. `No active session`
  becomes `Awake · 14:59 remaining`, and the same assertion appears. Stop it
  with `$V ax click role=AXButton desc=Stop --scope windows`.
- **Proof.** Record from Enable to Stop as `keep-awake-session`. Keep the
  assertion output while the session runs:
  `f=$(mktemp) && $V sh 'pmset -g assertions' > "$f" && $V keep "$f" --as keep-awake-pmset.txt`.

## Gotchas

- The panel's `Keep display on` switch has no accessible name (found on
  2026-10-16). Select it by `subrole=AXSwitch`, and treat a fix that names it
  as a change to this recipe. The Settings toggle is `desc="Keep display on"`.
- PRODUCT.md still names the right-click menu as a Keep Awake entry point, but
  that menu has no session controls. Do not report it as verified.
- `grep -c` exits 1 when it counts 0, so `$V sh '... | grep -c ...'` fails
  after Stop even though the proof passed. Read the printed count.
- The tab appears only after the tool is on. Before that, the panel shows
  only the other enabled quick controls, or `Open Settings` when none are on.
- `Start` and `Stop` exist in both the panel and Settings. Pass
  `--scope menubar` or `--scope windows`.
- Sessions never resume at launch or after wake. Relaunching Lineup ends the proof.
- The VM never sleeps on its own during a run, so the assertion is the proof,
  not an observed sleep.
- Keep the session short. Stop it before cleanup, so the recording shows the release.
