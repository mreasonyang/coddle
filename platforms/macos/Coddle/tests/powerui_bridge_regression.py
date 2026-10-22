#!/usr/bin/env python3
"""Compile the production PowerUI bridge with simulated private classes."""

import argparse
from pathlib import Path
import subprocess
import tempfile
import traceback


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    transcript = []

    def log(message):
        transcript.append(message)
        print(message, flush=True)

    try:
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="coddle-powerui-test-") as directory:
            binary = Path(directory) / "powerui-bridge-test"
            build = subprocess.run([
                "clang", "-fobjc-arc", "-fblocks", "-O2", "-DCODDLE_POWERUI_TESTING=1",
                "-fmodules-cache-path=" + str(args.output_dir / "module-cache-powerui"),
                str(source / "PowerUI.m"), str(source / "tests/powerui_bridge_regression.m"),
                "-framework", "Foundation", "-o", str(binary),
            ], capture_output=True, text=True, timeout=60)
            if build.stdout or build.stderr:
                log(build.stdout + build.stderr)
            assert build.returncode == 0, "PowerUI fixture build failed"
            log("PASS: compiled production PowerUI.m with simulated class provider")
            for scenario in ["normal", "unavailable", "provider-throw", "class-probe-throw",
                             "init-throw", "selector-probe-throw", "method-throw",
                             "temporary-full", "temporary-error", "temporary-throw"]:
                # Each process gets a fresh dispatch_once token. A token stuck
                # by an escaping exception fails with this bounded timeout.
                run = subprocess.run([str(binary), scenario], capture_output=True,
                                     text=True, timeout=8)
                log((run.stdout + run.stderr).strip())
                assert run.returncode == 0, f"bridge fixture failed: {scenario}"
        log("PASS: 10 bridge scenarios; no private framework or hardware writes")
    except BaseException:
        log(traceback.format_exc())
        raise
    finally:
        (args.output_dir / "powerui-bridge-regression.log").write_text("\n".join(transcript) + "\n")


if __name__ == "__main__":
    main()
