# Lineup verification map

This directory is the maintained source for verifying Lineup's user-facing
behavior. Read this index before driving the app, then use the matching feature
file as the recipe. `V` is `.agents/skills/verify-lineup/scripts/verify-lineup`,
run from the repository root.

## Baseline preconditions

- `$V setup` has finished once on this machine (`base VM ready`).
- `$V launch` started this run from the checkout under test, and `$V doctor`
  reports `doctor: healthy`.
- A fresh launch has no `~/.config/lineup` in the VM. Lineup treats it as a
  brand-new user and shows `Welcome to Lineup`. Dismiss it with
  `$V ax click role=AXButton desc="Not now"`, or launch with
  `--config .agents/skills/verify-lineup/fixtures/returning-user.json` to start
  with no window.
- With default settings only Zones is on. Every other tool, Keep Awake and
  World Clock included, starts off.
- The VM has one display, `Apple Virtual`, at 1920x1200 points.

## Driving conventions

- Start each recipe from the baseline unless its preconditions say otherwise.
- Prefer accessible names (`desc=`, `title=`, `id=`) over coordinates. Use
  coordinates only for drags, read from `$V ax tree` frames.
- Treat each command as literal. Keep quoted names and selectors unchanged.
- The panel lives in the menu bar. Pass `--scope menubar` when a name also
  exists in Settings, such as `desc="World Clock"`.
- Turn on a tool through its Settings toggle, the way a user does. Never edit
  the config to enable it.
- Wait for the result (`$V ax wait ...`) instead of a fixed sleep. Add a
  `sleep 1` after an action only so a recording shows it.
- Never drive the host desktop, except for `host-only` journeys under the
  standing rule in [SKILL.md](../SKILL.md#host-desktop-the-one-standing-rule).

## Proof and skip reporting

- Record the journey: `$V record start <feature>-<journey>` before the first
  action and `$V record stop` after the end state is visible.
- Capture the action and the resulting state, plus the side effect from a
  second view: `$V config`, `$V sh 'pmset -g assertions'`, or another app's
  window frame.
- Tag each artifact with the feature ID and entry point in `$V note`.
- Report each unreachable entry point with the command you tried and the
  unmet precondition. Never report a skipped path as verified through another one.
- Report each `host-only` journey you could not run under `Pending host journeys`.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph that describes the
user-visible behavior. It then has exactly four H2 sections, in this order:

1. `Sub-features` lists short IDs, one line per behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with verify-lineup` starts with `Preconditions:`. Its labeled
   bullets pair each user action with an exact command and an observable result.
4. `Gotchas` lists traps that waste or invalidate a run.

Keep implementation details out of the map. Name only user paths, stable
handles, required state, commands and observable proof.

## Features

- [Menu-bar panel](./menu-panel.md): the status item, the popover with tool
  tabs, the More menu, the right-click menu, Escape and outside clicks.
- [Settings](./settings.md): the Settings window, the sidebar, tool toggles and
  permission status.
- [Keep Awake](./keep-awake.md): timed sleep prevention from the panel and
  Settings, with the real power assertion as proof.
- [World Clock](./world-clock.md): places, offline city search and time
  scroll in the panel.
- [Zones](./zones.md): window snapping by shortcut and by Shift-drag, and the
  layout editor.

## Host-only, not mapped yet

These journeys need hardware that the VM does not have. Each one needs a
feature file with the `host-only` tag before an agent can claim the desktop
for it:

- Display Control on an external DDC display: brightness, volume, black
  screen and Apple's native on-screen indicators.
- Hyperkey and Keyboard Remap through the physical keyboard's Caps Lock path.
- Zones and Cycler across several displays.
