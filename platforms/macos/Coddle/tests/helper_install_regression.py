#!/usr/bin/env python3
"""Execute the generated installer integrity prefix with isolated staging.

This is not an administrator installation. Only directory creation, copying,
SHA256, codesign verification, and fixed-plist generation/linting are executed.
No fixture payload, pmset, launchctl, privileged path, or final install is run.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shlex
import shutil
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

    def run(argv, **kwargs):
        return subprocess.run(argv, capture_output=True, text=True, timeout=60, **kwargs)

    try:
        assert os.geteuid() != 0, "run scoped validation as a normal user"
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="installer-fixture-", dir=args.output_dir) as directory:
            work = Path(directory)
            generator_source = work / "Generator.swift"
            generator_source.write_text('''import Foundation
@main struct Generator {
    static func main() {
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "uninstall" {
            print(HelperManager.uninstallationScript)
        } else {
            precondition(CommandLine.arguments.count == 3)
            print(HelperManager.installationScript(helper: CommandLine.arguments[1], sha256: CommandLine.arguments[2]))
        }
    }
}
''')
            generator = work / "generator"
            built = run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(work / "cache"),
                         str(source / "Sources/HelperManager.swift"), str(source / "Sources/HelperCommand.swift"), str(source / "Sources/BoundedIO.swift"),
                         str(generator_source), "-o", str(generator), "-framework", "Foundation", "-framework", "IOKit"])
            assert built.returncode == 0, built.stderr
            log("PASS: generator compiled from actual HelperManager and BoundedIO sources")
            fixtures = {}
            for name, marker in [("signed", "CODDLE_FIXTURE_A_MARKER"), ("alternate", "CODDLE_FIXTURE_B_MARKER")]:
                c_source = work / f"{name}.c"
                c_source.write_text(f'const char *marker = "{marker}"; int main(void) {{ return marker[0] == 0; }}\n')
                binary = work / name
                compiled = run(["clang", str(c_source), "-o", str(binary)])
                assert compiled.returncode == 0, compiled.stderr
                signed = run(["/usr/bin/codesign", "--force", "--sign", "-", str(binary)])
                assert signed.returncode == 0, signed.stderr
                verified = run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(binary)])
                assert verified.returncode == 0, verified.stderr
                fixtures[name] = binary
            unsigned = work / "unsigned"
            shutil.copyfile(fixtures["signed"], unsigned)
            stripped = run(["/usr/bin/codesign", "--remove-signature", str(unsigned)])
            assert stripped.returncode == 0, stripped.stderr
            fixtures["unsigned"] = unsigned
            damaged = work / "damaged"
            content = fixtures["signed"].read_bytes()
            assert content.count(b"CODDLE_FIXTURE_A_MARKER") == 1
            damaged.write_bytes(content.replace(b"CODDLE_FIXTURE_A_MARKER", b"CODDLE_FIXTURE_X_MARKER"))
            fixtures["damaged"] = damaged
            log("PASS: valid, unsigned, damaged-signature and separately signed alternate fixture bytes prepared without execution")
            # A quoted path exercises actual shell quoting at the same time.
            resources = work / "fixture's Coddle.app" / "Contents" / "Resources"
            resources.mkdir(parents=True)
            selected = resources / "coddle-helper"
            bundled_plist = resources / "com.coddle.helper.plist"
            bundled_plist.write_text("THIS IS NOT XML; <ProgramArguments>/bin/false</ProgramArguments>")
            staging_root = work / "staging"

            def check(name, selected_bytes, *, replace_after_selection=None, expected_success=False, signature_reached=True):
                shutil.copyfile(selected_bytes, selected)
                digest = hashlib.sha256(selected.read_bytes()).hexdigest()
                generated = run([str(generator), str(selected), digest])
                assert generated.returncode == 0, generated.stderr
                full_script = generated.stdout
                boundary = '/usr/bin/install -m 755 -o root -g wheel "$stage/helper" '
                assert full_script.count(boundary) == 1
                prefix = full_script[:full_script.index(boundary)]
                assert prefix.rstrip().endswith('/usr/bin/plutil -lint "$stage/helper.plist"')
                assert "/bin/launchctl" not in prefix and "/usr/bin/pmset" not in prefix
                assert str(bundled_plist) not in prefix
                # Only staging location and ownership flags change. The bytes
                # comparison, signature command and plist contents are original.
                prefix = prefix.replace('/bin/mkdir -p /Library/PrivilegedHelperTools',
                                        '/bin/mkdir -p ' + shlex.quote(str(staging_root)))
                prefix = prefix.replace('/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.coddle-install.XXXXXX',
                                        '/usr/bin/mktemp -d ' + shlex.quote(str(staging_root / '.coddle-install.XXXXXX')))
                prefix = prefix.replace(' -o root -g wheel', '')
                assert '/bin/mkdir -p /Library/' not in prefix
                assert '/usr/bin/mktemp -d /Library/' not in prefix
                generated_plist = work / f"{name}.plist"
                prefix += '\n/bin/cp "$stage/helper.plist" ' + shlex.quote(str(generated_plist)) + '\n'
                if replace_after_selection:
                    shutil.copyfile(replace_after_selection, selected)
                result = run(["/bin/bash", "-x", "-c", prefix])
                (args.output_dir / f"helper-install-{name}.log").write_text(result.stdout + result.stderr)
                assert (result.returncode == 0) == expected_success, (name, result.returncode, result.stderr)
                assert ('+ /usr/bin/codesign --verify' in result.stderr) == signature_reached, (name, result.stderr)
                assert not list(staging_root.iterdir()), "stage must be removed on success and rejection"
                if expected_success:
                    plist = plistlib.loads(generated_plist.read_bytes())
                    assert plist["ProgramArguments"] == ["/Library/PrivilegedHelperTools/com.coddle.helper"]
                    assert plist["Label"] == "com.coddle.helper"
                    assert plist["RunAtLoad"] is True and plist["KeepAlive"] is True
                    assert bundled_plist.read_text().startswith("THIS IS NOT XML")
                return result

            check("valid", fixtures["signed"], expected_success=True)
            log("PASS: matching signed bytes pass the actual staged hash/signature checks; malformed bundled plist cannot alter generated fixed plist")
            check("unsigned", fixtures["unsigned"])
            log("PASS: unsigned bytes with matching hash reach codesign and are rejected")
            check("damaged", fixtures["damaged"])
            log("PASS: damaged-signature bytes with matching hash reach codesign and are rejected")
            check("substituted", fixtures["signed"], replace_after_selection=fixtures["alternate"], signature_reached=False)
            log("PASS: selected bytes substituted by another valid signed binary are rejected at SHA256 check")
            # Execute actual uninstall control flow with every external command
            # replaced by this stateful harmless fixture. No root operation runs.
            fixture = work / "uninstall-dependency"
            fixture.write_text("""#!/bin/bash
set -eu
case "$1" in
  power)
    count=$(/bin/cat "$CODDLE_TEST_POWER_COUNT")
    count=$((count + 1))
    /usr/bin/printf '%s' "$count" > "$CODDLE_TEST_POWER_COUNT"
    if [ "$CODDLE_TEST_MODE" = fail_final_once ] && [ "$count" -eq 1 ]; then exit 1; fi
    ;;
  bootout)
    if [ "$CODDLE_TEST_MODE" = bootout_failure ] || [ "$CODDLE_TEST_MODE" = probe_failure ]; then exit 5; fi
    if [ "$(/bin/cat "$CODDLE_TEST_SERVICE_STATE")" = absent ]; then exit 113; fi
    /usr/bin/printf absent > "$CODDLE_TEST_SERVICE_STATE"
    ;;
  print)
    if [ "$CODDLE_TEST_MODE" = probe_failure ]; then exit 77; fi
    if [ "$(/bin/cat "$CODDLE_TEST_SERVICE_STATE")" = absent ]; then exit 113; fi
    ;;
  remove) /usr/bin/printf yes > "$CODDLE_TEST_REMOVED" ;;
  *) exit 99 ;;
esac
""")
            fixture.chmod(0o755)
            generated = run([str(generator), "uninstall"])
            assert generated.returncode == 0, generated.stderr
            removal = generated.stdout
            fixture_cmd = shlex.quote(str(fixture))
            assert 'pmset' not in removal and removal.count('--restore-sleep') == 1
            removal = removal.replace("'/Library/PrivilegedHelperTools/com.coddle.helper' --restore-sleep", fixture_cmd + ' power')
            journal = work / "sleep-journal"
            journal.touch()
            removal = removal.replace('/var/db/com.coddle.helper.sleep-state', shlex.quote(str(journal)))
            removal = removal.replace('/bin/launchctl bootout system/com.coddle.helper', fixture_cmd + ' bootout')
            removal = removal.replace('/bin/launchctl print system/com.coddle.helper', fixture_cmd + ' print')
            remove_lines = [line for line in removal.splitlines() if line.startswith('/bin/rm -f ')]
            assert len(remove_lines) == 1
            removal = removal.replace(remove_lines[0], fixture_cmd + ' remove')
            assert '/Library/' not in removal and '/var/run/' not in removal
            assert 'pmset' not in removal and 'launchctl' not in removal
            power_count = work / "power-count"
            service_state = work / "service-state"
            removed = work / "removed"
            environment = dict(os.environ, CODDLE_TEST_POWER_COUNT=str(power_count),
                               CODDLE_TEST_SERVICE_STATE=str(service_state), CODDLE_TEST_REMOVED=str(removed),
                               CODDLE_TEST_MODE="fail_final_once")
            power_count.write_text("0")
            service_state.write_text("active")
            first = run(["/bin/bash", "-x", "-c", removal], env=environment)
            assert first.returncode == 1 and service_state.read_text() == "absent" and not removed.exists()
            retry = run(["/bin/bash", "-x", "-c", removal], env=environment)
            assert retry.returncode == 0 and removed.read_text() == "yes" and power_count.read_text() == "2"
            (args.output_dir / "helper-uninstall-retry.log").write_text(first.stderr + retry.stderr)
            log("PASS: uninstall recovery failure preserves files; retry confirms service absent, restores recorded state, then removes files")
            for mode in ("bootout_failure", "probe_failure"):
                removed.unlink(missing_ok=True)
                power_count.write_text("0")
                service_state.write_text("active")
                environment["CODDLE_TEST_MODE"] = mode
                failed = run(["/bin/bash", "-x", "-c", removal], env=environment)
                assert failed.returncode == 5 and not removed.exists() and power_count.read_text() == "0"
                (args.output_dir / f"helper-uninstall-{mode}.log").write_text(failed.stderr)
            log("PASS: genuine bootout failure or inconclusive service probe never proceeds to deletion")
            journal.unlink()
            environment["CODDLE_TEST_MODE"] = "normal"
            removed.unlink(missing_ok=True)
            power_count.write_text("0")
            service_state.write_text("active")
            unowned = run(["/bin/bash", "-x", "-c", removal], env=environment)
            assert unowned.returncode == 0 and removed.exists() and power_count.read_text() == "0"
            log("PASS: uninstall without ownership record performs no power writes")
        log("PASS: scoped installer-integrity and substituted uninstall control flow; no administrator installation, payload execution, launchctl or power writes")
    except BaseException:
        log(traceback.format_exc())
        raise
    finally:
        (args.output_dir / "helper-install-regression.log").write_text("\n".join(transcript) + "\n")


if __name__ == "__main__":
    main()
