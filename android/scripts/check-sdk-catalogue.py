#!/usr/bin/env python3
"""The Android class names of the detected-SDK catalogue (docs/CMP-MOBILE.md §3.14), checked against the SDKs themselves.

    check-sdk-catalogue.py releases [report.md]   every name against each SDK's current release (its AAR or JAR from its
                                                   Maven repository, and the artifacts of the same vendor it depends on)
    check-sdk-catalogue.py sync                    scruter-cmp/catalogue-rules.pro is generated from catalogue/sdks.json,
                                                   and, in the Scruter monorepo, catalogue/sdks.json has the class names of
                                                   backend/crates/cmp/data/app_sdks.json
    check-sdk-catalogue.py rules                   writes scruter-cmp/catalogue-rules.pro (the consumer rules that keep these
                                                   class names, and nothing else of the app, through the app's R8)

Standard library only. `releases` downloads public artifacts from public Maven repositories (the CI's job, not the app's).
"""

from __future__ import annotations

import io
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent  # sdk/android
CATALOGUE = HERE / "catalogue" / "sdks.json"
BACKEND = HERE.parent.parent / "backend" / "crates" / "cmp" / "data" / "app_sdks.json"
TIMEOUT = 60
MAX_DEPTH = 3


def load() -> dict:
    return json.loads(CATALOGUE.read_text(encoding="utf-8"))


def fetch(url: str) -> bytes | None:
    req = urllib.request.Request(url, headers={"User-Agent": "scruter-sdk-catalogue-check"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.read()
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
        return None


class Repo:
    def __init__(self, repos: list[str]):
        self.repos = repos
        self.where: dict[str, str] = {}

    def path(self, group: str, artifact: str) -> str:
        return group.replace(".", "/") + "/" + artifact

    def latest(self, group: str, artifact: str) -> str | None:
        """The current release: maven-metadata.xml's <release>, else its last non-snapshot, non-preview version."""
        for base in self.repos:
            data = fetch(f"{base}/{self.path(group, artifact)}/maven-metadata.xml")
            if not data:
                continue
            try:
                root = ET.fromstring(data)
            except ET.ParseError:
                continue
            versions = [v.text for v in root.iter("version") if v.text]
            return self.pick(versions, root.findtext("versioning/release"), group, artifact, base)
        # A repository without maven-metadata.xml: the version folders of its directory listing.
        for base in self.repos:
            page = fetch(f"{base}/{self.path(group, artifact)}/")
            if not page:
                continue
            versions = sorted(set(re.findall(r'href="(?:[^"]*/)?(\d+(?:\.\d+)+)/?"', page.decode("utf-8", "replace"))), key=version_key)
            if versions:
                return self.pick(versions, None, group, artifact, base)
        # A repository in an S3 bucket without metadata (Smartlook's): the bucket's listing of the artifact's folder.
        for base in self.repos:
            m = re.match(r"(https://[^/]+)/(.*)", base)
            if not m:
                continue
            prefix = f"{m.group(2).strip('/')}/{self.path(group, artifact)}/".lstrip("/")
            page = fetch(f"{m.group(1)}/?prefix={urllib.parse.quote(prefix)}&delimiter=/")
            if not page or b"ListBucketResult" not in page:
                continue
            versions = sorted(set(re.findall(r"<Prefix>[^<]*/(\d+(?:\.\d+)+)/</Prefix>", page.decode("utf-8", "replace"))), key=version_key)
            if versions:
                return self.pick(versions, None, group, artifact, base)
        return None

    def pick(self, versions: list[str], release: str | None, group: str, artifact: str, base: str) -> str | None:
        stable = [v for v in versions if not re.search(r"(?i)snapshot|alpha|beta|rc|preview|dev", v)]
        if release and release in stable:
            version = release
        elif stable:
            version = sorted(stable, key=version_key)[-1]
        elif versions:
            version = versions[-1]
        else:
            return None
        self.where[f"{group}:{artifact}"] = base
        return version

    def file(self, group: str, artifact: str, version: str, ext: str) -> bytes | None:
        base = self.where.get(f"{group}:{artifact}")
        bases = [base] if base else self.repos
        for b in bases:
            data = fetch(f"{b}/{self.path(group, artifact)}/{version}/{artifact}-{version}.{ext}")
            if data:
                self.where[f"{group}:{artifact}"] = b
                return data
        return None


def version_key(v: str):
    return [int(p) if p.isdigit() else -1 for p in re.split(r"[.\-]", v)]


def classes_of(archive: bytes) -> set[str]:
    """Class names in a JAR, or in an AAR (classes.jar and libs/*.jar)."""
    out: set[str] = set()
    try:
        z = zipfile.ZipFile(io.BytesIO(archive))
    except zipfile.BadZipFile:
        return out
    for name in z.namelist():
        if name.endswith(".class"):
            out.add(name[:-6].replace("/", "."))
        elif name == "classes.jar" or (name.startswith("libs/") and name.endswith(".jar")):
            out |= classes_of(z.read(name))
    return out


def dependencies(pom: bytes) -> list[tuple[str, str, str]]:
    """(group, artifact, version) of a POM's compile and runtime dependencies, versions as stated ([1.0] → 1.0)."""
    try:
        root = ET.fromstring(pom)
    except ET.ParseError:
        return []
    ns = {"m": root.tag.split("}")[0].strip("{")} if root.tag.startswith("{") else {}
    q = (lambda t: f"m:{t}") if ns else (lambda t: t)
    props = {}
    for p in root.findall(f"{q('properties')}/*", ns):
        props[p.tag.split("}")[-1]] = (p.text or "").strip()
    project_version = (root.findtext(q("version"), default="", namespaces=ns) or root.findtext(f"{q('parent')}/{q('version')}", default="", namespaces=ns)).strip()
    out = []
    for d in root.findall(f"{q('dependencies')}/{q('dependency')}", ns):
        scope = (d.findtext(q("scope"), default="compile", namespaces=ns) or "compile").strip()
        if scope not in ("compile", "runtime") or (d.findtext(q("optional"), default="", namespaces=ns) or "").strip() == "true":
            continue
        g = (d.findtext(q("groupId"), default="", namespaces=ns) or "").strip()
        a = (d.findtext(q("artifactId"), default="", namespaces=ns) or "").strip()
        v = (d.findtext(q("version"), default="", namespaces=ns) or "").strip()
        v = re.sub(r"\$\{project\.version\}", project_version, v)
        v = re.sub(r"\$\{([^}]+)\}", lambda m: props.get(m.group(1), ""), v)
        v = v.strip("[]()").split(",")[0].strip()
        if g and a and v:
            out.append((g, a, v))
    return out


def vendor(group: str) -> str:
    """Two first segments of a group: the dependencies of the same vendor are searched too (Firebase → GMS)."""
    return ".".join(group.split(".")[:2])


def search(repo: Repo, coord: str, wanted: set[str]) -> tuple[str | None, set[str]]:
    """The version of [coord]'s current release (or the version it names) and which of [wanted] it (or its vendor's
    dependencies) holds."""
    group, artifact, *pinned = coord.split(":")
    version = pinned[0] if pinned else repo.latest(group, artifact)
    if version is None:
        return None, set()
    found: set[str] = set()
    seen: set[str] = set()
    todo = [(group, artifact, version, 0)]
    while todo and found != wanted:
        g, a, v, depth = todo.pop(0)
        key = f"{g}:{a}"
        if key in seen:
            continue
        seen.add(key)
        archive = repo.file(g, a, v, "aar") or repo.file(g, a, v, "jar")
        if archive:
            found |= classes_of(archive) & wanted
        if depth < MAX_DEPTH:
            pom = repo.file(g, a, v, "pom")
            if pom:
                for dg, da, dv in dependencies(pom):
                    if vendor(dg) == vendor(group) or dg.startswith("com.google.android.gms") and group.startswith("com.google"):
                        todo.append((dg, da, dv, depth + 1))
    return version, found


def releases(report: str | None) -> int:
    cat = load()
    repo = Repo(cat["repositories"])
    lines = ["| SDK | release checked | class names | result |", "|---|---|---|---|"]
    failed = 0
    for s in cat["sdks"]:
        names = set(s["android"])
        legacy = set(s.get("legacy", []))
        current: set[str] = set()
        older: set[str] = set()
        checked = []
        for coord in s["maven"]:
            version, got = search(repo, coord, names)
            if version:
                checked.append(f"{coord}:{version}")
                current |= got
        for coord in s.get("legacyMaven", []):
            version, got = search(repo, coord, legacy)
            if version:
                checked.append(f"{coord}:{version} (older major)")
                older |= got
        # Every name must be in the current release, but those kept for older majors (found in one of them).
        missing = sorted((names - legacy) - current)
        # Names of older majors are proven only when one of those releases could be fetched.
        older_checked = any(c.endswith("(older major)") for c in checked)
        lost = sorted(legacy - current - older) if older_checked else []
        if not any(not c.endswith("(older major)") for c in checked):
            result = "no release found"
            failed += 1
        elif missing or lost:
            result = "MISSING " + ", ".join(missing + [f"{n} (older major)" for n in lost])
            failed += 1
        else:
            gone = sorted(legacy - current)
            result = "ok" + (" (only in older majors: " + ", ".join(gone) + ")" if gone else "")
            if gone and not older_checked:
                result += " (older majors not fetched: their names are not verified)"
            stale = sorted((legacy & current))
            if stale:
                result += " (still in the current release: " + ", ".join(stale) + ")"
        line = f"| {s['k']} | {'<br>'.join(checked) or '–'} | {', '.join(s['android'])} | {result} |"
        lines.append(line)
        print(f"{'ok  ' if result.startswith('ok') else 'FAIL'} {s['k']}: {result} ({', '.join(checked) or 'nothing resolved'})", flush=True)
    text = "\n".join(lines) + "\n"
    if report:
        Path(report).write_text(text, encoding="utf-8")
    print(f"\n{failed} of {len(cat['sdks'])} SDKs to correct" if failed else f"\nall {len(cat['sdks'])} SDKs match their current release")
    return 1 if failed else 0


RULES = HERE / "scruter-cmp" / "catalogue-rules.pro"


def sync() -> int:
    if RULES.read_text(encoding="utf-8") != rules_text():
        print("FAIL scruter-cmp/catalogue-rules.pro is not generated from catalogue/sdks.json: run `check-sdk-catalogue.py rules`")
        return 1
    if not BACKEND.is_file():
        print("not in the Scruter monorepo: the backend's catalogue is not compared")
        return 0
    backend = json.loads(BACKEND.read_text(encoding="utf-8"))
    cat = load()
    problems = []
    if backend["version"] != cat["version"]:
        problems.append(f"version: backend {backend['version']}, catalogue/sdks.json {cat['version']}")
    ours = {s["k"]: s["android"] for s in cat["sdks"]}
    theirs = {s["key"]: s["android"] for s in backend["sdks"] if s["android"]}
    for k in sorted(set(ours) | set(theirs)):
        if ours.get(k) != theirs.get(k):
            problems.append(f"{k}: backend {theirs.get(k)}, catalogue/sdks.json {ours.get(k)}")
    for p in problems:
        print("FAIL", p)
    print("catalogue/sdks.json matches the backend's catalogue" if not problems else f"{len(problems)} differences")
    return 1 if problems else 0


def rules_text() -> str:
    names = sorted({n for s in load()["sdks"] for n in s["android"]})
    text = "# Generated from ../catalogue/sdks.json by scripts/check-sdk-catalogue.py rules: the detected SDKs' class names keep\n"
    text += "# their names through the app's R8 (names only: R8 still removes an SDK the app does not use). Nothing else of\n"
    text += "# the app is kept (docs/CMP-MOBILE.md §3.14).\n"
    return text + "".join(f"-keepnames class {n}\n" for n in names)


def rules() -> int:
    RULES.write_text(rules_text(), encoding="utf-8")
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "releases":
        sys.exit(releases(sys.argv[2] if len(sys.argv) > 2 else None))
    if cmd == "sync":
        sys.exit(sync())
    if cmd == "rules":
        sys.exit(rules())
    print(__doc__)
    sys.exit(2)
