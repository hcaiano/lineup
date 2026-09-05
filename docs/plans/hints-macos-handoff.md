# Hints macOS Handoff

Status: implementation-ready after Gate 5; transfer reference and Phase 5 evidence remain pending
Date: 2026-09-04
Companion plan: [hints-integration.md](hints-integration.md)
Target: macOS 13 and the current supported macOS

## Purpose and entry criteria

This document hands implementation work begun on a Linux session over to a new chat on a signed
macOS machine. The Linux session may author production code first, but that is **deferred
validation**, not a passed gate. No feature completion or release readiness may be claimed until
the final signed macOS evidence matrix passes.

Entry criteria, all required before starting macOS work:

1. The Linux-authored `HintsCore` passes `swift build --target HintsCore` and
   `swift run lineup-tests` where supported, or host/toolchain gaps are recorded as blocked in the
   progress log below. Full AppKit compilation remains a macOS entry task.
2. Every platform assumption in the companion plan's Phase 0 section has a recorded safe default
   and a fail-closed path, isolated behind the recorded AX/Input/Presentation owning boundaries.
3. Hints is default-off in the shipped code; no build starts it automatically.
4. The branch or worktree transfers cleanly (checklist below).
5. This document's progress log is current.

## Branch and worktree transfer checklist

- [ ] Confirm the branch or worktree containing all Linux-authored Hints work is pushed or copied
      in full, including `docs/plans/hints-integration.md` and this document.
- [ ] Expect the diff to contain only the files the Linux phases actually changed or created,
      including `docs/plans/hints-integration.md` and this document. Plan-authorized candidates to
      look for: `Sources/HintsCore/**`, `Sources/lineup-tests/HintsSuite.swift` and `main.swift`,
      `Package.swift`, `Sources/lineup/Tools/Hints/**` (`AX`, `Input`, `Presentation`,
      `HintSessionController` and tool files, `HintsSettingsPane.swift`), `Sources/AppCore/ToolID.swift`
      (which **must** show `.hints` appended after Hyperkey), and the integration and documentation
      files those phases authorized (`Sources/lineup/App/AppShell.swift`, `Brand.swift`,
      `StatusItemController.swift`, `Sources/lineup/Settings/Components/ToolIcon.swift`,
      README.md, PRODUCT.md, BUILDING.md, AGENTS.md, docs/hints.md) plus comment-only edits. A file
      that did not change is not expected in the diff.
- [ ] Confirm `Sources/lineup-tests/AppSuite.swift`, `Sources/lineup-tests/HintsSuite.swift`, the
      sibling tool suites, and `Tests/HintsAdapterTests/**` are present and intact. The sibling
      suites were reviewed and kept strict even where they did not appear in the diff, so their
      absence from the diff is not a finding; missing or weakened files are.
- [ ] Protect the actual identity anchors; the bundle ID, hotkey signature, Sparkle feed,
      `Resources/Info.plist`, `web/appcast.xml`, `web/downloads/`, tags, and signing scripts must be
      untouched.
- [ ] On the macOS machine, clone or check out into a clean worktree aimed at the correct commit.
- [ ] Confirm no stale `~/Library/Developer/Xcode/DerivedData` or SPM cache breaks the build; if
      the build fails on caches, clear the cache only.
- [ ] Prepare a dedicated disposable macOS account for manual persistence tests. Never point the
      manual matrix at the maintainer's live `~/.config/lineup/config.json`; line up the
      disposable account before manual work starts.

## Required reading

Before touching code on macOS, read in order:

1. `AGENTS.md` (project contracts, verification loop, manual-launch rules).
2. `PRODUCT.md` (user-visible behavior and design register).
3. `docs/plans/hints-integration.md` (architecture, phases, safe defaults, gates).
4. `BUILDING.md` (build, package, bundle behavior).
5. `CONTRIBUTING.md` (evidence, review gates, merge policy).
6. This document.

## Environments

Run every automated command and manual scenario on both:

- macOS 13, since the target floor is macOS 13.
- The current supported macOS at the time of validation.

A scenario an environment cannot host is recorded as **blocked**, never silently skipped. Record
OS versions, machine model, and display configuration with each result. A behavior that diverges
between the two environments is a finding, not a nuisance.

## Automated commands

Run these first; do not proceed to the manual matrix until they pass:

```sh
swift run lineup-tests
swift build
UNIVERSAL=0 ./Scripts/build-app.sh <explicit-temporary-output-directory>
```

Use an explicit temporary output directory for the app build and discard it (with `trash`) after
evidence collection. The app build is required for signing and permission behavior; tests and
`swift build` are required after every code change.

Do not launch Lineup as routine automated verification. Launch is permitted only inside the
explicit manual matrix below.

## Stable signing caveat

`Scripts/setup-signing.sh` changes the login keychain and requires explicit maintainer intent.
Run it only after the maintainer has asked for it on this machine in this session. Never treat
setting up the stable signing identity as an incidental step of the handoff. Final TCC permission
and permission-matrix evidence requires the app built with the cert-based stable signature at a
fixed app path; ad-hoc or ephemeral signing runs are exploratory only and never satisfy the final
gate. If stable signing is not explicitly authorized on this machine, the final Oracle gate is
**blocked**, and only exploratory runs plus automated commands proceed.

## No release-state changes

Do not change or publish `web/appcast.xml`, `web/downloads/`, tags, release versions, notarization
state, or signing identities under this handoff. Release work is maintainer-directed only.

Every scenario below must run on both macOS 13 and the current supported macOS. An environment
that cannot host a scenario marks that cell **blocked**, never silently skipped. Ad-hoc or
ephemeral-signing runs are exploratory only and their results may not satisfy the final gate. Cells
for permission state, config preservation, teardown completeness, input leakage, and wrong-target
invocation are **non-waivable**: a failure in any of them fails the final gate outright, and scope
narrowing is accepted only after the failing behavior is removed or disabled, the docs are updated,
and the reduced matrix is rerun with maintainer approval.

## Permission state matrix

Exercise Hints under every state and record each cell:

| State | Expected behavior |
|---|---|
| Accessibility denied before enable | warning banner, no side effects, tool stays inert |
| Accessibility granted after denial | granted state detected without restart; next invocation works |
| Accessibility revoked mid-session | immediate fail-closed cancellation; no AX messaging after loss |
| Input Monitoring denied (only if an event tap was approved) | Hints stays on the panel path or cancels; no silent escalation |
| Input Monitoring granted (only if an event tap was approved) | tap exists only during an active session |
| Shortcut conflict with another tool | conflict named correctly; no degraded activation |

## Panels, Carbon, event taps

The frozen safe default is panel-only input. Carbon registers only the assigned global activation
shortcut. No modal Carbon registration, event tap, or Input Monitoring request exists in the
implementation; if one is found in the code, that is a finding and a stop condition.

- [ ] A nonactivating key-capable panel receives keys while the target app stays frontmost.
- [ ] The target app regains its exact context (focus, selection, insertion point) after the
      session ends.
- [ ] Carbon activation shortcut fires while focus is in Login items, Spotlight, Launchpad, and a
      fullscreen Space, and the registered shortcut matches the recorded one exactly.
- [ ] No fallback or secondary input path was silently introduced. (An event tap or modal Carbon
      path only becomes testable if a maintainer-approved future decision reintroduces it; in that
      case apply the recorded requirements: session-only existence, O(1) callback, no AX or
      rendering work in callbacks, synthetic-marker pass-through, Hyperkey coexistence, non-US/IME
      and repeat behavior for modal Carbon.)
- [ ] No automatic or hidden fallback between panel, Carbon, and event tap occurred.

## Secure Input

- [ ] Secure Input active at invocation: session cancels, no label shows a secure field, nothing
      typed is echoed anywhere.
- [ ] Secure Input activated mid-session: cancellation path completes and returns to idle.
- [ ] After cancellation, the system Secure Input state is not left blocked (confirm with
      `ioreg`-based check or Hyperkey's own indicator if available).

## AX actions and staleness

- [ ] Revalidation catches stale elements; invocation on a stale token cancels instead of acting.
- [ ] Every action/focus mutation dispatches **at most once**. A `kAXErrorCannotComplete` outcome is
      never retried; only a fresh observational rescan may follow. Log any observed dispatch count
      above one.
- [ ] Never a remembered-coordinate click; the release performs no pointer synthesis at all (the
      pointer/click allowlist is empty and any synthesized input is a gate-failing finding).
- [ ] `AXPress`, `AXShowMenu`, and settable focus fire exactly as the candidate/action matrix
      defines, against buttons, links, checkboxes, radio buttons, tabs, menu items, popups, and
      editable fields in the application tiers.
- [ ] Menu and popover activation triggers a bounded rescan or safe cancellation under a new
      generation, never an unbounded wait.
- [ ] AX traversal uses typed individual reads within the frozen budgets; if bulk reads appear in
      the implementation, confirm every slot and type is independently validated and that no bulk
      read is treated as a snapshot.
- [ ] Cancel on every path (Escape, repeated shortcut, tool disable, app quit, revocation,
      capture loss, Secure Input, PID/window mismatch, display change, timeout) releases every
      retained AX element; confirm no growth across repeated sessions in a leak-checking run.

## Displays and Spaces

- [ ] One display: labels land on the correct controls.
- [ ] Two displays: each overlay covers its own display; nothing straddles incorrectly.
- [ ] Negative-origin secondary display: clamping and placement correct.
- [ ] Retina scaling: label frames map to window coordinates correctly.
- [ ] Display attach/remove during a session: fail-closed cancellation or bounded rescan.
- [ ] Fullscreen Space: capture and activation work as recorded in the Phase 0 decision.
- [ ] Straddling window across displays: dedupe and label placement remain deterministic.
- [ ] Notched and differently sized displays: labels clamp inside safe areas.

## Cross-tool interaction

- [ ] Hyperkey on and off; trigger through the Hyperkey composition key behaves as recorded.
- [ ] Zones drag-snap and layout-editor activity during a Hints session do not deadlock either
      tool.
- [ ] Cycler HUD activation does not collide with Hints panels or hotkeys.
- [ ] Settings shortcut recorder open prevents Hints activation, and Hints shortcut recording
      prevents Hints invocation on the recorded combo.

## Persistence

Manual persistence scenarios run in the dedicated disposable macOS account prepared during the
transfer checklist, never against the maintainer's live config.

- [ ] Checksum `~/.config/lineup/zones.json` and `~/.config/cycler/bindings.json` before and after
      every manual persistent-setting run; the checksums must not change.
- [ ] Fresh config: Hints section seeds default-off with no assigned activation shortcut.
- [ ] Current config with Hints enabled: settings round-trip without envelope-schema change.
- [ ] Malformed `tools.hints`: decode fails, Hints runs no side effects, the rejected section is
      preserved, sibling tools remain operational, Hints-specific writes are blocked.
- [ ] Newer schema: unknown keys preserved.
- [ ] Legacy imports continue creating only Zones/Cycler/Hyperkey sections and never write to
      `~/.config/lineup/zones.json` or `~/.config/cycler/bindings.json`.
- [ ] A failed load blocks writes; normal writes stay atomic.
- [ ] If a Hints reset path exists in the implementation: it preserves the rejected Hints bytes
      before replacement and aborts the reset if preservation fails. If no reset path exists, note
      its omission from scope explicitly.

## Performance

Record p50 and p95 for each metric in the companion plan's performance table, plus the hard
deadlines, on both OS environments:

- [ ] Activation callback work, scanning indicator, labels available, large-surface response.
- [ ] Filter/search redraw and overlay redraw on a dense scene.
- [ ] Idle cost: no polling, tap, overlays, or retained AX elements between sessions.
- [ ] Truncation path: highest-ranked partial result with count-only status under the scan
      deadline.

## Visual evidence

Screenshots and videos are PR evidence and must **not** be committed to the repository. Collect
them into an approved external evidence location per `CONTRIBUTING.md` and reference them from
the pull request description only.

Capture before/after screenshots and a short keyboard-flow recording covering:

- [ ] Activation through the shortcut on a native app and a browser.
- [ ] Filtering by label and by accessible-name search.
- [ ] Invocation of a press action and a menu action, followed by the rescan.
- [ ] Nested scroll-region navigation with key repeat.
- [ ] Cancellation from presentation and from mid-invocation.
- [ ] A failure or partial-result state (no matches, truncation, revocation).
- [ ] Light/dark appearance, increased contrast, Reduce Motion, dense overlap, and clamping.

## Result fields

For every scenario above, record exactly these fields:

- `scenario`: the checklist item name.
- `environment`: OS version, machine, display setup.
- `result`: pass / fail / blocked / partial.
- `evidence`: pointer to the external screenshot, video, or log (never a committed binary).
- `notes`: numbers that matter (timings, counts, error codes), or the reason for a block.
- `remediation_owner`: the owning lane (see remediation routing) if a repair is needed.

Summarize the counts at the end: passed, failed, blocked, partial, and open repairs.

## Stop and fail-closed conditions

Stop work and record the decision before continuing when any of these occur:

1. The nonactivating panel cannot reliably capture keys with the target app frontmost. Stop and
   record the decision; do not invent a third global-input owner, and do not introduce an event
   tap or modal Carbon path without a separate maintainer-approved decision.
2. Panel capture fails materially and any secondary input path (event tap or modal Carbon) was not
   approved by a maintainer decision; never invent a third global-input owner, and any found
   unauthorized input path is itself a stop condition.
3. Safe invocation of an advertised AX action cannot be proven; the pointer/click allowlist is
   empty, guessing from remembered coordinates is never acceptable, and synthesized pointer input
   in the code is a stop condition.
4. AX latency forces raising timeouts past the recorded budgets until Lineup stalls; revisit
   candidate scope instead with maintainer approval.
5. Provenance for adapted MIT code cannot be established; rewrite it or omit it.
6. Accessibility revocation (or any permission loss, should a future decision add a permission)
   produces any side effect after revocation.
7. A config contract from `AGENTS.md` is violated by current code: failed load must block writes,
   reset must preserve rejected bytes and abort if preservation fails, and writes stay atomic.
8. Behavior cannot be reproduced to spec on macOS 13 versus current macOS; do not ship a matrix
   result that is known-divergent.

In every case Hints must fail closed: cancel, release everything retained, and leave the system
in the state the user had before the session.

## Remediation routing

Send each defect back to the owning lane's scope; do not widen scopes to make fixes easy:

- Label, filter, ranking, geometry, reducer, budgets: Phase 1 core owner
  (`Sources/HintsCore/**`, `Sources/lineup-tests/HintsSuite.swift`).
- AX traversal, staleness, and advertised actions: Phase 2A owner
  (`Sources/lineup/Tools/Hints/AX/**`).
- Overlay and visual behavior: Phase 2B owner, route visual changes through `@designer`.
- Capture, Carbon, event tap, modifiers: Phase 2C owner (`Sources/lineup/Tools/Hints/Input/**`).
- Session orchestration, lifecycle, menu, warnings: Phase 3 lifecycle owner.
- Settings pane and copy: Phase 3 Settings owner, route design through `@designer`.
- Registration, suites, source scans: the Phase 4 integration owner, one writer only.
- Documentation drift: the Phase 4 documentation lane.
- Contract conflicts (`AGENTS.md`, identity, config, release state): escalate to the maintainer
  before continuing.

## Oracle final gate

The Phase 5 Oracle gate is the only gate that can support a release-readiness claim. It passes
only when: `swift run lineup-tests`, `swift build`, and the host-architecture app build pass on
macOS before any manual test; every matrix cell is pass on both macOS 13 and the current supported
macOS, with nothing silently skipped (unavailable environments are blocked); each Phase 0 safe
default is confirmed or its remediation is complete; performance budgets are met; TCC and
permission evidence comes from the cert-based stable signature at a fixed app path, ad-hoc runs
never qualify, and without explicit stable-signing authorization the gate is blocked; the
non-waivable cells (permission state, config preservation, teardown completeness, input leakage,
wrong-target invocation) all pass outright; visual evidence is collected externally; and the counts
in the result-fields summary show zero open failures or blocks. A passing check is verification,
not merge approval; only the maintainer approves and merges.

## Progress log

Append dated entries here as work happens.

### 2026-09-04 - Linux authoring transfer

- Oracle Gates 1 through 5 passed. The first Gate 5 review found menu-discovery and documentation
  blockers; remediation added a truthful `Hints (Off)…` menu route directly to Hints Settings and
  aligned the public support contract with the implemented AX candidate/action matrix.
- Phase 4 added stable `ToolID.hints` last, registered Hints fourth, preserved default-off seeding,
  completed shared menu/Settings metadata, retained the three-tile Welcome exclusion, strengthened
  config/permission/registration/source scans, and documented the support and privacy contract.
- Clean-room attestation: `docs/hints.md` records that no source was adapted from Hinto, Keyouse, or
  another third-party implementation. No Hints notice or build-script change is required.
- Docker Swift 5.10 evidence on the reconciled tree: package dump passed; HintsCore build passed;
  the actual HintsCore + minimal AppCore bridge + actual HintsSuite passed **314 checks**; changed
  Phase 4 Swift files passed parse-only validation; `git diff --check` passed.
- The full `swift run lineup-tests` attempt is blocked on Linux by the existing unavailable
  `CoreGraphics` module in `Sources/ZonesCore/Cycle.swift`, not by Hints.
- The macOS-only adapter inventory is **70 source-reviewed XCTest methods**: 28 lifecycle tests and
  42 AX/Input/Presentation tests. They have not been compiled or run.
- No app target, app bundle, signed TCC path, visual state, performance matrix, or runtime behavior
  was validated on Linux. Every manual and macOS command below remains required.

### 2026-09-05 - Gate 5 closure and transfer state

- Oracle Gate 5 passed. Phase 5 may open; this is implementation readiness, not release readiness.
- Repository: `git@github.com:hcaiano/lineup.git`; branch: `gustavocaiano/hints`; current base commit:
  `9093a1db3ccd6752fe077bc57b1e5eb8c3a55293`.
- The Hints implementation is still an uncommitted working-tree diff with untracked source/test/doc
  files. Checking out the base commit alone will not transfer it. Before starting macOS work, create
  and verify a transferable commit/ref or copy the complete worktree, then replace the placeholders
  in the prompt below with that resulting reference.
- No session-only `.slim`, `.ignore`, or `.gitignore` change remains in the transfer.

## New chat resumption prompt

Use this as the opening message in a fresh macOS chat:

```text
Repo: git@github.com:hcaiano/lineup.git
Branch/worktree: gustavocaiano/hints
Transfer ref: <commit containing the complete Hints working tree, or verified full-worktree copy>

Do not check out base commit 9093a1db3ccd6752fe077bc57b1e5eb8c3a55293 by itself: the Linux-authored
Hints implementation was still uncommitted when this handoff was finalized. Confirm every expected
file in the transfer checklist before running validation.

Read these, in order: AGENTS.md, PRODUCT.md, docs/plans/hints-integration.md,
docs/plans/hints-macos-handoff.md (this handoff governs your work), BUILDING.md,
CONTRIBUTING.md.

Context: Hints (a fourth Lineup tool) implementation was authored on Linux without any macOS
runtime validation. It is default-off with its frozen safe defaults recorded in the plan's
assumption register: panel-only input with Accessibility only, Carbon for the activation shortcut
only, no event tap or Input Monitoring path, no pointer synthesis, and at-most-once dispatch.
Linux evidence is recorded in this handoff's progress log: package dump and HintsCore build passed,
the isolated Hints suite passed 314 checks, and 70 adapter XCTest methods remain source-only.
The signed macOS validation was deferred to Phase 5 and has NOT run. Do not claim feature
completion or release readiness.

Your job: execute Phase 5 stabilization and evidence per the handoff. Start with
`swift run lineup-tests` and `swift build`, then the host-architecture app build to an explicit
temporary output directory, then the handoff's manual checklists (permission matrix, panel and
Carbon, Secure Input, AX staleness, displays and Spaces, cross-tool, persistence, performance,
visual evidence). Record every result in the handoff's result-fields format and append to its
progress log. Do not run Scripts/setup-signing.sh without explicit maintainer intent. Do not
change release state. Screenshots and videos are external PR evidence; never commit them. On any
stop condition in the handoff, halt, record, and fail closed.
```
