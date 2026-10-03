"""Release policy and crash-recovery checks; no network, keychain, or installed app access."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/nightly-service.py"
spec = importlib.util.spec_from_file_location("nightly_service", SCRIPT)
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)
SHA = "a" * 40
OTHER = "b" * 40


def entry(build="23", version="2.2.0", nightly=False, url=None):
    item = ET.Element("item")
    ET.SubElement(item, service.SPARKLE + "version").text = build
    ET.SubElement(item, service.SPARKLE + "shortVersionString").text = version
    if nightly:
        ET.SubElement(item, service.SPARKLE + "channel").text = "nightly"
    ET.SubElement(item, "enclosure", {"url": url or service.SITE + "/downloads/Lineup-2.2.0.dmg",
                  service.SPARKLE + "edSignature": "signed-by-fixture", "length": "3"})
    return item


def feed(*items):
    root = ET.Element("rss")
    channel = ET.SubElement(root, "channel")
    for item in items:
        channel.append(item)
    return ET.tostring(root)


class PolicyTests(unittest.TestCase):
    def test_command_timeout_is_reported_as_a_retryable_error(self):
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            service.command(sys.executable, "-c", "import time; time.sleep(30)", timeout=0.05)

    def test_only_app_or_package_changes_release(self):
        for paths, expected in [(["README.md", "web/appcast.xml"], False),
                                (["Scripts/nightly-service.py", "Tests/nightly_automation_test.py"], False),
                                (["Sources/lineup-tests/AppSuite.swift"], False),
                                (["Resources/Info.plist"], True), (["Package.resolved"], True),
                                (["Scripts/build-app.sh"], True),
                                (["Sources/lineup/Tools/Zones/ZonesTool.swift", "README.md"], True)]:
            with self.subTest(paths=paths):
                self.assertEqual(service.affects_app(paths), expected)

    def test_ci_requires_exact_main_push_and_latest_attempt(self):
        green = dict(id=20, head_sha=SHA, head_branch="main", event="push", status="completed",
                     conclusion="success", path=".github/workflows/ci.yml", run_attempt=1)
        self.assertEqual(service.ci_result([green], SHA), "passed")
        for override in [dict(head_sha=OTHER), dict(head_branch="feature"), dict(event="pull_request"),
                         dict(path=".github/workflows/another.yml")]:
            self.assertEqual(service.ci_result([dict(green, **override)], SHA), "waiting")
        self.assertEqual(service.ci_result([green, dict(green, run_attempt=2, status="queued")], SHA), "waiting")
        self.assertEqual(service.ci_result([green, dict(green, id=21, conclusion="failure")], SHA), "failed")

    def test_merge_preserves_stable_and_nightly_across_manual_deploy(self):
        stable = entry()
        nightly = entry("23.02.72a001", "2.2.1-nightly.20260929.1", True, "https://github.com/example.dmg")
        proposed = entry("24", "2.3.0", url=service.SITE + "/downloads/Lineup-2.3.0.dmg")
        merged = service.feed_items(service.merge_feed(feed(stable, nightly), feed(stable, proposed)))[1]
        self.assertEqual(set(merged), {"23", "24", "23.02.72a001"})
        self.assertEqual(service.item_identity(merged["23"]), service.item_identity(stable))
        self.assertEqual(service.item_identity(merged["23.02.72a001"]), service.item_identity(nightly))

    def test_rerun_preserves_published_entry_but_replacement_is_rejected(self):
        old = entry()
        ET.SubElement(old, "description").text = "Published notes"
        self.assertEqual(len(service.feed_items(service.merge_feed(feed(old), feed(old)))[1]), 1)
        revised = entry()
        ET.SubElement(revised, "description").text = "Different notes"
        preserved = service.feed_items(service.merge_feed(feed(old), feed(revised)))[1]["23"]
        self.assertEqual(preserved.findtext("description"), "Published notes")
        changed = entry(url="https://elsewhere.invalid/changed.dmg")
        with self.assertRaisesRegex(RuntimeError, "replaced"):
            service.merge_feed(feed(old), feed(changed))

    def test_explicit_notes_repair_preserves_other_entries_and_update_metadata(self):
        stable = entry()
        nightly = entry("23.02.72a001", "2.2.1-nightly.20260929.1", True,
                        "https://github.com/example.dmg")
        ET.SubElement(nightly, "pubDate").text = "Tue, 29 Sep 2026 12:00:00 +0000"
        ET.SubElement(nightly, "description").text = "<pre>## What's Changed</pre>"
        revised = ET.fromstring(ET.tostring(nightly))
        revised.find("description").text = "<h2>What's Changed</h2><ul><li>Restores saved keys.</li></ul>"
        # Reformatting the XML itself must not count as changed release metadata.
        proposal = ET.fromstring(feed(revised))
        ET.indent(proposal)
        merged = service.feed_items(service.merge_feed(feed(stable, nightly), ET.tostring(proposal),
                                                       update_release_notes=True))[1]
        self.assertEqual(set(merged), {"23", "23.02.72a001"})
        self.assertEqual(ET.tostring(merged["23"]), ET.tostring(stable))
        self.assertEqual(ET.tostring(merged["23.02.72a001"]), ET.tostring(revised))

    def test_explicit_notes_repair_rejects_unrelated_metadata_changes(self):
        original = entry()
        ET.SubElement(original, "title").text = "Lineup 2.2.0"
        ET.SubElement(original, "pubDate").text = "Tue, 29 Sep 2026 12:00:00 +0000"
        ET.SubElement(original, service.SPARKLE + "minimumSystemVersion").text = "13.0"
        ET.SubElement(original, service.SPARKLE + "releaseNotesLink").text = "https://example.com/notes"
        ET.SubElement(original, "description").text = "Old notes"
        for field in ["title", "pubDate", service.SPARKLE + "minimumSystemVersion",
                      service.SPARKLE + "shortVersionString", service.SPARKLE + "releaseNotesLink",
                      "enclosure"]:
            with self.subTest(field=field):
                revised = ET.fromstring(ET.tostring(original))
                revised.find("description").text = "<p>Fixed notes</p>"
                if field == "enclosure":
                    revised.find(field).set(service.SPARKLE + "edSignature", "different-signature")
                else:
                    revised.find(field).text = "changed metadata"
                with self.assertRaisesRegex(RuntimeError, "replaced|notes-only"):
                    service.merge_feed(feed(original), feed(revised), update_release_notes=True)

    def test_deploy_requires_published_notes_to_match_for_new_releases_and_repairs(self):
        original = entry(url="https://github.com/example.dmg")
        ET.SubElement(original, "description").text = "Old notes"
        for repair in [False, True]:
            revised = ET.fromstring(ET.tostring(original)) if repair else entry("24", "2.3.0", url="https://github.com/new.dmg")
            if revised.find("description") is None:
                ET.SubElement(revised, "description")
            revised.find("description").text = "<p>Restores saved keys.</p>"
            cached = ET.fromstring(ET.tostring(revised))
            cached.find("description").text = "<pre>## Old notes</pre>"
            options = {"update_release_notes": True} if repair else {}
            for stale in [True, False]:
                with self.subTest(repair=repair, stale=stale), tempfile.TemporaryDirectory() as directory:
                    state = Path(directory)
                    web = state / "web"
                    web.mkdir()
                    visible = cached if stale else revised
                    deployed = feed(visible) if repair else feed(original, visible)
                    responses = [feed(original), feed(original)] + [deployed] * (6 if stale else 1)
                    with patch.object(service, "public_feed", side_effect=responses), \
                         patch.object(service, "command", return_value="") as command, \
                         patch.object(service.time, "sleep"):
                        if stale:
                            with self.assertRaisesRegex(RuntimeError, "not verified"):
                                service.deploy_web(state, web, feed(revised), **options)
                        else:
                            service.deploy_web(state, web, feed(revised), **options)
                        staged = service.feed_items((command.call_args.kwargs["cwd"] / "appcast.xml").read_bytes())[1]
                        self.assertEqual(staged["23" if repair else "24"].findtext("description"),
                                         "<p>Restores saved keys.</p>")

    def test_older_nightly_and_challenge_html_fail_closed(self):
        newer = entry("23.02.72a002", "2.2.1-nightly.20260929.2", True)
        older = entry("23.02.72a001", "2.2.1-nightly.20260929.1", True)
        with self.assertRaisesRegex(RuntimeError, "newer Nightly"):
            service.merge_feed(feed(newer), feed(older))
        with self.assertRaisesRegex(RuntimeError, "RSS"):
            service.merge_feed(b"<html>challenge</html>", feed(older))

    def test_hosted_downloads_and_dotted_release_notes_must_survive(self):
        with tempfile.TemporaryDirectory() as directory:
            web = Path(directory)
            (web / "downloads").mkdir()
            (web / "downloads/Lineup-2.2.0.dmg").write_bytes(b"dmg")
            item = entry()
            ET.SubElement(item, service.SPARKLE + "releaseNotesLink").text = service.SITE + "/release-notes/2.2.0"
            with self.assertRaisesRegex(RuntimeError, "release notes"):
                service.validate_hosted_assets(feed(item), web)
            (web / "release-notes").mkdir()
            (web / "release-notes/2.2.0.html").write_text("notes")
            service.validate_hosted_assets(feed(item), web)
            (web / "downloads/Lineup-2.2.0.dmg").write_bytes(b"wrong size")
            with self.assertRaisesRegex(RuntimeError, "length"):
                service.validate_hosted_assets(feed(item), web)

    def test_duplicate_versions_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "duplicate"):
            service.feed_items(feed(entry(), entry()))

    def test_publisher_lock_is_exclusive_and_recovers_after_error(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "injected failure"):
                with service.publication_lock(state):
                    with self.assertRaisesRegex(RuntimeError, "another release"):
                        with service.publication_lock(state):
                            self.fail("second publisher acquired the lock")
                    raise RuntimeError("injected failure")
            with service.publication_lock(state):
                service.atomic_json(state / "state.json", {"cursor": SHA})
            self.assertEqual(json.loads((state / "state.json").read_text())["cursor"], SHA)


class PublicationFixture:
    """In-memory GitHub/Cloudflare responses at the external command boundary."""
    def __init__(self, root, fail_after=None):
        self.root = root
        self.job = root / "jobs" / SHA
        self.source = self.job / "source"
        self.web = self.source / "web"
        self.web.mkdir(parents=True)
        (self.web / "downloads").mkdir()
        (self.web / "downloads/Lineup-2.2.0.dmg").write_bytes(b"dmg")
        self.live = feed(entry())
        (self.web / "appcast.xml").write_bytes(self.live)
        self.plan = dict(tag="v2.2.1-nightly.20260929.1", version="2.2.1-nightly.20260929.1",
                         current_stable="2.2.0",
                         next_patch="2.2.1", bundle_version="23.02.72a001", stable_build="23",
                         asset_name="Lineup-2.2.1-nightly.20260929.1.dmg",
                         asset_url="https://github.com/hcaiano/lineup/releases/download/v2.2.1-nightly.20260929.1/Lineup-2.2.1-nightly.20260929.1.dmg")
        self.dmg = self.job / self.plan["asset_name"]
        self.dmg.write_bytes(b"notarized fixture")
        self.digest = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        service.atomic_json(self.job / "job.json", {"sha": SHA, "phase": "built", "plan": self.plan, "digest": self.digest})
        site = self.job / ("site-" + SHA)
        import shutil
        shutil.copytree(self.web, site / "web")
        self.release = None
        self.creations = 0
        self.uploads = 0
        self.deploys = 0
        self.fail_after = fail_after
        self.tag_sha = None
        self.immutable = True
        self.notes = ("## What's Changed\n"
                      "* fix(menu-bar): preserve capture indicators and simplify settings by @hcaiano "
                      "in https://github.com/hcaiano/lineup/pull/85\n\n"
                      "**Full Changelog**: https://github.com/hcaiano/lineup/compare/v2.2.0...v2.2.1\n")
        self.rendered_notes = ("<h2>What's Changed</h2>\n<ul><li>fix(menu-bar): preserve capture indicators "
                               "and simplify settings by <a href=\"https://github.com/hcaiano\">@hcaiano</a> "
                               "in <a href=\"https://github.com/hcaiano/lineup/pull/85\">"
                               "https://github.com/hcaiano/lineup/pull/85</a></li></ul>\n"
                               "<p><strong>Full Changelog</strong>: "
                               "<a href=\"https://github.com/hcaiano/lineup/compare/v2.2.0...v2.2.1\">"
                               "https://github.com/hcaiano/lineup/compare/v2.2.0...v2.2.1</a></p>")
        self.render_failure = False
        self.existing_description = False
        self.notes_requests = []
        self.markdown_requests = []
        self.pull_body = ""

    def crash(self, point):
        if self.fail_after == point:
            self.fail_after = None
            raise RuntimeError("response lost after " + point)

    def api(self, endpoint, *args):
        if endpoint.endswith("/immutable-releases"):
            return {"enabled": self.immutable}
        if endpoint == "user":
            return {"login": "hcaiano"}
        if endpoint.endswith("/releases/generate-notes"):
            self.notes_requests.append(args)
            return {"body": self.notes}
        if endpoint.endswith("/pulls/85"):
            return {"body": self.pull_body}
        if "/releases/tags/" in endpoint:
            return self.release
        if endpoint.endswith("/releases?per_page=100"):
            return [[self.release] if self.release else []]
        raise AssertionError("unexpected API request " + endpoint)

    def command(self, *args, cwd=None, env=None, timeout=None):
        if args[:3] == ("gh", "api", "markdown"):
            if timeout is None or timeout <= 0:
                raise AssertionError("renderer must have a finite execution timeout")
            if self.render_failure:
                raise RuntimeError("Markdown rendering unavailable")
            self.markdown_requests.append(next(arg[5:] for arg in args if arg.startswith("text=")))
            if "mode=gfm" not in args or "context=" + service.REPOSITORY not in args:
                raise AssertionError("renderer must use the repository's GitHub Markdown context")
            return self.rendered_notes
        if args[:3] == ("git", "ls-remote", "--tags"):
            return "" if self.tag_sha is None else self.tag_sha + "\trefs/tags/" + self.plan["tag"]
        if args[:2] == ("git", "show"):
            return plistlib.dumps({"CFBundleVersion": "23"}).decode()
        if args[:3] == ("gh", "release", "create"):
            self.creations += 1
            self.release = dict(tag_name=self.plan["tag"], body=(self.job / "notes.md").read_text(),
                                prerelease=True, draft=True, target_commitish=SHA, assets=[])
            self.crash("create")
        elif args[:3] == ("gh", "release", "upload"):
            self.uploads += 1
            self.release["assets"].append({"name": self.plan["asset_name"], "digest": "sha256:" + self.digest})
            self.crash("upload")
        elif args[:3] == ("gh", "release", "edit"):
            if len(self.release["assets"]) != 1:
                raise AssertionError("published without artifact")
            self.release.update(draft=False, immutable=True)
            self.tag_sha = SHA
            self.crash("publish")
        elif args[0] == "bash" and str(args[1]).endswith("nightly-release.sh"):
            if self.release["draft"] or not self.release.get("immutable") or self.tag_sha != SHA:
                raise RuntimeError("public release verification failed")
        elif args[0] == "bash" and str(args[1]).endswith("sparkle-appcast.sh"):
            nightly = entry(self.plan["bundle_version"], self.plan["version"], True, self.plan["asset_url"])
            if self.existing_description:
                ET.SubElement(nightly, "description").text = "Old notes"
            (self.web / "appcast.xml").write_bytes(feed(entry(), nightly))
        elif args[:3] == ("npx", "--yes", "wrangler@4.127.1"):
            self.deploys += 1
            self.live = (Path(cwd) / "appcast.xml").read_bytes()
            self.crash("deploy")
        else:
            raise AssertionError("unexpected command " + str(args))
        return ""

    @contextlib.contextmanager
    def connected(self):
        runner = object.__new__(service.Service)
        runner.state = self.root
        runner.repo = self.root
        with patch.object(service, "command", side_effect=self.command), \
             patch.object(service, "api", side_effect=self.api), \
             patch.object(service, "public_feed", side_effect=lambda: self.live), \
             patch.object(runner, "source", return_value=self.source), \
             patch.object(runner, "fetch", return_value=SHA), \
             patch.object(runner, "ci", return_value="passed"):
            yield runner


class RecoveryTests(unittest.TestCase):
    def test_notes_cover_stable_upgrade_and_use_user_facing_pr_section(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = PublicationFixture(Path(directory))
            fixture.pull_body = ("## What changed\nInternal refactor.\n\n"
                                 "## Release notes\n<!-- Write for users. -->\n"
                                 "- Keep screen-sharing indicators visible when hiding menu bar icons.\n"
                                 "- Find hidden apps in a simpler Settings list.\n\n"
                                 "## Verification\nPrivate review evidence must not appear.\n")
            with fixture.connected() as runner:
                runner.release(SHA)
            self.assertIn("previous_tag_name=v2.2.0", fixture.notes_requests[0])
            body = fixture.release["body"]
            self.assertIn("Changes since Lineup 2.2.0", body)
            self.assertIn("Keep screen-sharing indicators visible", body)
            self.assertIn("Find hidden apps in a simpler Settings list", body)
            self.assertNotIn("fix(menu-bar)", body)
            self.assertNotIn("Private review evidence", body)
            self.assertNotIn("Internal refactor", body)
            self.assertNotIn("lineup-nightly-source", fixture.markdown_requests[0])
            self.assertIn("v2.2.0..." + SHA, body)

    def test_nightly_feed_contains_formatted_release_notes(self):
        for existing_description in [False, True]:
            with self.subTest(existing_description=existing_description), tempfile.TemporaryDirectory() as directory:
                fixture = PublicationFixture(Path(directory))
                fixture.existing_description = existing_description
                with fixture.connected() as runner:
                    runner.release(SHA)
                item = service.feed_items(fixture.live)[1][fixture.plan["bundle_version"]]
                description = item.findtext("description")
                self.assertIn(fixture.rendered_notes, description)
                self.assertNotIn("<pre>", description)
                self.assertNotIn("## What's Changed", description)
                self.assertNotIn("lineup-nightly-source", description)
                self.assertEqual(len(item.findall("description")), 1)
                self.assertIn("lineup-nightly-source: " + SHA, fixture.release["body"])
                self.assertIn("Menu bar: preserve capture indicators", fixture.release["body"])
                self.assertNotIn("fix(menu-bar)", fixture.release["body"])

    def test_empty_generated_changes_stop_before_publication(self):
        for body in ["## What's Changed\n\n**Full Changelog**: https://github.com/hcaiano/lineup/compare/a...b",
                     "## New Contributors\n* @someone made their first contribution in https://github.com/hcaiano/lineup/pull/85"]:
            with self.subTest(body=body), tempfile.TemporaryDirectory() as directory:
                fixture = PublicationFixture(Path(directory))
                fixture.notes = body
                with fixture.connected() as runner, self.assertRaisesRegex(RuntimeError, "no release changes"):
                    runner.release(SHA)
                self.assertEqual((fixture.creations, fixture.uploads, fixture.deploys), (0, 0, 0))

    def test_rendering_failure_stops_before_release_mutations_and_can_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = PublicationFixture(Path(directory))
            fixture.render_failure = True
            with fixture.connected() as runner:
                with self.assertRaisesRegex(RuntimeError, "Markdown rendering unavailable"):
                    runner.release(SHA)
                self.assertEqual((fixture.creations, fixture.uploads, fixture.deploys), (0, 0, 0))
                self.assertEqual(json.loads((fixture.job / "job.json").read_text())["phase"], "built")
                fixture.render_failure = False
                runner.release(SHA)
            self.assertEqual(json.loads((fixture.job / "job.json").read_text())["phase"], "verified")

    def test_invalid_saved_notes_stop_before_creating_a_release(self):
        for markdown in ["- Fix keyboard recovery.",
                         "- Fix keyboard recovery.\n<!-- lineup-nightly-source: " + OTHER + " -->",
                         "<!-- lineup-nightly-source: " + SHA + " -->"]:
            with self.subTest(markdown=markdown), tempfile.TemporaryDirectory() as directory:
                fixture = PublicationFixture(Path(directory))
                (fixture.job / "notes.md").write_text(markdown)
                with fixture.connected() as runner, self.assertRaisesRegex(RuntimeError, "ownership marker|notes are empty"):
                    runner.release(SHA)
                self.assertEqual((fixture.creations, fixture.uploads, fixture.deploys), (0, 0, 0))

    def test_dry_run_never_advances_or_releases_and_pending_ci_stops_queue(self):
        runner = object.__new__(service.Service)
        runner.config = {"cursor": "c" * 40}
        runner.repo = Path("unused")
        def git(*args, **kwargs):
            if args[:2] == ("git", "rev-list"):
                return SHA + "\n" + OTHER
            if args[:2] == ("git", "diff"):
                return "Sources/lineup/App/AppShell.swift"
            raise AssertionError(args)
        with patch.object(service, "command", side_effect=git), \
             patch.object(runner, "fetch", return_value=OTHER), \
             patch.object(runner, "ci", side_effect=["passed", "waiting"]), \
             patch.object(runner, "release") as release, patch.object(runner, "advance") as advance:
            runner.run()
            release.assert_not_called()
            advance.assert_not_called()
        with patch.object(service, "command", side_effect=git), \
             patch.object(runner, "fetch", return_value=OTHER), \
             patch.object(runner, "ci", return_value="waiting") as ci, \
             patch.object(runner, "release") as release, patch.object(runner, "advance") as advance:
            runner.run(publish=True)
            release.assert_not_called()
            advance.assert_not_called()
            ci.assert_called_once_with(SHA)

    def test_publication_failure_leaves_cursor_for_retry(self):
        runner = object.__new__(service.Service)
        runner.config = {"cursor": OTHER}
        runner.repo = Path("unused")
        def git(*args, **kwargs):
            if args[:2] == ("git", "rev-list"):
                return SHA
            if args[:2] == ("git", "diff"):
                return "Sources/ZonesCore/LineupConfig.swift"
            if args[:2] == ("git", "show"):
                return plistlib.dumps({"CFBundleShortVersionString": "2.2.0"}).decode()
            raise AssertionError(args)
        with tempfile.TemporaryDirectory() as directory:
            runner.config_path = Path(directory) / "state.json"
            service.atomic_json(runner.config_path, runner.config)
            with patch.object(service, "command", side_effect=git), \
                 patch.object(service, "api", return_value={"tag_name": "v2.2.0", "prerelease": False, "draft": False}), \
                 patch.object(runner, "fetch", return_value=SHA), patch.object(runner, "ci", return_value="passed"), \
                 patch.object(runner, "release", side_effect=RuntimeError("notarization failed")):
                with self.assertRaisesRegex(RuntimeError, "notarization"):
                    runner.run(publish=True)
                self.assertEqual(json.loads(runner.config_path.read_text())["cursor"], OTHER)

    def test_retry_after_each_external_mutation_keeps_one_release_and_exact_artifact(self):
        for point in ["create", "upload", "publish", "deploy"]:
            with self.subTest(point=point), tempfile.TemporaryDirectory() as directory:
                fixture = PublicationFixture(Path(directory), point)
                with fixture.connected() as runner:
                    with self.assertRaisesRegex(RuntimeError, "response lost"):
                        runner.release(SHA)
                    runner.release(SHA)
                self.assertEqual(fixture.creations, 1)
                self.assertEqual(fixture.uploads, 1)
                self.assertFalse(fixture.release["draft"])
                self.assertEqual(hashlib.sha256(fixture.dmg.read_bytes()).hexdigest(), fixture.digest)
                self.assertIn("23.02.72a001", service.feed_items(fixture.live)[1])
                self.assertEqual(json.loads((fixture.job / "job.json").read_text())["phase"], "verified")

    def test_modified_artifact_never_publishes(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = PublicationFixture(Path(directory))
            fixture.dmg.write_bytes(b"tampered")
            with fixture.connected() as runner, self.assertRaisesRegex(RuntimeError, "artifact changed"):
                runner.release(SHA)
            self.assertEqual(fixture.creations, 0)
            self.assertEqual(fixture.deploys, 0)

    def test_existing_tag_from_another_commit_never_publishes(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = PublicationFixture(Path(directory))
            fixture.tag_sha = OTHER
            with fixture.connected() as runner, self.assertRaisesRegex(RuntimeError, "another source"):
                runner.release(SHA)
            self.assertEqual(fixture.creations, 0)

    def test_immutable_release_setting_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = PublicationFixture(Path(directory))
            fixture.immutable = False
            with fixture.connected() as runner, self.assertRaisesRegex(RuntimeError, "immutable"):
                runner.release(SHA)
            self.assertEqual(fixture.creations, 0)

    def test_ci_rerun_started_before_publication_prevents_release(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = PublicationFixture(Path(directory))
            with fixture.connected() as runner, patch.object(runner, "ci", side_effect=["passed", "waiting"]):
                with self.assertRaisesRegex(RuntimeError, "CI changed"):
                    runner.release(SHA)
            self.assertEqual(fixture.creations, 0)

    def test_feed_change_during_staging_prevents_deploy(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = PublicationFixture(Path(directory))
            with fixture.connected(), patch.object(service, "public_feed", side_effect=[fixture.live, feed(entry("24"))]):
                with self.assertRaisesRegex(RuntimeError, "changed while staging"):
                    service.deploy_web(fixture.root, fixture.web, fixture.live)
            self.assertEqual(fixture.deploys, 0)


if __name__ == "__main__":
    # Keep the Swift runner's output readable while retaining unittest failures.
    with contextlib.redirect_stdout(io.StringIO()):
        unittest.main()
