#!/usr/bin/env python3
"""Trusted release-Mac poller. No credentials leave the logged-in user's Mac."""
import argparse
import contextlib
import copy
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

REPOSITORY = "hcaiano/lineup"
REMOTE = "https://github.com/" + REPOSITORY + ".git"
SITE = "https://lineup.caiano.com"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
LABEL = "com.caiano.lineup.nightly"
DEFAULT_STATE = Path.home() / "Library/Application Support/Lineup Nightly"
ET.register_namespace("sparkle", SPARKLE[1:-1])
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def command(*args, cwd=None, env=None, timeout=None):
    try:
        result = subprocess.run([str(a) for a in args], cwd=cwd, env=env, timeout=timeout,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"{args[0]} timed out after {timeout} seconds") from error
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def api(endpoint, *args):
    return json.loads(command("gh", "api", endpoint, *args))


def atomic_json(path, value):
    temporary = path.with_suffix(".pending")
    with temporary.open("w") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


@contextlib.contextmanager
def publication_lock(state):
    # The kernel releases this lock on exit/crash. Never delete a PID lock to recover.
    with (state / "publisher.lock").open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("another release or website publication is running")
        yield


def affects_app(paths):
    return any(p in {"Package.swift", "Package.resolved"}
               or p.startswith(("Sources/", "Resources/"))
               or p in {"Scripts/build-app.sh", "Scripts/make-dmg.sh", "Scripts/notarize.sh"}
               for p in paths if not p.startswith("Sources/lineup-tests/"))


def ci_result(runs, sha):
    matching = [r for r in runs if r.get("head_sha") == sha
                and r.get("head_branch") == "main" and r.get("event") == "push"
                and r.get("path") == ".github/workflows/ci.yml"]
    if not matching:
        return "waiting"
    latest = max(matching, key=lambda r: (r["id"], r.get("run_attempt", 1)))
    if latest["status"] != "completed":
        return "waiting"
    return "passed" if latest.get("conclusion") == "success" else "failed"


def feed_items(data):
    root = ET.fromstring(data)
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        raise RuntimeError("expected an RSS update feed")
    items = {}
    for item in channel.findall("item"):
        key = item.findtext(SPARKLE + "version")
        enclosure = item.find("enclosure")
        if not key or enclosure is None or key in items:
            raise RuntimeError("missing or duplicate appcast version/enclosure")
        if not enclosure.get("url") or not enclosure.get(SPARKLE + "edSignature"):
            raise RuntimeError("unsigned or incomplete appcast entry")
        items[key] = item
    if not items:
        raise RuntimeError("refusing an empty update feed")
    return root, items


def item_identity(item):
    return (item.findtext(SPARKLE + "shortVersionString"),
            item.findtext(SPARKLE + "channel", "stable"),
            dict(item.find("enclosure").attrib))


def nightly_order(build):
    match = re.fullmatch(r"([1-9]\d{0,3})\.(\d{2})\.(\d{2})a(\d{3})", build)
    if not match or not 1 <= int(match[4]) <= 255:
        raise RuntimeError("invalid Nightly build: " + build)
    return tuple(map(int, match.groups()))


def merge_feed(published, proposed):
    """Preserve published entries, and reject replacement or a late older Nightly."""
    root, live = feed_items(published)
    _, additions = feed_items(proposed)
    newest = max((nightly_order(k) for k, v in live.items()
                  if v.findtext(SPARKLE + "channel") == "nightly"), default=None)
    channel = root.find("channel")
    for build, item in additions.items():
        if build in live:
            if item_identity(item) != item_identity(live[build]):
                raise RuntimeError("published build would be replaced: " + build)
            continue
        if item.findtext(SPARKLE + "channel") == "nightly":
            if newest is not None and nightly_order(build) <= newest:
                raise RuntimeError("a newer Nightly is already published")
        channel.insert(0, copy.deepcopy(item))
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def validate_hosted_assets(feed, web):
    from urllib.parse import unquote, urlparse
    _, items = feed_items(feed)
    for item in items.values():
        enclosure = item.find("enclosure")
        url = enclosure.get("url")
        if url.startswith(SITE + "/"):
            relative = unquote(urlparse(url).path).lstrip("/")
            asset = (web / relative).resolve()
            if web.resolve() not in asset.parents or not asset.is_file():
                raise RuntimeError("deployment would remove hosted asset: " + relative)
            if asset.stat().st_size != int(enclosure.get("length", "-1")):
                raise RuntimeError("hosted asset length differs: " + relative)
        notes = item.findtext(SPARKLE + "releaseNotesLink", "")
        if notes.startswith(SITE + "/"):
            relative = unquote(urlparse(notes).path).lstrip("/")
            asset = web / (relative + ".html")
            if web.resolve() not in asset.resolve().parents or not asset.is_file():
                raise RuntimeError("deployment would remove release notes: " + relative)


def public_feed():
    # Use the updater's user agent; do not accept challenge HTML as an empty feed.
    data = command("curl", "--fail", "--location", "--silent", "--show-error",
                   "--max-time", "30", "-A", "Lineup/NightlyPublisher Sparkle/2",
                   SITE + "/appcast.xml?publication=" + str(time.time_ns())).encode()
    feed_items(data)
    return data


def deploy_web(state, web, proposed):
    """Caller holds the one Mac-wide lock, for both Stable and Nightly deploys."""
    published = public_feed()
    merged = merge_feed(published, proposed)
    validate_hosted_assets(merged, web)
    # Keep the caller's source checkout clean. Keep failed stages for diagnosis.
    stage = state / "deployments" / str(time.time_ns())
    shutil.copytree(web, stage)
    (stage / "appcast.xml").write_bytes(merged)
    if public_feed() != published:
        raise RuntimeError("public feed changed while staging; retry with the new feed")
    command("npx", "--yes", "wrangler@4.127.1", "deploy", cwd=stage)
    expected = feed_items(merged)[1]
    for attempt in range(6):
        actual = feed_items(public_feed())[1]
        if all(k in actual and item_identity(v) == item_identity(actual[k])
               for k, v in expected.items()):
            print("PASS: public feed contains every staged update", flush=True)
            return
        time.sleep(10)
    raise RuntimeError("deployment returned but the public feed was not verified")


class Service:
    def __init__(self, state):
        self.state = state
        self.config_path = state / "state.json"
        self.config = json.loads(self.config_path.read_text())
        self.repo = state / "repository"
        if command("git", "remote", "get-url", "origin", cwd=self.repo) != REMOTE:
            raise RuntimeError("release checkout is not the canonical repository")

    def fetch(self):
        command("git", "fetch", "origin", "main", cwd=self.repo)
        head = command("git", "rev-parse", "origin/main", cwd=self.repo)
        command("git", "merge-base", "--is-ancestor", self.config["cursor"], head, cwd=self.repo)
        return head

    def ci(self, sha):
        runs = api(f"repos/{REPOSITORY}/actions/workflows/ci.yml/runs?event=push&branch=main&head_sha={sha}")
        return ci_result(runs["workflow_runs"], sha)

    def advance(self, sha, reason):
        print(sha + ": " + reason, flush=True)
        self.config["cursor"] = sha
        self.config["last_result"] = reason
        atomic_json(self.config_path, self.config)

    def checkpoint(self, job, value):
        atomic_json(job / "job.json", value)

    def release_for_tag(self, tag):
        # The by-tag endpoint is for published releases. Drafts need the owner-visible list.
        pages = api(f"repos/{REPOSITORY}/releases?per_page=100", "--paginate", "--slurp")
        matches = [r for page in pages for r in page if r["tag_name"] == tag]
        if len(matches) > 1:
            raise RuntimeError("multiple releases exist for the planned tag")
        return matches[0] if matches else None

    def source(self, job, sha):
        source = job / "source"
        if not source.exists():
            command("git", "worktree", "add", "--detach", source, sha, cwd=self.repo)
        if command("git", "rev-parse", "HEAD", cwd=source) != sha:
            raise RuntimeError("job source HEAD changed")
        return source

    def run(self, publish=False):
        head = self.fetch()
        commits = command("git", "rev-list", "--first-parent", "--reverse",
                          self.config["cursor"] + ".." + head, cwd=self.repo).splitlines()
        if not commits:
            print("No new main commits.")
        for sha in commits:
            paths = command("git", "diff", "--name-only", sha + "^", sha, cwd=self.repo).splitlines()
            if not affects_app(paths):
                if publish:
                    self.advance(sha, "skipped: no app or packaging changes")
                else:
                    print(sha + ": skip (no app or packaging changes)")
                continue
            result = self.ci(sha)
            print(sha + ": CI " + result, flush=True)
            if result == "waiting":
                break
            if result == "failed":
                # Don't permanently skip a red/cancelled commit: a CI rerun can recover it.
                # A later green app commit includes it and may supersede it.
                later = [c for c in commits[commits.index(sha) + 1:]
                         if affects_app(command("git", "diff", "--name-only", c + "^", c,
                                                cwd=self.repo).splitlines()) and self.ci(c) == "passed"]
                if not later:
                    break
                if publish:
                    self.advance(sha, "skipped: unsuccessful CI, covered by a later green commit")
                continue
            if not publish:
                continue
            source_plist = plistlib.loads(command("git", "show", sha + ":Resources/Info.plist", cwd=self.repo).encode())
            stable = api(f"repos/{REPOSITORY}/releases/latest")
            stable_tag = stable["tag_name"]
            if not re.fullmatch(r"v\d+\.\d+\.\d+", stable_tag) or stable["prerelease"] or stable["draft"]:
                raise RuntimeError("latest release is not a public Stable version")
            source_version = tuple(map(int, source_plist["CFBundleShortVersionString"].split(".")))
            if source_version < tuple(map(int, stable_tag[1:].split("."))):
                self.advance(sha, "skipped: already superseded by Stable " + stable_tag)
                continue
            self.release(sha)
            self.advance(sha, "published and verified")

    def release(self, sha):
        if self.ci(sha) != "passed":
            raise RuntimeError("source CI is no longer successful")
        if not api(f"repos/{REPOSITORY}/immutable-releases").get("enabled"):
            raise RuntimeError("enable GitHub immutable releases before publishing Nightlies")
        if api("user")["login"] != "hcaiano":
            raise RuntimeError("publication requires the maintainer's logged-in GitHub account")
        job = self.state / "jobs" / sha
        job.mkdir(parents=True, exist_ok=True)
        source = self.source(job, sha)
        checkpoint = job / "job.json"
        if checkpoint.exists():
            record = json.loads(checkpoint.read_text())
            if record["sha"] != sha:
                raise RuntimeError("checkpoint belongs to another commit")
        else:
            plan = dict(line.split("=", 1) for line in command(
                "bash", source / "Scripts/nightly-release.sh", cwd=source).splitlines())
            if plan["source_sha"] != sha or plan["repository"] != REPOSITORY:
                raise RuntimeError("Nightly plan does not match the source")
            record = {"sha": sha, "plan": plan, "phase": "planned"}
            self.checkpoint(job, record)
        plan = record["plan"]
        dmg = job / plan["asset_name"]
        if record["phase"] == "planned":
            print("Building " + plan["tag"], flush=True)
            output = job / "build"
            if output.exists():
                command("trash", output)
            env = dict(os.environ, LINEUP_BUILD_CHANNEL="nightly", LINEUP_VERSION=plan["next_patch"],
                       LINEUP_BUILD_VERSION=plan["bundle_version"], REQUIRE_DEVELOPER_ID_SIGNATURE="1",
                       UNIVERSAL="1")
            env.pop("LINEUP_ALLOW_DIRTY", None)
            command("bash", source / "Scripts/build-app.sh", output, cwd=source, env=env)
            signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(output / "Lineup.app")],
                                       text=True, capture_output=True, check=True)
            if "TeamIdentifier=HJ9R8572WN" not in signature.stderr.splitlines():
                raise RuntimeError("built app does not use Lineup's Developer ID team")
            command("bash", source / "Scripts/notarize.sh", output / "Lineup.app", cwd=source)
            command("bash", source / "Scripts/make-dmg.sh", output, cwd=source)
            built_dmg = output / ("Lineup-" + plan["next_patch"] + ".dmg")
            command("bash", source / "Scripts/notarize.sh", built_dmg, cwd=source)
            os.replace(built_dmg, dmg)
            record.update(phase="built", digest=hashlib.sha256(dmg.read_bytes()).hexdigest())
            self.checkpoint(job, record)
        if hashlib.sha256(dmg.read_bytes()).hexdigest() != record["digest"]:
            raise RuntimeError("saved notarized artifact changed; refusing to resume")
        notes = job / "notes.md"
        marker = "<!-- lineup-nightly-source: " + sha + " -->"
        if not notes.exists():
            generated = api(f"repos/{REPOSITORY}/releases/generate-notes", "-f", "tag_name=" + plan["tag"],
                            "-f", "target_commitish=" + sha)
            notes.write_text(generated["body"] + "\n\n" + marker + "\n")
        # Sparkle displays HTML. Render GitHub's Markdown before any release mutation,
        # excluding the ownership marker that must remain in the GitHub release body.
        rendered_notes = command("gh", "api", "markdown", "-H", "Accept: text/html",
                                 "-f", "mode=gfm", "-f", "context=" + REPOSITORY,
                                 "-f", "text=" + notes.read_text().split(marker)[0].strip(), timeout=300)
        notes_html = ("<style>body { font-family: -apple-system, sans-serif; "
                      "overflow-wrap: anywhere; }</style>\n" + rendered_notes)
        existing = self.release_for_tag(plan["tag"])
        if self.ci(sha) != "passed":
            raise RuntimeError("source CI changed before release publication")
        refs = command("git", "ls-remote", "--tags", "origin", "refs/tags/" + plan["tag"],
                       "refs/tags/" + plan["tag"] + "^{}", cwd=self.repo).splitlines()
        if refs:
            resolved = dict(line.split()[::-1] for line in refs)
            tag_sha = resolved.get("refs/tags/" + plan["tag"] + "^{}", resolved.get("refs/tags/" + plan["tag"]))
            if tag_sha != sha:
                raise RuntimeError("existing release tag points at another source commit")
        if existing is None:
            command("gh", "release", "create", plan["tag"], "--repo", REPOSITORY,
                    "--draft", "--prerelease", "--target", sha, "--title", "Lineup " + plan["version"],
                    "--notes-file", notes)
            existing = self.release_for_tag(plan["tag"])
            if existing is None:
                raise RuntimeError("created draft is not visible yet; retry after GitHub responds")
        if (marker not in (existing.get("body") or "") or not existing["prerelease"]
                or (existing["draft"] and existing["target_commitish"] != sha)):
            raise RuntimeError("existing release is not owned by this source checkpoint")
        assets = [a for a in existing["assets"] if a["name"] == plan["asset_name"]]
        if assets:
            if len(assets) != 1 or assets[0].get("digest") != "sha256:" + record["digest"]:
                raise RuntimeError("existing release asset differs; it will not be overwritten")
        elif existing["draft"]:
            command("gh", "release", "upload", plan["tag"], dmg, "--repo", REPOSITORY)
        else:
            raise RuntimeError("published release lacks its artifact")
        if existing["draft"]:
            command("gh", "release", "edit", plan["tag"], "--repo", REPOSITORY,
                    "--draft=false", "--prerelease", "--latest=false")
        command("bash", source / "Scripts/nightly-release.sh", "--verify", plan["tag"],
                "--expected-source-sha", sha, cwd=source)
        record["phase"] = "released"
        self.checkpoint(job, record)
        # A new Stable can make this Nightly obsolete while notarization is in progress.
        head = self.fetch()
        current_plist = plistlib.loads(command("git", "show", head + ":Resources/Info.plist", cwd=self.repo).encode())
        if str(current_plist["CFBundleVersion"]) != plan["stable_build"]:
            raise RuntimeError("Stable advanced during this job; inspect the checkpoint before resuming")
        command("bash", source / "Scripts/sparkle-appcast.sh", "--nightly", dmg,
                plan["asset_url"], plan["version"], plan["bundle_version"], cwd=source)
        root, items = feed_items((source / "web/appcast.xml").read_bytes())
        item = items[plan["bundle_version"]]
        description = item.find("description")
        if description is None:
            description = ET.SubElement(item, "description")
        description.text = notes_html
        candidate = ET.tostring(root, encoding="utf-8", xml_declaration=True)
        (job / "appcast.xml").write_bytes(candidate)
        # Stage the current site's files, not an older queued app commit's website.
        site_source = job / ("site-" + head)
        if not site_source.exists():
            command("git", "worktree", "add", "--detach", site_source, head, cwd=self.repo)
        candidate = merge_feed((site_source / "web/appcast.xml").read_bytes(), candidate)
        if self.fetch() != head:
            raise RuntimeError("main changed while staging the website; retry from its current files")
        deploy_web(self.state, site_source / "web", candidate)
        record["phase"] = "verified"
        self.checkpoint(job, record)


def initialize(state):
    if state.exists():
        raise RuntimeError("state directory already exists; it will not be overwritten")
    state.mkdir(parents=True, mode=0o700)
    command("git", "clone", "--no-checkout", REMOTE, state / "repository")
    head = command("git", "rev-parse", "origin/main", cwd=state / "repository")
    atomic_json(state / "state.json", {"cursor": head, "last_result": "initialized; no historical releases"})
    print("Initialized at " + head + ". Future app merges will be considered.")


def install(state):
    # Install a fixed copy. Future main commits cannot silently replace the poller's policy.
    Service(state)
    plist = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    if plist.exists():
        raise RuntimeError("LaunchAgent already exists; stop and review it before replacing")
    destination = state / "nightly-service.py"
    shutil.copy2(Path(__file__).resolve(), destination)
    logs = state / "logs"
    logs.mkdir(exist_ok=True)
    plist.parent.mkdir(exist_ok=True)
    path = os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    environment = {"PATH": path, "DEVELOPER_DIR": os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")}
    data = {"Label": LABEL, "ProgramArguments": [str(Path(sys.executable).resolve()), str(destination),
            "--state-dir", str(state), "run", "--publish"], "StartInterval": 300, "RunAtLoad": True,
            "EnvironmentVariables": environment, "StandardOutPath": str(logs / "publisher.log"),
            "StandardErrorPath": str(logs / "publisher-error.log"), "ProcessType": "Background"}
    with plist.open("wb") as handle:
        plistlib.dump(data, handle)
    print("Installed, not started. Activate with:")
    print("launchctl bootstrap gui/" + str(os.getuid()) + " " + str(plist))


def main():
    os.umask(0o077)
    xcode = "/Applications/Xcode.app/Contents/Developer"
    if Path(xcode).is_dir():
        os.environ.setdefault("DEVELOPER_DIR", xcode)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("init", help="create private release state; start at current main")
    run = sub.add_parser("run", help="inspect new commits; publication requires --publish")
    run.add_argument("--publish", action="store_true")
    sub.add_parser("install", help="write a LaunchAgent without starting it")
    deploy = sub.add_parser("publish-web", help="manual Stable/site deploy, preserving the live Nightly feed")
    deploy.add_argument("web", type=Path)
    args = parser.parse_args()
    state = args.state_dir.expanduser().resolve()
    if args.action == "init":
        initialize(state)
    elif args.action == "install":
        install(state)
    else:
        with publication_lock(state):
            if args.action == "run":
                Service(state).run(args.publish)
            else:
                web = args.web.resolve()
                deploy_web(state, web, (web / "appcast.xml").read_bytes())


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, ET.ParseError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
