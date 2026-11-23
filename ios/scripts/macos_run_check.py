#!/usr/bin/env python3
"""Checks the batches the example Mac app sent during ios/scripts/macos-run.sh: platform `macos`, form `desktop`, this
Mac's model and macOS version, a session, the SwiftUI and AppKit screens, the custom event, and a batch sent at quit.

Usage: macos_run_check.py BATCH_DIR APP_EXIT_TIME EXPECTED_SDK
"""
import glob
import json
import subprocess
import sys

batch_dir, exit_time, sdk = sys.argv[1], float(sys.argv[2]), sys.argv[3]
model = subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip()
version = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip().split(".")
os_version = version[0] + "." + (version[1] if len(version) > 1 else "0")

batches = []
for path in sorted(glob.glob(batch_dir + "/batch-*.json")):
    with open(path) as f:
        body = json.load(f)
    with open(path[: -len(".json")] + ".received") as f:
        batches.append((float(f.read()), path, body))

failures = []


def check(ok, what):
    print(("  ok    " if ok else "  FAIL  ") + what)
    if not ok:
        failures.append(what)


check(len(batches) > 0, "%d batch(es) received" % len(batches))
sessions = [s for _, _, b in batches for s in b.get("s", [])]
events = [e for _, _, b in batches for e in b.get("e", [])]
first = sessions[0] if sessions else {}
check(all(b.get("sdk") == sdk for _, _, b in batches), "sdk = %s" % sdk)
check(first.get("p") == "macos", "p = macos (got %r)" % first.get("p"))
check(first.get("f") == "desktop", "f = desktop (got %r)" % first.get("f"))
check(first.get("m") == model, "m = this Mac's hw.model %s (got %r)" % (model, first.get("m")))
check(first.get("os") == os_version, "os = macOS %s (got %r)" % (os_version, first.get("os")))
check(first.get("bid") == "net.scruter.example.mac", "bid = net.scruter.example.mac (got %r)" % first.get("bid"))
check(first.get("bk") == "debug", "bk = debug: a development-signed build (got %r)" % first.get("bk"))
check(len({s.get("id") for s in sessions}) == 1, "one session (%d)" % len({s.get("id") for s in sessions}))
screens = [e.get("n") for e in events if e.get("k") == "screen"]
check("Mac Home" in screens, "SwiftUI screen « Mac Home » (.scruterScreen)")
check("Reports" in screens, "AppKit screen « Reports » (automatic, ReportsViewController)")
custom = [e for e in events if e.get("k") == "event" and e.get("n") == "export"]
check(bool(custom), "custom event « export »")
check(bool(custom) and (custom[0].get("p") or {}).get("format") == "csv", "its property format = csv")
last_time = batches[-1][0] if batches else 0
check(exit_time - 2.5 <= last_time <= exit_time + 0.5, "a batch sent at quit (%.2f s before the process ended)" % (exit_time - last_time))
with_export = [t for t, _, b in batches for e in b.get("e", []) if e.get("n") == "export"]
check(bool(with_export) and with_export[-1] >= exit_time - 2.5, "the event sent 1.5 s before quitting left with the quit flush")
print("screens: %s · sessions: %d · events: %d · batches: %d" % (screens, len(sessions), len(events), len(batches)))
sys.exit(1 if failures else 0)
