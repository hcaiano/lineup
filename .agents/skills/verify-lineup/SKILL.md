---
name: verify-lineup
description: Launch, drive and record the real Lineup macOS menu-bar app in a disposable macOS 27 VM, away from the developer's desktop. Use it to prove a UI or behavior change with screenshots and a start-to-finish video before a PR, to reproduce a user-visible bug, or whenever someone asks whether Lineup actually works.
---

# Verify Lineup

`scripts/verify-lineup` boots a fresh clone of a local macOS 27 VM, installs the
build of this checkout, starts Lineup and drives it with `lineup-ax`, an
Accessibility driver that clicks, types and drags inside the VM's own session.
The host cursor, keyboard, config and permissions are never touched, so you
never need to ask whether the Mac is free.

Run every command from the repository root:

```sh
V=.agents/skills/verify-lineup/scripts/verify-lineup
```

Before you drive a feature, read [the feature map](features/README.md) and the
matching feature file. It lists every entry point you must cover.

## Setup (once per machine)

```sh
$V setup
```

It installs Tart 2.40.1 (pinned and checksummed) under
`~/.local/share/verify-lineup/` and pulls the macOS 27 image (about 31 GB, once).
It builds the base VM `verify-lineup-base`: SIP off, SSH key login, Accessibility,
input posting and screen capture granted, and the screen-capture reminder
pre-approved. The command is idempotent and prints `base VM ready` when done.
Rerun it after a change bumps `BASE_REVISION`, because `launch` refuses an older base.

## Launch

```sh
$V launch                       # build this checkout, fresh config (Welcome window shows)
$V launch --config FILE         # seed ~/.config/lineup/config.json in the VM first
$V launch --app PATH/Lineup.app # skip the build and install a given bundle
```

Launch builds with `UNIVERSAL=0 Scripts/build-app.sh` (about 2 minutes, log in
`<run>/build.log`). It then clones the base VM (an APFS clone, a few seconds)
and boots it headless. It installs the app to `/Applications/Lineup.app`,
grants Lineup Accessibility, Input Monitoring, input posting and screen capture,
and turns off Sparkle checks. Finally it opens Lineup and waits for its menu-bar item.

Ready means Lineup's status item exists and responds to Accessibility. Launch prints:

```text
ready: RUN_ID=20261016-154424-ecac VM=verify-lineup-20261016-154424-ecac IP=192.168.64.5
evidence: /Users/<you>/.local/state/verify-lineup/runs/20261016-154424-ecac/evidence
```

Each run has its own VM and evidence directory. Commands use the newest open run
of this checkout; pass `--run ID` to `doctor`, `config` or `cleanup` for another.
macOS allows at most two macOS VMs at once. Launch refuses a third, so reuse
your open run or clean one up.

## Doctor

```sh
$V doctor
```

Doctor is read-only. Run it after launch and whenever anything looks off. It
checks that:

- the run is open and its VM process is alive;
- SSH works, and it prints the guest macOS version;
- SIP is off in the guest;
- the guest app binary matches the build this run installed;
- the `lineup` process runs, `lineup-ax` is trusted and Lineup's menu-bar item exists;
- `config.json` parses.

It ends with `doctor: healthy` (exit 0), `doctor: unhealthy` (exit 1) or
`doctor: unknown` (exit 2, the VM or SSH is gone). When it notes
`HEAD moved since launch`, the VM runs an older commit: clean up and launch again.

## Drive

`$V ax ...` runs `lineup-ax` in the VM's logged-in session. Use real UI paths,
the way a user would.

```sh
$V ax tree --scope menubar --depth 12         # what is on screen now
$V ax click role=AXMenuBarItem --scope menubar  # open the Lineup panel
$V ax click role=AXButton desc="Open Settings"
$V ax wait role=AXWindow title="Lineup Settings"
$V ax read role=AXCheckBox desc="Enable Keep Awake"     # prints the value
$V ax raise role=AXWindow title="Lineup Settings"       # bring a covered window forward
$V ax key escape        # also cmd+comma, ctrl+opt+shift+cmd+left, hyper+z
$V ax type Lisbon
$V ax drag --from 1200,40 --to 400,600 --mods shift --steps 30
$V ax tree --app com.apple.TextEdit --scope windows --depth 0   # another app
$V ax find --app system role=AXButton title=Allow               # any app, e.g. alerts
```

Selectors are `role= subrole= title= desc= id= value= name=`. They all must
match, and `~` makes one a case-insensitive substring, as in `desc~=Lisbon`.
`name=` matches the title, description or identifier. `click`, `read` and
`raise` poll for up to 10 seconds until exactly one element matches. They fail
with exit 4 on no match and exit 1 on several; narrow with another selector or
`--index N`. `wait` succeeds on one or more matches. Options: `--app BUNDLE` (default `com.caiano.lineup`; `system` for
every app), `--scope menubar|windows|all`, `--right`, `--press` (AXPress
without a mouse event), `--timeout S`, `--gone` and `--json`. `$V ax help`
prints the full usage.

Prefer accessible names over coordinates. Use coordinates only for drags,
taking them from `tree` frames. The VM screen is 1920x1200 points with its
origin at the top left.

Clicks are real mouse events at the element's center. When another window
covers a window element, `click` refuses with exit 3 and names the app on
top. Run `raise` on the target window first. Key combos press and release
each modifier, as a keyboard does.

## Helpers

- `$V sh 'COMMAND'` runs a shell command in the VM as the logged-in user
  (`pmset -g assertions`, `open -a TextEdit`, `defaults read ...`). Quote it.
- `$V config` prints the VM's `~/.config/lineup/config.json`.
- `$V vnc` prints a `vnc://` URL. Open it in Screen Sharing to watch, or to
  drive by hand when no Accessibility path exists. VNC input stays in the VM.

## Verification control

- Retry a failed case only after code, the driver, a fixture or a precondition
  changed in a way that is relevant to the failure. Rerunning unchanged steps
  is not new evidence.
- Keep passed evidence while its inputs stay valid. Rerun the affected cases
  when the build or the config changes.
- Record the runtime: the run's journal records the commit, the dirty state,
  the app version and the guest macOS. A static check, `swift run lineup-tests`
  or a host build does not prove behavior in the running app.
- When a step fails, run `$V doctor` before changing anything. Run
  `$V cleanup` after every failed attempt, so no VM is left running.
- Drive only VMs this checkout launched. Never drive the host's Lineup with
  `ax`. Outside a VM, `lineup-ax` refuses every event and every Accessibility
  action, `--press` and `raise` included, unless `host-ax` passes a claim (exit 6).

### Host desktop (the one standing rule)

Some journeys need real hardware: an external display with DDC, several
physical displays, the real keyboard's Caps Lock path or Apple's native
on-screen indicators. The feature map tags them `host-only`. Never ask
Henrique whether the Mac is free. This rule replaces that question:

1. `$V host-gate` reads the host's input idle time, lock state and claim
   without changing anything. The gate is open only when no human input has
   happened for 10 minutes, the screen is unlocked and no other run holds the
   desktop.
2. When it is open, `$V host-gate claim HOLDER` takes the desktop, with
   HOLDER set to your PR or thread name. Drive only with
   `$V host-ax --holder HOLDER ARGS...`, which runs `lineup-ax` on the host.
3. Before each event and Accessibility action, `host-ax` compares the host's
   idle time with its own last input, and before each command it checks the
   screen lock. At the first human input or a locked screen, it lifts any key
   or button it holds, stops with exit 7 and releases the claim. Do not retry, refocus a window or poll to take the desktop back.
   Checkpoint the case and continue in the VM.
4. When you finish, or after 30 minutes without input (the claim goes stale),
   run `$V host-gate release HOLDER`. Restore what you changed: quit a test
   build and reopen the installed `/Applications/Lineup.app`.
5. When the gate is closed, keep working. List each host-only journey under
   `Pending host journeys` in the PR, with the exact steps, so Henrique can run
   it in one sitting.

Host runs use Henrique's real config, grants and hotkeys. Change only what the
journey needs, and never during a claim held by someone else. As of
2026-10-16 the host path refuses input correctly but has not driven a journey
yet. Treat its first real use as a proof step.

## Evidence

Everything goes into `~/.local/state/verify-lineup/runs/<RUN_ID>/evidence/`.
An existing name gets a `-2` suffix, and nothing is overwritten.

| Command | Keeps |
|---|---|
| `$V record start NAME` / `$V record stop` | `NAME.mov` (lossless), `NAME.mp4` (H.264, for PRs) |
| `$V shot NAME` | `NAME.png`, the whole VM screen |
| `$V note TEXT` | a line in `journal.md` |
| `$V keep FILE [--as NAME]` | a copy of any file, such as `pmset` output |
| automatic | `journal.md` (launch, commit, version, every capture, cleanup), `seed-config.json` |

**Record every journey you will show.** A PR that changes what users see or do
needs a start-to-finish video:

1. `$V record start <feature>-<journey>` after `doctor` is healthy, before the
   first action.
2. Drive the whole journey through its user entry points. Pause about a second
   after each action, so the result is visible (`sleep 1`).
3. Prove side effects while recording when they show on screen. Prove the
   others right after, with `$V sh`, `$V config` or `$V keep`.
4. `$V record stop`, then `$V shot <feature>-end` for the final state.

Proof standards:

- Use the real user path: the menu-bar item, the panel, Settings, shortcuts
  and drag. Never use `defaults write`, config edits or internal hooks to reach
  a state the journey claims to test. Seeding a starting config with
  `--config` is fine, and the journal records it.
- Capture the action and the resulting state, not only the final screen.
- Verify the side effect next to what is visible: the config value Lineup
  wrote, the power assertion it holds, the window frame it set.
- Report each entry point you could not drive, with the command you tried and
  the reason. Never report a path as verified through a different one.
- Attach the `.mp4` and the key screenshots to the PR. Never commit them.

## Cleanup

```sh
$V cleanup              # every open run of this checkout
$V cleanup --run ID
$V runs                 # list runs and their state
```

Cleanup stops an unfinished recording and keeps it. It then stops and deletes
the run's VM clone and marks the run closed. When the recording cannot be
saved, cleanup leaves that run's VM running and exits 1: check `doctor`, rerun
`cleanup --run ID`, or pass `--discard-recording` to drop it. It never deletes the evidence
directory, the base VM or the image. Check the evidence afterwards with
`ls ~/.local/state/verify-lineup/runs/<RUN_ID>/evidence/`. A closed run's VM is
gone: launch a new run to continue.

## Gotchas

- The VM runs macOS 27 on Apple Virtualization with one virtual display named
  `Apple Virtual` (1920x1200). It has no DDC, native brightness, second display
  or physical keyboard. Display Control shows its no-controls path there, and
  multi-display journeys are host-only.
- The guest has SIP off, so permission grants can be scripted. Permission
  prompts and `TCC` denial paths behave differently from a user's Mac. To test
  denied Accessibility, revoke it in the VM's System Settings and say so.
- A fresh config is a brand-new user and shows the Welcome window. Seed a
  returning user with `--config` and
  [fixtures/returning-user.json](fixtures/returning-user.json) when the journey
  is not about first launch.
- Text Capture and other screen-capture paths still show Lineup's own consent
  alert. That alert is product behavior, so drive it like a user.
- While recording, macOS shows the purple screen-recording indicator in the VM
  menu bar, and the videos include it.
- In zsh, quote key combos that contain `[` or `]`, as in `$V ax key 'ctrl+opt+shift+cmd+['`.
- Each run clone costs little disk, but the base VM and image take about 36 GB.
  Check `df -h ~` before setup on a small disk.
- `scripts/lineup-ax.swift` is compiled per run, so driver changes apply on the next launch.
