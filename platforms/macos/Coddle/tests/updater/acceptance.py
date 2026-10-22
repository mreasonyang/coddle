#!/usr/bin/env python3
"""Run real Sparkle download, signature checks, replacement and relaunch in disposable apps.

Requires macOS GUI login and an extracted Sparkle distribution. No existing
signing keys, Coddle defaults, helper, or production app are accessed.
Usage: python3 tests/updater/acceptance.py --sparkle /path/to/sparkle-2.10.0
"""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import platform
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, **kwargs)


def sign_app(app):
    framework = app / "Contents/Frameworks/Sparkle.framework"
    version = framework / "Versions/B"
    for target in [*sorted((version / "XPCServices").glob("*.xpc")),
                   version / "Autoupdate", version / "Updater.app", framework, app]:
        run(["codesign", "--force", "--sign", "-", target])
    run(["codesign", "--verify", "--deep", "--strict", app])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sparkle", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    sparkle = args.sparkle.resolve()
    output = (args.output or Path(tempfile.mkdtemp(prefix="coddle-updater-evidence-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    results = []
    # The freshly generated key remains in memory, and is passed to Sparkle on
    # stdin. It is never written to a keychain, file, command argument, or log.
    key = json.loads(run(["swift", "-e", '''import Foundation; import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let result = ["seed": key.rawRepresentation.base64EncodedString(), "public": key.publicKey.rawRepresentation.base64EncodedString()]
print(String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)''']).stdout)
    secret_input = (key.pop("seed") + "\n").encode()
    def signature(path, feed=False):
        # Do not forward the tool's output on error: signing diagnostics can
        # contain invalid key input. Only public signatures enter evidence.
        result = subprocess.run([str(sparkle / "bin/sign_update"), "--ed-key-file", "-", "-p", str(path)],
            input=secret_input, capture_output=True)
        if result.returncode: raise RuntimeError("Disposable fixture signing failed")
        return result.stdout.decode().strip()

    with tempfile.TemporaryDirectory(prefix="coddle-updater-acceptance-") as temp:
        work = Path(temp)
        binary = work / "Acceptance"
        run(["clang", "-fobjc-arc", "-target", platform.machine() + "-apple-macos13.0", "-F", sparkle,
             "-framework", "AppKit", "-framework", "Sparkle", "-Wl,-rpath,@executable_path/../Frameworks",
             Path(__file__).with_name("AcceptanceApp.m"), "-o", binary])
        for tampered in (False, True):
            scenario = "tampered" if tampered else "upgrade"
            folder = work / scenario
            served = folder / "served"
            served.mkdir(parents=True)
            evidence = output / (scenario + ".jsonl")
            evidence.write_text("")
            bundle_id = "com.coddle.updater.acceptance." + uuid.uuid4().hex
            class Handler(http.server.SimpleHTTPRequestHandler):
                def log_message(self, *arguments): pass
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(served)))
            threading.Thread(target=server.serve_forever, daemon=True).start()
            url = "http://127.0.0.1:%d" % server.server_port
            app = folder / "installed/CoddleUpdaterAcceptance.app"
            target = folder / "new/CoddleUpdaterAcceptance.app"
            def create_app(path, version):
                (path / "Contents/MacOS").mkdir(parents=True)
                (path / "Contents/Frameworks").mkdir()
                shutil.copy2(binary, path / "Contents/MacOS/Acceptance")
                run(["ditto", sparkle / "Sparkle.framework", path / "Contents/Frameworks/Sparkle.framework"])
                info = dict(CFBundleIdentifier=bundle_id, CFBundleExecutable="Acceptance", CFBundleName="Coddle Updater Acceptance",
                    CFBundlePackageType="APPL", CFBundleVersion=str(version), CFBundleShortVersionString="1.0." + str(version),
                    LSUIElement=True, LSMinimumSystemVersion="13.0", SUFeedURL=url + "/appcast.xml", SUPublicEDKey=key["public"],
                    SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUEnableSystemProfiling=False,
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True, AcceptanceEvidence=str(evidence),
                    NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
                (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                sign_app(path)
            process = None
            try:
                create_app(app, 1)
                create_app(target, 2)
                archive = served / "update.zip"
                run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", target, archive])
                sig = signature(archive)
                if tampered:
                    with archive.open("ab") as file: file.write(b"fixture-tamper")
                feed = served / "appcast.xml"
                feed.write_text('''<?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated Acceptance</title><item><title>Version 2</title><sparkle:version>2</sparkle:version><sparkle:shortVersionString>1.0.2</sparkle:shortVersionString><sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion><enclosure url="%s/update.zip" sparkle:edSignature="%s" length="%d" type="application/octet-stream"/></item></channel></rss>''' % (url, sig, archive.stat().st_size))
                signature(feed, feed=True)
                with (output / (scenario + "-process.log")).open("wb") as log:
                    process = subprocess.Popen([str(app / "Contents/MacOS/Acceptance")], stdout=log, stderr=log)
                    deadline = time.monotonic() + args.timeout
                    while time.monotonic() < deadline:
                        events = [json.loads(line) for line in evidence.read_text().splitlines() if line]
                        if any(x["event"] in ("error", "startup-error", "not-found") for x in events): break
                        if any(x["event"] == "acceptance-completed" and x["version"] == "2" for x in events): break
                        time.sleep(0.25)
                events = [json.loads(line) for line in evidence.read_text().splitlines() if line]
                installed = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
                names = [x["event"] for x in events]
                if tampered:
                    error = next((x for x in events if x["event"] == "error"), {})
                    passed = installed == "1" and bool(error) and "ready-to-install" not in names and "signature" in (error.get("description", "") + error.get("underlying", "")).lower()
                else:
                    old_cleanup = next((i for i,x in enumerate(events) if x["event"] == "cleanup-completed" and x["version"] == "1"), -1)
                    relaunched = next((i for i,x in enumerate(events) if x["event"] == "launched" and x["version"] == "2"), -1)
                    passed = installed == "2" and "ready-to-install" in names and old_cleanup >= 0 and relaunched > old_cleanup
                    if passed: run(["codesign", "--verify", "--deep", "--strict", app])
                results.append(dict(scenario=scenario, passed=passed, installedVersion=installed, bundleID=bundle_id,
                    events=events, archiveSHA256=hashlib.sha256(archive.read_bytes()).hexdigest()))
                print(scenario + ": " + ("PASS" if passed else "FAIL"), flush=True)
            finally:
                server.shutdown(); server.server_close()
                if process and process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
                # Sparkle relaunches through LaunchServices, so the new process
                # is not represented by our Popen handle. Match both its logged
                # PID and this exact temporary executable before cleanup.
                logged = [json.loads(line) for line in evidence.read_text().splitlines() if line]
                for pid in {entry["pid"] for entry in logged if entry["event"] == "launched"}:
                    command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True).stdout.decode()
                    if str(app / "Contents/MacOS/Acceptance") not in command: continue
                    try: os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError: pass
                # Unique fixture domain only; never com.coddle.app.
                subprocess.run(["defaults", "delete", bundle_id], capture_output=True)
                shutil.rmtree(Path.home() / "Library/Caches" / bundle_id, ignore_errors=True)
    report = {"passed": all(x["passed"] for x in results), "sparkle": str(sparkle),
              "scope": "Real Sparkle in disposable minimal app; ad-hoc signing, loopback feed, custom fixture user driver", "results": results}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Evidence: " + str(output / "report.json"))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
