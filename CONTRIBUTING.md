# Contributing to Lineup

Thank you for helping improve Lineup. Focused fixes are easier to review and safer for an app that
controls windows, global shortcuts, and keyboard input.

## Before you start

- Search the existing [issues](https://github.com/hcaiano/lineup/issues) and
  [discussions](https://github.com/hcaiano/lineup/discussions).
- Use an issue for a reproducible bug.
- Start a discussion before a new feature, a behavior change, or a large refactor.
- Review [LICENSE](LICENSE) before you use or redistribute the source.

By submitting a contribution, you confirm that you have the right to submit it and agree to license
it under the [Apache License 2.0](LICENSE).

Good first contributions include focused bug fixes, reliability or accessibility improvements,
tests, and documentation. Changes to signing, notarization, Sparkle, hosted downloads, or deployment
need maintainer agreement before work starts.

## Set up the project

You need macOS 13 or later and Xcode Command Line Tools. Full Xcode is optional.

```sh
xcode-select --install
git clone https://github.com/hcaiano/lineup.git
cd lineup
swift build
swift run lineup-tests
```

The test runner does not use XCTest. It works with Command Line Tools alone. See
[BUILDING.md](BUILDING.md) when you need to assemble and run `Lineup.app` with a stable local
signature.

## Make a change

1. Create a branch from `main`.
2. Keep the change to one problem.
3. Put deterministic logic in a core module when possible. Keep AppKit, SwiftUI, Accessibility, and
   other system effects in `Sources/lineup`.
4. Add a regression check or focused behavior checks in `Sources/lineup-tests`.
5. Update the document that owns any changed behavior.

If you use a coding agent, [AGENTS.md](AGENTS.md) gives it the project contracts, code map, and
verification rules. `CLAUDE.md` imports the same source for Claude Code.

## Verify the change

Run both commands before you open a pull request:

```sh
swift build
swift run lineup-tests
```

If you changed packaging or bundle resources, also assemble a host-architecture app:

```sh
UNIVERSAL=0 ./Scripts/build-app.sh <output-directory>
```

## Provide visual evidence

For every user-visible change:

- Add before and after screenshots of the affected state.
- Add a short video when the change involves motion, timing, drag behavior, keyboard input, or a
  sequence of interactions.
- Use real app states and keep the before and after captures comparable.
- Upload review evidence to the pull request. Do not commit review-only media to the repository.
- Explain why visual evidence does not apply when the change has no visible effect.

## Open a pull request

- Use a clear conventional title, for example `fix(cycler): skip closed windows`.
- Explain the problem, the change, and how you verified it.
- Keep unrelated work in separate pull requests.
- Call out config migrations, new permissions, shortcut changes, or release impact.
- Do not commit local config, credentials, signing material, build output, or agent scratch files.

A pull request is ready for review when its scope is clear, the required checks pass, and the visual
evidence is present when applicable.

## Review and merge

- Every change to `main` goes through a pull request.
- Passing checks do not authorize a merge.
- Henrique (`@hcaiano`) is the required reviewer and the only person who merges pull requests.
- New commits after approval require a new review.
- Resolve every review conversation before merge.
- Opening a pull request does not guarantee review or merge.
