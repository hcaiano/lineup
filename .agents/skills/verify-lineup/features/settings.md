# Settings

The `Lineup Settings` window lists General and every tool in a sidebar that
shows each tool's on or off state. Each tool pane has an enable toggle in its
header, and General shows the permission status and Open at Login.

## Sub-features

- `settings-open` opens the window from the panel, the right-click menu and Command-comma.
- `settings-sidebar` shows each tool row with its current `On` or `Off`.
- `settings-toggle` turns a tool on or off from its pane header. The
  change persists to `config.json`, and the sidebar and panel update live.
- `settings-permissions` shows Accessibility, Input Monitoring and Screen
  Recording as granted or missing, each with `Open System Settings…`.

## How to get to it (user POV)

- Click the gear in the panel, or `Open Settings` when no quick control is on.
- Choose Settings in the right-click menu of the Lineup icon.
- Press Command-comma while the panel is open.
- Click a tool row in the sidebar.

## Driving it with verify-lineup

Preconditions:

- Baseline from [README.md](./README.md). The Welcome window is dismissed.

- **Open from the panel.** Run `$V ax click role=AXMenuBarItem --scope menubar`
  and `$V ax click role=AXButton desc~="settings" --scope menubar`.
  `$V ax wait role=AXWindow title="Lineup Settings"` succeeds.
- **Open from the menu.** Close the window (`$V ax click role=AXButton subrole=AXCloseButton`),
  then run `$V ax click role=AXMenuBarItem --scope menubar --right` and
  `$V ax click role=AXMenuItem title~=Settings`. The window opens again.
- **Bring it forward.** When another app's window covers Settings, `click`
  refuses with exit 3. Run `$V ax raise role=AXWindow title="Lineup Settings"`, as a
  user would click the window.
- **Sidebar.** Run `$V ax find role=AXStaticText --scope windows`. Each tool row
  is `desc="<Tool>" value="On|Off"`, and only `desc="Zones"` reads `On` on a
  fresh config.
- **Turn a tool on.** Run `$V ax click role=AXStaticText desc="Keep Awake"`, then
  `$V ax click role=AXCheckBox desc="Enable Keep Awake"`.
  `$V ax read role=AXCheckBox desc="Enable Keep Awake"` prints `1`. The sidebar row
  reads `value="On"`, and `$V config` shows `"awake": {"enabled": true`.
- **Live in the panel.** Open the panel. A `desc="Keep Awake" id="mug"` tab now exists.
- **Turn it off.** Click the same toggle again. The sidebar reads `Off`, the
  tab disappears and the config has `"enabled": false`.
- **Permissions.** Run `$V ax click role=AXStaticText value=General` and
  `$V ax tree --scope windows --depth 14`. Accessibility, Input Monitoring and
  Screen Recording each read `Granted`, because launch grants them.
- **Proof.** Record the toggle round trip, and keep `$V config` output with
  `f=$(mktemp) && $V config > "$f" && $V keep "$f" --as settings-config.json`.

## Gotchas

- Rows show the tool name in `desc` and the state in `value`. Select a row by
  `desc=`, because `title=` is empty.
- The General row has `value="General"` and no `desc`.
- The pane's own `AXStaticText value="<Tool>"` heading also matches
  `value=`. Use `desc=` for rows.
- Launch grants every permission. A journey about a missing permission must
  first revoke it in the VM's System Settings (Privacy & Security), and say so in the notes.
- Turning a tool on can start system effects, such as Zones' modifier-drag
  monitor. Turn off what the journey turned on before you test something else.
