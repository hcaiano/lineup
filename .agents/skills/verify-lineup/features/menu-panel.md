# Menu-bar panel

Clicking the Lineup icon opens one compact popover with an icon tab for each
enabled quick control (Display Control, Keep Awake, World Clock, Text Capture,
in that order), plus Settings and app actions in its top row. Right-clicking the
icon opens a short native menu.

## Sub-features

- `panel-open` opens the popover from the status item and closes it with
  Escape, a second click or a click outside.
- `panel-tabs` shows one tab per enabled quick control, selected with a click,
  Command-1…9 or Control-Tab.
- `panel-empty` offers Settings when no quick control is enabled.
- `panel-settings` opens Settings from the gear button.
- `panel-more` opens the More menu with Check for Updates…, About Lineup and Quit Lineup.
- `panel-context` opens the right-click menu with `Settings…`, `Check for Updates…`,
  `About Lineup`, `Quit Lineup` and any actionable tool problem.
- `panel-shortcut` opens Settings with Command-comma while the panel is open.

## How to get to it (user POV)

- Click the Lineup icon in the menu bar.
- Right-click the Lineup icon.
- With the panel open, click a tab, press Command-1…9, or press Control-Tab or
  Control-Shift-Tab.
- In the panel's top row, click the gear (`Open Lineup settings`) or the
  ellipsis (`More`).

## Driving it with verify-lineup

Preconditions:

- Baseline from [README.md](./README.md). The Welcome window is dismissed.
- For `panel-tabs`, at least two quick controls are on. Turn on Keep Awake and
  World Clock through [Settings](./settings.md).

- **Open.** Click the status item. Run `$V ax click role=AXMenuBarItem --scope menubar`.
  `$V ax wait role=AXPopover --scope menubar` succeeds.
- **Empty panel.** With no quick control on, read the popover. Run
  `$V ax tree --scope menubar --depth 12`. It shows `No quick controls turned on`,
  an `Open Settings` button and no tab group.
- **Tabs.** With Keep Awake and World Clock on, run
  `$V ax find role=AXRadioButton --scope menubar`. It lists
  `desc="Keep Awake" id="mug"` before `desc="World Clock" id="clock"`.
  Selecting one by click (`$V ax click role=AXRadioButton id=clock --scope menubar`)
  or by key (`$V ax key cmd+2`) sets its `value="1"` and changes the
  `AXHeading` under the tabs to the tool's name.
- **Next tab.** Run `$V ax key ctrl+tab`. The other tab's `value` becomes `1`.
- **Settings button.** Run `$V ax click role=AXButton desc="Open Lineup settings" --scope menubar`.
  `$V ax wait role=AXWindow title="Lineup Settings"` succeeds.
- **Settings shortcut.** Close Settings, open the panel and run `$V ax key cmd+comma`.
  The `Lineup Settings` window opens.
- **More menu.** Run `$V ax click role=AXMenuButton desc=More --scope menubar`.
  `$V ax find role=AXMenuItem` lists `Check for Updates…`, `About Lineup` and
  `Quit Lineup`. Close it with `$V ax key escape`.
- **Right-click menu.** Close the panel, then run
  `$V ax click role=AXMenuBarItem --scope menubar --right` and
  `$V ax find role=AXMenuItem`. It lists `Settings…`, `Check for Updates…`,
  `About Lineup` and `Quit Lineup`, and no tool controls. Close it with `$V ax key escape`.
- **Close.** With the panel open, run `$V ax key escape`.
  `$V ax wait role=AXPopover --scope menubar --gone` succeeds.
- **Proof.** Record the journey, then `$V shot menu-panel-tabs` with the panel open.

## Gotchas

- The popover is a child of the menu-bar item. Without `--scope menubar`, a
  name such as `World Clock` also matches the Settings sidebar and the click
  fails as ambiguous.
- In World Clock, the first Escape leaves place search or edit mode, and only
  a second Escape closes the panel.
- The first opening selects the first available quick control, and reopening
  remembers the last tab for this app session. Do not assume a tab: read
  `value="1"`.
- `Check for Updates…` reaches the network with Sparkle. Launch turns off
  automatic checks, so do not click it unless the journey is about updates.
- `Quit Lineup` ends the run's app. Relaunch it with
  `$V sh 'open -a /Applications/Lineup.app'`, then `$V doctor`.
