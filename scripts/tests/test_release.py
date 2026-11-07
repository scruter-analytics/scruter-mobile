"""release.py against a fake registry and a throwaway signing key: nothing here reaches a real registry."""

import hashlib
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import release  # noqa: E402

VERSION = "1.2.3"
POM = """<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>{group}</groupId>
  <artifactId>{artifact}</artifactId>
  <version>{version}</version>
  <packaging>{packaging}</packaging>
  <name>Name</name>
  <description>Description</description>
  <url>https://example.test</url>
  <licenses><license><name>MIT</name></license></licenses>
  <developers><developer><name>Scruter</name></developer></developers>
  <scm><url>https://example.test</url></scm>
</project>
"""


class FakeRegistry(http.server.BaseHTTPRequestHandler):
    routes: dict = {}
    calls: list = []
    bodies: list = []

    def answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        FakeRegistry.calls.append((self.command, self.path, self.headers.get("Authorization")))
        FakeRegistry.bodies.append(body)
        for prefix, response in FakeRegistry.routes.items():
            if self.path.startswith(prefix):
                if isinstance(response, list):
                    status, payload = response.pop(0) if len(response) > 1 else response[0]
                else:
                    status, payload = response
                break
        else:
            status, payload = 404, b""
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = answer
    do_POST = answer

    def log_message(self, *args):
        pass


class RegistryCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeRegistry)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        FakeRegistry.routes = {}
        FakeRegistry.calls = []
        FakeRegistry.bodies = []
        patched = {
            "CENTRAL_API": self.url + "/central",
            "PLUGIN_PORTAL": self.url + "/m2",
            "NPM_REGISTRY": self.url + "/npm",
            "PUB_DEV": self.url + "/pub",
            "CENTRAL_USERNAME": "user",
            "CENTRAL_PASSWORD": "pass",
        }
        self.saved = {k: os.environ.get(k) for k in patched}
        os.environ.update(patched)

    def tearDown(self):
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


class Published(RegistryCase):
    def test_absent_everywhere(self):
        FakeRegistry.routes = {"/central/published": (200, b'{"published": false}')}
        for name, check in release.PUBLISHED.items():
            self.assertFalse(check(VERSION), name)

    def test_present_everywhere(self):
        FakeRegistry.routes = {
            "/central/published": (200, b'{"published": true}'),
            f"/m2/net/scruter/symbols/net.scruter.symbols.gradle.plugin/{VERSION}/": (200, b"<project/>"),
            f"/npm/@scruter%2Freact-native/{VERSION}": (200, b"{}"),
            f"/pub/api/packages/scruter_flutter/versions/{VERSION}": (200, b"{}"),
        }
        for name, check in release.PUBLISHED.items():
            self.assertTrue(check(VERSION), name)

    def test_central_is_asked_with_the_user_token(self):
        FakeRegistry.routes = {"/central/published": (200, b'{"published": false}')}
        release.published_central(VERSION)
        self.assertEqual(FakeRegistry.calls[0][2], "Bearer dXNlcjpwYXNz")

    def test_half_a_deployment_is_not_an_answer(self):
        FakeRegistry.routes = {
            "/central/published": [(200, b'{"published": true}'), (200, b'{"published": false}')],
        }
        with self.assertRaises(release.Unknown):
            release.published_central(VERSION)

    def test_a_server_error_never_reads_as_not_published(self):
        FakeRegistry.routes = {"/npm/": (503, b""), "/central/published": (401, b"")}
        with self.assertRaises(release.Unknown):
            release.published_npm(VERSION)
        with self.assertRaises(release.Unknown):
            release.published_central(VERSION)


class Upload(RegistryCase):
    def bundle(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "bundle.zip"
        path.write_bytes(b"zip bytes")
        return path

    def test_waits_until_published(self):
        FakeRegistry.routes = {
            "/central/upload": (201, b"deployment-id"),
            "/central/status": [
                (200, b'{"deploymentState": "VALIDATING"}'),
                (503, b""),
                (200, b'{"deploymentState": "PUBLISHING"}'),
                (200, b'{"deploymentState": "PUBLISHED"}'),
            ],
        }
        release.central_upload(self.bundle(), "scruter-mobile-1.2.3", poll=0)
        method, path, authorization = FakeRegistry.calls[0]
        self.assertEqual(method, "POST")
        self.assertIn("publishingType=AUTOMATIC", path)
        self.assertIn("name=scruter-mobile-1.2.3", path)
        self.assertEqual(authorization, "Bearer dXNlcjpwYXNz")
        self.assertIn(b'name="bundle"; filename="bundle.zip"', FakeRegistry.bodies[0])
        self.assertIn(b"zip bytes", FakeRegistry.bodies[0])
        self.assertIn("id=deployment-id", FakeRegistry.calls[-1][1])

    def test_failed_validation_stops_the_job(self):
        report = {"deploymentState": "FAILED", "errors": {"pkg:maven/x": ["Missing signature"]}}
        FakeRegistry.routes = {
            "/central/upload": (201, b"id"),
            "/central/status": (200, json.dumps(report).encode()),
        }
        with self.assertRaises(SystemExit) as caught:
            release.central_upload(self.bundle(), "n", poll=0)
        self.assertIn("Missing signature", str(caught.exception))

    def test_refused_upload_stops_the_job(self):
        FakeRegistry.routes = {"/central/upload": (401, b"bad token")}
        with self.assertRaises(SystemExit) as caught:
            release.central_upload(self.bundle(), "n", poll=0)
        self.assertIn("401", str(caught.exception))

    def test_deadline(self):
        FakeRegistry.routes = {
            "/central/upload": (201, b"id"),
            "/central/status": (200, b'{"deploymentState": "PUBLISHING"}'),
        }
        with self.assertRaises(SystemExit) as caught:
            release.central_upload(self.bundle(), "n", deadline=0, poll=0)
        self.assertIn("rerun the job", str(caught.exception))


class Staging(unittest.TestCase):
    """A real signature from a key made for the test, in a keyring of its own."""

    @classmethod
    def setUpClass(cls):
        if shutil.which("gpg") is None:
            raise unittest.SkipTest("gpg is not installed")
        # gpg-agent's socket path has a length limit: a short directory.
        cls.home = tempfile.mkdtemp(prefix="g", dir="/tmp" if os.path.isdir("/tmp") else None)
        cls.saved_home = os.environ.get("GNUPGHOME")
        os.environ["GNUPGHOME"] = cls.home
        os.chmod(cls.home, 0o700)
        subprocess.run(
            ["gpg", "--batch", "--passphrase", "", "--quick-generate-key", "Test <test@example.test>", "ed25519", "sign", "1d"],
            check=True,
            capture_output=True,
        )
        out = subprocess.run(
            ["gpg", "--batch", "--with-colons", "--list-keys"], check=True, capture_output=True, text=True
        ).stdout
        cls.fingerprint = next(line.split(":")[9] for line in out.splitlines() if line.startswith("fpr:"))

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["gpgconf", "--kill", "gpg-agent"], capture_output=True)
        shutil.rmtree(cls.home, ignore_errors=True)
        if cls.saved_home is None:
            os.environ.pop("GNUPGHOME", None)
        else:
            os.environ["GNUPGHOME"] = cls.saved_home

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.staging = Path(directory.name) / "staging"
        for (group, artifact), packaging in release.ARTIFACTS.items():
            target = self.staging.joinpath(*group.split("."), artifact, VERSION)
            target.mkdir(parents=True)
            stem = f"{artifact}-{VERSION}"
            files = {f"{stem}.pom": POM.format(group=group, artifact=artifact, version=VERSION, packaging=packaging)}
            if packaging != "pom":
                files.update({f"{stem}.{packaging}": "main", f"{stem}-sources.jar": "src", f"{stem}-javadoc.jar": "doc"})
            for name, content in files.items():
                self.write(target / name, content)
            (target.parent / "maven-metadata.xml").write_text("<metadata/>")

    def write(self, path, content):
        path.write_text(content)
        self.sign(path)

    def sign(self, path):
        data = path.read_bytes()
        path.with_name(path.name + ".md5").write_text(hashlib.md5(data).hexdigest())
        path.with_name(path.name + ".sha1").write_text(hashlib.sha1(data).hexdigest())
        path.with_name(path.name + ".asc").unlink(missing_ok=True)
        subprocess.run(["gpg", "--batch", "--armor", "--detach-sign", str(path)], check=True, capture_output=True)

    def problems(self, version=VERSION):
        return release.verify_staging(self.staging, version, self.fingerprint)

    def file(self, group, artifact, suffix):
        return self.staging.joinpath(*group.split("."), artifact, VERSION, f"{artifact}-{VERSION}{suffix}")

    def test_a_good_deployment_passes(self):
        self.assertEqual(self.problems(), [])

    def test_a_wrong_key_is_refused(self):
        found = release.verify_staging(self.staging, VERSION, "0" * 40)
        self.assertTrue(found and all("no valid signature" in line for line in found), found)

    def test_a_changed_file_is_refused(self):
        path = self.file("net.scruter", "scruter-android", ".aar")
        path.write_text("tampered")
        found = self.problems()
        self.assertTrue(any(".md5 does not match" in line for line in found), found)
        self.assertTrue(any("no valid signature" in line for line in found), found)

    def test_a_missing_javadoc_is_refused(self):
        self.file("net.scruter", "scruter-android", "-javadoc.jar").unlink()
        self.assertTrue(any("no scruter-android-1.2.3-javadoc.jar" in line for line in self.problems()))

    def test_a_missing_module_is_refused(self):
        shutil.rmtree(self.staging / "net/scruter/symbols")
        self.assertTrue(any("gradle.plugin is missing" in line for line in self.problems()))

    def test_a_wrong_version_is_refused(self):
        self.assertTrue(any("expected version 9.9.9" in line for line in self.problems("9.9.9")))

    def test_a_poor_pom_is_refused(self):
        path = self.file("net.scruter", "scruter-android", ".pom")
        text = path.read_text().replace("<scm><url>https://example.test</url></scm>", "")
        text = text.replace("<description>Description</description>", "")
        self.write(path, text)
        found = self.problems()
        self.assertTrue(any("no <scm><url>" in line for line in found), found)
        self.assertTrue(any("no <description>" in line for line in found), found)

    def test_a_stray_module_is_refused(self):
        target = self.staging / "com/example/other/1.0.0"
        target.mkdir(parents=True)
        self.write(target / "other-1.0.0.pom", "<project/>")
        self.assertTrue(any("should not be in the deployment" in line for line in self.problems()))

    def test_the_bundle_leaves_the_repository_metadata_out(self):
        target = self.staging.parent / "bundle.zip"
        count = release.bundle(self.staging, target)
        with zipfile.ZipFile(target) as archive:
            names = archive.namelist()
        self.assertEqual(count, len(names))
        self.assertFalse([n for n in names if "maven-metadata" in n])
        self.assertIn(f"net/scruter/scruter-android/{VERSION}/scruter-android-{VERSION}.aar", names)
        self.assertIn(f"net/scruter/scruter-android/{VERSION}/scruter-android-{VERSION}.aar.asc", names)


class Mode(unittest.TestCase):
    def test_a_pushed_tag_publishes(self):
        self.assertFalse(release.is_dry_run("push", "refs/tags/v1.2.3", "", VERSION))

    def test_a_pushed_branch_never_publishes(self):
        self.assertTrue(release.is_dry_run("push", "refs/heads/wip/publish", "", VERSION))

    def test_a_manual_run_is_dry_by_default(self):
        self.assertTrue(release.is_dry_run("workflow_dispatch", "refs/heads/wip/publish", "true", VERSION))
        self.assertTrue(release.is_dry_run("workflow_dispatch", "refs/tags/v1.2.3", "true", VERSION))
        self.assertTrue(release.is_dry_run("workflow_dispatch", "refs/heads/main", "", VERSION))

    def test_a_manual_run_on_the_tag_can_publish(self):
        self.assertFalse(release.is_dry_run("workflow_dispatch", "refs/tags/v1.2.3", "false", VERSION))

    def test_a_branch_cannot_publish(self):
        with self.assertRaises(SystemExit):
            release.is_dry_run("workflow_dispatch", "refs/heads/main", "false", VERSION)

    def test_the_tag_must_match_version(self):
        for event in ("push", "workflow_dispatch"):
            with self.assertRaises(SystemExit):
                release.is_dry_run(event, "refs/tags/v1.2.4", "false", VERSION)
        with self.assertRaises(SystemExit):
            release.is_dry_run("push", "refs/tags/1.2.3", "", VERSION)

    def test_other_events_do_not_run(self):
        with self.assertRaises(SystemExit):
            release.is_dry_run("pull_request", "refs/pull/1/merge", "", VERSION)


class Notes(unittest.TestCase):
    TEXT = "# Changelog\n\n## 1.1.0\n\nNew.\n\n## 1.0.0\n\nFirst.\n"

    def test_one_section(self):
        self.assertEqual(release.changelog_section(self.TEXT, "1.1.0"), "New.\n")
        self.assertEqual(release.changelog_section(self.TEXT, "1.0.0"), "First.\n")

    def test_no_section(self):
        with self.assertRaises(SystemExit):
            release.changelog_section(self.TEXT, "2.0.0")


if __name__ == "__main__":
    unittest.main()
