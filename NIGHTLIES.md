# Automatic Nightlies

`Scripts/nightly-service.py` runs on the trusted release Mac. It polls `main` every five minutes,
then publishes app-changing commits whose **push** run of `ci.yml` passed on that exact SHA.
Stable releases remain manual. No GitHub-hosted or self-hosted Actions runner gets the Sparkle key.

## What gets published

- Each qualifying first-parent commit after activation gets its own immutable GitHub prerelease,
  universal Developer ID-signed and notarized DMG, and signed Nightly item in the existing feed.
- Changes confined to documentation, tests, the website, or the publisher itself do not create app
  releases. App sources, resources, Swift package inputs and app packaging scripts do.
- Pending CI waits. Failed or cancelled CI waits for a rerun, unless a later app-changing commit
  has passed and includes those changes. Commits already superseded by a public Stable release
  are skipped. Initialization starts at current `main`; it never publishes the historical backlog.
- Only users who selected Nightly receive these updates. Stable keeps its current behavior.
  Publication makes the update available; it does not force an immediate installation.
- Generated GitHub release notes are rendered as HTML through GitHub's Markdown API before
  publication and inlined in the feed. The update window shows headings, lists and clickable
  links, with long URLs wrapping to its width. The internal source marker stays in the GitHub
  release body and is excluded from the update window. If rendering fails, the job retries
  before creating or publishing the release.

The service does not commit or push to `main`, merge PRs, change app preferences, install Lineup,
or launch the app. The version planner, clean source snapshots, signing, notarization and appcast
verification reuse the existing release scripts. The installed publisher is a fixed copy: updating
it requires stopping the service and reviewing/reinstalling that copy.

## One-time activation

Use **one** trusted Mac and the same logged-in macOS account for automatic Nightlies and manual
Stable/site publication. The Mac needs full Xcode, Python 3, Git, `gh`, Node/npm, `trash`, the
existing Developer ID identity for team `HJ9R8572WN`, the `lineup-notary` Keychain profile, the
existing Sparkle key and an authenticated Wrangler user session. Keep these credentials on the
Mac. No new key or permission grant is created by the service.

Before activation, enable GitHub immutable releases for `hcaiano/lineup`. The service checks the
live setting before building and verifies `immutable=true` on every published Nightly. It never
weakens this requirement. GitHub's publication order is draft → attach DMG → publish; the public
artifact cannot then be replaced.

From a reviewed checkout containing the service:

```sh
python3 Scripts/nightly-service.py init
python3 Scripts/nightly-service.py run             # read-only remote inspection; no publication
python3 Scripts/nightly-service.py install         # writes the LaunchAgent, but does not start it
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.caiano.lineup.nightly.plist"
```

`init` creates `~/Library/Application Support/Lineup Nightly` with private permissions and a
dedicated clone. It refuses an existing state directory. `install` refuses an existing LaunchAgent.
Neither command enables immutable releases or changes repository settings. Review and explicitly
authorize activation before running the last command: it enables future unattended publication.

The LaunchAgent captures the current executable search path and Python interpreter. It defaults to
full Xcode at `/Applications/Xcode.app/Contents/Developer`; set `DEVELOPER_DIR` when installing if
Xcode lives elsewhere. Do not put secrets in the plist. The agent runs only while this account is
logged in, the Mac is awake and credentials remain usable. It catches up after sleep or a network
outage. There is no promise of a fixed release latency; Apple notarization can take time.

For a supervised publication using the same state and lock:

```sh
python3 Scripts/nightly-service.py run --publish
```

## Recovery and visibility

State, notarized artifacts, generated notes and per-commit checkpoints live under the service's
private state directory. The kernel lock serializes builds and publication, and is released even
if the process crashes. A response lost after creating a draft, uploading its DMG, publishing it,
or deploying the feed can be retried without creating another release or rebuilding the saved DMG.
An existing mismatched tag, release, asset digest or source commit stops publication.

Logs are in `~/Library/Application Support/Lineup Nightly/logs/`. `state.json` records the last
completed/skipped commit. `jobs/<sha>/job.json` records work in progress. A failure leaves the
cursor unchanged, prints an error and retries on the next invocation. The cursor advances only
after the public feed has been read back and verified. Do not delete checkpoints to clear errors:
inspect the log and fix the reported condition first. If Stable advances during a build, the old
Nightly is not advertised; its release/checkpoint remain available for inspection.

Stop without deleting artifacts or keys:

```sh
launchctl bootout "gui/$(id -u)/com.caiano.lineup.nightly"
```

The service retains job worktrees, artifacts and staged deployments for recovery. Inspect disk use
periodically. There is no automatic destructive cleanup or keychain modification.

## Stable and website publication

Nightly feed entries are deployment state, not automatic commits to `main`. **All** publications
must use the same Mac, state directory and publisher lock. After preparing a Stable feed with
`sparkle-appcast.sh`, or changing the website, publish through:

```sh
python3 Scripts/nightly-service.py publish-web web
```

This replaces a direct `npx wrangler deploy` once the service is activated. It stages a copy of the
website, merges in the current public feed, preserves every existing signed enclosure and checks
that all hosted downloads and release notes still exist with the expected file lengths. New
Nightly notes are inlined, so a later checkout cannot remove their linked notes file. Changed
bytes under an already-published build number are rejected. A feed change during staging aborts
the deployment instead of overwriting it. Stable version bumps, approval, signing and notarization
remain the maintainer's existing manual process in `BUILDING.md`.

Do not enable the dormant GitHub web-deploy workflow or deploy from another Mac while this service
is active: neither participates in its local publication lock. Keep historical Stable downloads
in `web/downloads/`. A missing download blocks deployment rather than removing it from the feed.

## Validation

`swift run lineup-tests` includes the Python standard-library publication tests. They use isolated
temporary files and simulated GitHub/Cloudflare responses: exact-commit CI selection, publication
filtering, retry after external mutations, tag/artifact ownership, immutable-release enforcement,
exclusive locking, feed preservation, formatted release notes and rendering failures, stale
Nightlies and missing hosted assets. These tests do not contact GitHub, access Keychain, notarize,
deploy, or launch Lineup. A real first Nightly still
needs supervised end-to-end verification after activation is authorized.
