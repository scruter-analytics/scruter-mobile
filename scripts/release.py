#!/usr/bin/env python3
"""The registries' side of the publish workflow (docs/RUNBOOK.md, "Publishing the mobile SDKs").

    release.py mode <event> <ref> <dry-run input> <version> prints true for a dry run; refuses a run that cannot publish
    release.py published central|portal|npm|pub <version>   prints true or false; exit 2 when the registry cannot tell
    release.py pub-package-exists                           whether scruter_flutter has a first version on pub.dev
    release.py central-verify <staging> <version>           the checks Maven Central runs on a deployment, offline
    release.py central-bundle <staging> <bundle.zip>        the deployment bundle of the Central Portal
    release.py central-upload <bundle.zip> <name>           uploads it and waits until it is published
    release.py notes <version>                              the section of CHANGELOG.md for that version

Standard library only: it runs in the release jobs, next to the signing key, with nothing installed. Credentials come
from the environment and are never printed.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from pathlib import Path

NAMESPACE = "net.scruter"
SIGNING_FINGERPRINT = "3BDEE583E8C3BD91800986FBC2F008320316D8D7"

# Everything Maven Central receives, in one deployment: both or neither (`packaging` of each POM).
ARTIFACTS = {
    ("net.scruter", "scruter-android"): "aar",
    ("net.scruter", "scruter-symbols-gradle-plugin"): "jar",
    # The plugin marker: `id("net.scruter.symbols")` also resolves from mavenCentral().
    ("net.scruter.symbols", "net.scruter.symbols.gradle.plugin"): "pom",
}
# The artifacts the Central Portal is asked about: the marker cannot exist without the plugin.
CENTRAL_PUBLISHED = [("net.scruter", "scruter-android"), ("net.scruter", "scruter-symbols-gradle-plugin")]

NPM_PACKAGE = "@scruter/react-native"
PUB_PACKAGE = "scruter_flutter"
PLUGIN_ID = "net.scruter.symbols"

TIMEOUT = 60
POLL_SECONDS = 15
PUBLISH_DEADLINE_SECONDS = 60 * 60


class Unknown(Exception):
    """The registry did not answer in a way that says whether the version exists."""


def central_api() -> str:
    return os.environ.get("CENTRAL_API", "https://central.sonatype.com/api/v1/publisher")


def plugin_portal() -> str:
    return os.environ.get("PLUGIN_PORTAL", "https://plugins.gradle.org/m2")


def npm_registry() -> str:
    return os.environ.get("NPM_REGISTRY", "https://registry.npmjs.org")


def pub_dev() -> str:
    return os.environ.get("PUB_DEV", "https://pub.dev")


def central_authorization() -> str:
    username = os.environ.get("CENTRAL_USERNAME")
    password = os.environ.get("CENTRAL_PASSWORD")
    if not username or not password:
        raise SystemExit("CENTRAL_USERNAME and CENTRAL_PASSWORD are not set")
    return "Bearer " + base64.b64encode(f"{username}:{password}".encode()).decode()


def request(url: str, *, method: str = "GET", headers: dict | None = None, body: bytes | None = None):
    """(status, body); a network failure or a server error is `Unknown`, never "not published"."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as res:
            return res.status, res.read()
    except urllib.error.HTTPError as err:
        payload = err.read()
        if err.code >= 500 or err.code == 429:
            raise Unknown(f"{urllib.parse.urlsplit(url).netloc} answered {err.code}") from err
        return err.code, payload
    except (urllib.error.URLError, TimeoutError, ConnectionError) as err:
        raise Unknown(f"{urllib.parse.urlsplit(url).netloc}: {err}") from err


def exists(url: str, headers: dict | None = None) -> bool:
    status, _ = request(url, headers=headers)
    if status == 200:
        return True
    if status == 404:
        return False
    raise Unknown(f"{url} answered {status}")


def published_central(version: str) -> bool:
    headers = {"Authorization": central_authorization()}
    found = []
    for namespace, name in CENTRAL_PUBLISHED:
        query = urllib.parse.urlencode({"namespace": namespace, "name": name, "version": version})
        status, body = request(f"{central_api()}/published?{query}", headers=headers)
        if status != 200:
            raise Unknown(f"the Central Portal answered {status} about {name}")
        found.append(bool(json.loads(body).get("published")))
    if any(found) and not all(found):
        # One deployment holds both: half of it published means someone uploaded by hand.
        raise Unknown(f"only part of {version} is on Maven Central: {dict(zip(CENTRAL_PUBLISHED, found))}")
    return all(found)


def published_portal(version: str) -> bool:
    path = PLUGIN_ID.replace(".", "/")
    return exists(f"{plugin_portal()}/{path}/{PLUGIN_ID}.gradle.plugin/{version}/{PLUGIN_ID}.gradle.plugin-{version}.pom")


def published_npm(version: str) -> bool:
    name = urllib.parse.quote(NPM_PACKAGE, safe="@")
    return exists(f"{npm_registry()}/{name}/{version}")


def published_pub(version: str) -> bool:
    return exists(f"{pub_dev()}/api/packages/{PUB_PACKAGE}/versions/{version}")


def pub_package_exists() -> bool:
    return exists(f"{pub_dev()}/api/packages/{PUB_PACKAGE}")


PUBLISHED = {
    "central": published_central,
    "portal": published_portal,
    "npm": published_npm,
    "pub": published_pub,
}


@dataclass(frozen=True)
class Module:
    group: str
    artifact: str
    version: str
    directory: Path


def modules(staging: Path) -> list[Module]:
    """Every group/artifact/version directory of a Maven repository on disk."""
    found = []
    for pom in sorted(staging.rglob("*.pom")):
        directory = pom.parent
        relative = directory.relative_to(staging).parts
        if len(relative) < 3:
            continue
        found.append(Module(".".join(relative[:-2]), relative[-2], relative[-1], directory))
    return found


POM_NS = re.compile(r"^\{[^}]*\}")


def pom_tree(path: Path) -> dict:
    """The POM as nested dicts, namespaces dropped (repeated elements: the last one, which is enough here)."""

    def walk(node: ET.Element):
        children = list(node)
        if not children:
            return (node.text or "").strip()
        return {POM_NS.sub("", child.tag): walk(child) for child in children}

    return walk(ET.parse(path).getroot())


def verify_pom(module: Module, pom: dict) -> list[str]:
    where = f"{module.group}:{module.artifact}"
    out = []
    coordinates = (pom.get("groupId"), pom.get("artifactId"), pom.get("version"))
    if coordinates != (module.group, module.artifact, module.version):
        out.append(f"{where}: the POM says {coordinates}")
    for field in ("name", "description", "url"):
        if not pom.get(field):
            out.append(f"{where}: the POM has no <{field}>")
    license_ = pom.get("licenses", {}).get("license", {}) if isinstance(pom.get("licenses"), dict) else {}
    if not (isinstance(license_, dict) and license_.get("name")):
        out.append(f"{where}: the POM has no license name")
    developer = pom.get("developers", {}).get("developer", {}) if isinstance(pom.get("developers"), dict) else {}
    if not (isinstance(developer, dict) and (developer.get("name") or developer.get("id"))):
        out.append(f"{where}: the POM has no developer")
    scm = pom.get("scm")
    if not (isinstance(scm, dict) and scm.get("url")):
        out.append(f"{where}: the POM has no <scm><url>")
    return out


def checksums(path: Path) -> list[str]:
    data = path.read_bytes()
    out = []
    for suffix, algorithm in ((".md5", hashlib.md5), (".sha1", hashlib.sha1)):
        sidecar = path.with_name(path.name + suffix)
        if not sidecar.is_file():
            out.append(f"{path.name}: no {suffix} file")
        elif sidecar.read_text().split()[0].lower() != algorithm(data).hexdigest():
            out.append(f"{path.name}: {suffix} does not match")
    return out


def gpg_signed_by_key(path: Path, fingerprint: str) -> bool:
    """A good signature made by the key, or one of its subkeys (VALIDSIG's last field is the primary key)."""
    result = subprocess.run(
        ["gpg", "--batch", "--status-fd", "1", "--verify", f"{path}.asc", str(path)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) > 3 and fields[1] == "VALIDSIG":
            return fingerprint in (fields[2], fields[-1])
    return False


def verify_staging(staging: Path, version: str, fingerprint: str = SIGNING_FINGERPRINT) -> list[str]:
    """Maven Central's own rules (central.sonatype.org/publish/requirements), on the directory the bundle is made of."""
    out = []
    found = modules(staging)
    coordinates = {(m.group, m.artifact) for m in found}
    for missing in sorted(set(ARTIFACTS) - coordinates):
        out.append(f"{missing[0]}:{missing[1]} is missing")
    for module in found:
        where = f"{module.group}:{module.artifact}:{module.version}"
        if (module.group, module.artifact) not in ARTIFACTS:
            out.append(f"{where} should not be in the deployment")
            continue
        if module.version != version:
            out.append(f"{where}: expected version {version}")
            continue
        if module.group != NAMESPACE and not module.group.startswith(NAMESPACE + "."):
            out.append(f"{where}: outside the namespace {NAMESPACE}")
        stem = f"{module.artifact}-{module.version}"
        packaging = ARTIFACTS[(module.group, module.artifact)]
        required = [f"{stem}.pom"]
        if packaging != "pom":
            required += [f"{stem}.{packaging}", f"{stem}-sources.jar", f"{stem}-javadoc.jar"]
        for name in required:
            if not (module.directory / name).is_file():
                out.append(f"{where}: no {name}")
        pom_path = module.directory / f"{stem}.pom"
        if pom_path.is_file():
            pom = pom_tree(pom_path)
            out += verify_pom(module, pom)
            declared = pom.get("packaging", "jar")
            if declared != packaging:
                out.append(f"{where}: the POM's packaging is {declared}, expected {packaging}")
        for path in sorted(module.directory.iterdir()):
            if path.suffix in (".md5", ".sha1", ".sha256", ".sha512", ".asc") or path.name.startswith("maven-metadata"):
                continue
            out += [f"{where}: {line}" for line in checksums(path)]
            if not path.with_name(path.name + ".asc").is_file():
                out.append(f"{where}: {path.name} is not signed")
            elif not gpg_signed_by_key(path, fingerprint):
                out.append(f"{where}: {path.name}: no valid signature by {fingerprint}")
    return out


def bundle(staging: Path, target: Path) -> int:
    """The Maven layout zipped from its root; `maven-metadata.xml` is the repository's, not the deployment's."""
    count = 0
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(staging.rglob("*")):
            if path.is_file() and not path.name.startswith("maven-metadata"):
                archive.write(path, path.relative_to(staging).as_posix())
                count += 1
    return count


def multipart(field: str, filename: str, data: bytes) -> tuple[str, bytes]:
    boundary = uuid.uuid4().hex
    head = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
        "Content-Type: application/octet-stream\r\n\r\n"
    ).encode()
    return f"multipart/form-data; boundary={boundary}", head + data + f"\r\n--{boundary}--\r\n".encode()


def central_upload(path: Path, name: str, *, deadline: int = PUBLISH_DEADLINE_SECONDS, poll: int = POLL_SECONDS) -> None:
    """AUTOMATIC: the Portal publishes once its validation passes. Failed validation publishes nothing."""
    authorization = central_authorization()
    content_type, body = multipart("bundle", path.name, path.read_bytes())
    query = urllib.parse.urlencode({"name": name, "publishingType": "AUTOMATIC"})
    status, answer = request(
        f"{central_api()}/upload?{query}",
        method="POST",
        headers={"Authorization": authorization, "Content-Type": content_type},
        body=body,
    )
    if status not in (200, 201):
        raise SystemExit(f"the Central Portal refused the bundle ({status}): {answer.decode(errors='replace')[:2000]}")
    deployment = answer.decode().strip()
    print(f"deployment {deployment}", flush=True)
    started = time.monotonic()
    state = "unknown"
    while time.monotonic() - started < deadline:
        query = urllib.parse.urlencode({"id": deployment})
        try:
            status, answer = request(
                f"{central_api()}/status?{query}", method="POST", headers={"Authorization": authorization}
            )
        except Unknown as err:
            print(f"{err}: asking again", flush=True)
            time.sleep(poll)
            continue
        if status != 200:
            raise SystemExit(f"the Central Portal answered {status} about deployment {deployment}")
        report = json.loads(answer)
        if report.get("deploymentState") != state:
            state = report.get("deploymentState")
            print(f"state: {state}", flush=True)
        if state == "PUBLISHED":
            return
        if state == "FAILED":
            raise SystemExit("validation failed:\n" + json.dumps(report.get("errors", report), indent=2))
        time.sleep(poll)
    raise SystemExit(
        f"deployment {deployment} is still {state} after {deadline} s: see central.sonatype.com/publishing/deployments, "
        "and rerun the job once it is published"
    )


def is_dry_run(event: str, ref: str, dry_run_input: str, version: str) -> bool:
    """Only a tag `v<VERSION>` publishes: pushed, or a manual run on it with `dry_run` off. Anything else is a dry run."""
    tag = ref.removeprefix("refs/tags/") if ref.startswith("refs/tags/") else None
    if tag is not None and tag != f"v{version}":
        raise SystemExit(f"the tag {tag} does not match VERSION ({version})")
    if event == "push":
        return tag is None
    if event == "workflow_dispatch":
        if dry_run_input == "false" and tag is None:
            raise SystemExit("a publication runs from a tag v<version>, not from a branch")
        return dry_run_input != "false"
    raise SystemExit(f"this workflow does not run on {event}")


def changelog_section(text: str, version: str) -> str:
    match = re.search(rf"^## {re.escape(version)}\s*$(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL)
    if match is None or not match.group(1).strip():
        raise SystemExit(f"CHANGELOG.md has no section for {version}")
    return match.group(1).strip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    mode = commands.add_parser("mode")
    mode.add_argument("event")
    mode.add_argument("ref")
    mode.add_argument("dry_run")
    mode.add_argument("version")
    published = commands.add_parser("published")
    published.add_argument("registry", choices=sorted(PUBLISHED))
    published.add_argument("version")
    verify = commands.add_parser("central-verify")
    verify.add_argument("staging", type=Path)
    verify.add_argument("version")
    verify.add_argument("--fingerprint", default=SIGNING_FINGERPRINT, help="the key that must have signed")
    make = commands.add_parser("central-bundle")
    make.add_argument("staging", type=Path)
    make.add_argument("bundle", type=Path)
    upload = commands.add_parser("central-upload")
    upload.add_argument("bundle", type=Path)
    upload.add_argument("name")
    commands.add_parser("pub-package-exists")
    notes = commands.add_parser("notes")
    notes.add_argument("version")
    args = parser.parse_args()

    if args.command == "mode":
        print("true" if is_dry_run(args.event, args.ref, args.dry_run, args.version) else "false")
    elif args.command in ("published", "pub-package-exists"):
        try:
            answer = PUBLISHED[args.registry](args.version) if args.command == "published" else pub_package_exists()
        except Unknown as err:
            print(err, file=sys.stderr)
            return 2
        print("true" if answer else "false")
    elif args.command == "central-verify":
        problems = verify_staging(args.staging, args.version, args.fingerprint)
        for line in problems:
            print(line, file=sys.stderr)
        if problems:
            return 1
        print(f"{len(modules(args.staging))} modules ready for Maven Central")
    elif args.command == "central-bundle":
        print(f"{bundle(args.staging, args.bundle)} files in {args.bundle}")
    elif args.command == "central-upload":
        central_upload(args.bundle, args.name)
    elif args.command == "notes":
        changelog = Path(__file__).resolve().parent.parent / "CHANGELOG.md"
        sys.stdout.write(changelog_section(changelog.read_text(encoding="utf-8"), args.version))
    return 0


if __name__ == "__main__":
    sys.exit(main())
