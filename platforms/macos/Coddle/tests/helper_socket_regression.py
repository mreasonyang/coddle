#!/usr/bin/env python3
"""Exercise the production helper with compile-time isolated, non-root power I/O."""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
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

    def eventually(predicate, seconds=4):
        deadline = time.monotonic() + seconds
        while not predicate():
            assert time.monotonic() < deadline, "condition did not become true"
            time.sleep(0.02)

    try:
        assert os.geteuid() != 0, "fixture intentionally refuses root"
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="helper-fixture-", dir=args.output_dir) as directory:
            work = Path(directory)
            binary = work / "helper"
            build = subprocess.run([
                "swiftc", "-O", "-D", "CODDLE_HELPER_TESTING",
                "-module-cache-path", str(args.output_dir / "module-cache-helper"),
                str(source / "helper/main.swift"), str(source / "helper/SleepLease.swift"), str(source / "Sources/HelperCommand.swift"),
                str(source / "Sources/BoundedIO.swift"),
                "-o", str(binary), "-framework", "Foundation",
            ], capture_output=True, text=True, timeout=60)
            if build.stdout or build.stderr:
                log(build.stdout + build.stderr)
            assert build.returncode == 0, "helper build failed"
            log("PASS: compiled production helper, dispatcher, and bounded I/O")
            clean_env = {k: v for k, v in os.environ.items() if not k.startswith("CODDLE_HELPER_")}
            refused = subprocess.run([str(binary)], env=clean_env, capture_output=True, timeout=5)
            assert refused.returncode != 0
            log("PASS: test binary cannot reach real pmset without isolated flags")
            state = work / "state"
            failure = work / "fail-off"
            journal = work / "journal"
            read_failure = work / "fail-read"
            # UNIX sockaddr_un is short on macOS; keep socket path independent
            # from the artifact directory's intentionally long retained path.
            socket_directory = tempfile.TemporaryDirectory(prefix="ch-", dir="/tmp")
            path = Path(socket_directory.name) / "s"
            index = 0

            @contextmanager
            def server(ttl=1.2, delay=0, initial="0", reset=True):
                nonlocal index
                index += 1
                path.unlink(missing_ok=True)
                if reset:
                    state.write_text(initial)
                    journal.unlink(missing_ok=True)
                env = dict(clean_env, CODDLE_HELPER_ALLOW_NONROOT="1", CODDLE_HELPER_DRYRUN="1",
                           CODDLE_HELPER_TEST_STATE=str(state), CODDLE_HELPER_TEST_JOURNAL=str(journal),
                           CODDLE_HELPER_TEST_READ_FAILURE=str(read_failure), CODDLE_HELPER_TEST_LEASE_SECONDS=str(ttl),
                           CODDLE_HELPER_TEST_ENABLE_DELAY=str(delay), CODDLE_HELPER_TEST_OFF_FAILURE=str(failure))
                with (args.output_dir / f"helper-server-{index}.log").open("w") as stderr:
                    process = subprocess.Popen([str(binary), str(path)], env=env,
                                               stdout=subprocess.DEVNULL, stderr=stderr)
                    try:
                        eventually(lambda: path.exists() or process.poll() is not None)
                        assert process.poll() is None, "server exited before startup"
                        yield process
                    finally:
                        if process.poll() is None:
                            process.terminate()
                            try:
                                process.wait(timeout=6)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                process.wait(timeout=5)

            def connect(timeout=5):
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.settimeout(timeout)
                client.connect(str(path))
                return client

            def call(command, timeout=5):
                with connect(timeout) as client:
                    client.sendall((command + "\n").encode())
                    return client.recv(4096).decode().strip()

            with server() as process:
                assert state.read_text() == "0"
                for command, expected in [
                    ("ping", "ok"), ("ping extra", "err bad-args"),
                    ("set_disablesleep 1", "err lease-required"),
                    ("lease_disablesleep 0", "err bad-args"),
                    ("lease_disablesleep 1;id", "err bad-args"),
                    ("x" * 4097, "err invalid-request"),
                ]:
                    assert call(command) == expected, command[:50]
                with connect() as client:
                    client.sendall(b"lease_disablesleep 1")
                    client.shutdown(socket.SHUT_WR)
                    assert client.recv(4096) == b"err invalid-request\n"
                assert state.read_text() == "0"
                log("PASS: startup OFF; legacy ON, injection, oversized and unterminated requests cannot write")
                assert call("lease_disablesleep 1") == "ok"
                assert state.read_text() == "1"
                eventually(lambda: state.read_text() == "0")
                log("PASS: abandoned/crashed client lease expires to OFF")
                assert call("lease_disablesleep 1") == "ok"
                for _ in range(4):
                    time.sleep(0.5)
                    assert call("lease_disablesleep 1") == "ok"
                    assert state.read_text() == "1"
                assert call("set_disablesleep 0") == "ok"
                assert state.read_text() == "0"
                log("PASS: renewals survive original expiry and explicit global OFF clears lease")
                assert call("lease_disablesleep 1") == "ok"
                failure.touch()
                time.sleep(1.7)
                assert state.read_text() == "1"
                failure.unlink()
                eventually(lambda: state.read_text() == "0")
                log("PASS: expired lease retries a failed OFF until cleanup succeeds")
                # Eight clients consume the entire fixed admission budget.
                clients = [connect() for _ in range(8)]
                time.sleep(0.1)
                extra = connect(timeout=1)
                try:
                    assert extra.recv(4096) == b""
                except ConnectionResetError:
                    pass
                finally:
                    extra.close()
                started = time.monotonic()
                for _ in range(8):
                    time.sleep(0.35)
                    for client in clients:
                        try:
                            client.sendall(b"p")
                        except (BrokenPipeError, ConnectionResetError):
                            pass
                for client in clients:
                    try:
                        assert client.recv(4096) in (b"err invalid-request\n", b"")
                    except ConnectionResetError:
                        pass
                    finally:
                        client.close()
                assert time.monotonic() - started < 4.5
                assert call("ping") == "ok"
                log("PASS: ninth client rejected; slow-drip clients expire at absolute deadline; service recovers")
                assert call("lease_disablesleep 1") == "ok"
                process.kill()
                process.wait(timeout=5)
                assert state.read_text() == "1"
            with server(reset=False):
                assert state.read_text() == "0"
                assert not journal.exists()
                log("PASS: daemon restart clears state remaining after SIGKILL")
            with server(ttl=0.7, delay=1.1):
                assert call("lease_disablesleep 1") == "err lease-expired"
                assert state.read_text() == "0"
                log("PASS: delayed ON completing after its accepted lease deadline immediately resets OFF")
            with server(ttl=10, delay=3):
                client = connect(timeout=2)
                client.sendall(b"lease_disablesleep 1\n")
                assert call("ping", timeout=1) == "ok"
                try:
                    client.recv(4096)
                except socket.timeout:
                    pass
                else:
                    raise AssertionError("delayed ON unexpectedly replied before client deadline")
                finally:
                    client.close()
                assert call("set_disablesleep 0") == "ok"
                assert state.read_text() == "0"
                log("PASS: timed-out ON finishes before later OFF; concurrent ping remains responsive")
            with server():
                assert call("lease_disablesleep 1") == "ok"
            assert state.read_text() == "0"
            log("PASS: graceful daemon termination resets OFF")
            for ending in ("release_sleep", "set_disablesleep 0", "expiry", "exit", "crash"):
                with server(initial="1") as process:
                    assert state.read_text() == "1" and not journal.exists()
                    assert call("release_sleep") == "ok"
                    assert call("lid_state") == "ok lid=0"
                    assert call("lease_sleep 1") == "ok"
                    assert journal.read_text() == "v1 baseline=1\n"
                    assert call("lid_state") == "ok lid=1"
                    if ending in ("release_sleep", "set_disablesleep 0"):
                        assert call(ending) == "ok"
                        assert call(ending) == "ok"
                        assert call("lid_state") == "ok lid=0"
                        assert not journal.exists()
                    elif ending == "expiry":
                        eventually(lambda: not journal.exists())
                        assert call("lid_state") == "ok lid=0"
                    elif ending == "crash":
                        process.kill(); process.wait(timeout=5)
                assert state.read_text() == "1", ending
                if ending == "crash":
                    with server(reset=False):
                        assert state.read_text() == "1" and not journal.exists()
                        assert call("lid_state") == "ok lid=0"
                log(f"PASS: existing external ON preserved across {ending}")
            with server():
                state.write_text("unknown")
                assert call("lease_sleep 1") == "err state-unavailable"
                assert not journal.exists()
                state.write_text("0")
                read_failure.touch()
                assert call("lease_sleep 1") == "err state-unavailable"
                read_failure.unlink()
                assert call("lease_sleep 1") == "ok"
                failure.touch()
                assert call("release_sleep") == "err restore-failed"
                assert call("lid_state") == "err state-unconfirmed" and journal.exists()
                failure.unlink()
                eventually(lambda: not journal.exists())
                assert state.read_text() == "0"
                log("PASS: unknown baseline refuses ON; failed recovery stays pending and retries")
            with server():
                journal.symlink_to(state)
                assert call("lease_sleep 1") in ("err journal-unavailable", "err cleanup-pending")
                assert call("release_sleep") == "err journal-unavailable"
                assert state.read_text() == "0"
                journal.unlink()
                eventually(lambda: call("release_sleep") == "ok")
                journal.write_text("corrupt")
                journal.chmod(0o600)
                assert call("lease_sleep 1") in ("err journal-unavailable", "err cleanup-pending")
                assert state.read_text() == "0"
                journal.unlink()
                log("PASS: symlink and corrupt ownership records never cause power writes")
            with server(initial="1"):
                assert call("lease_sleep 1") == "ok"
                state.write_text("0")
                assert call("release_sleep") == "ok" and state.read_text() == "0"
                log("PASS: external OFF during our lease is preserved")
            with server() as process:
                assert call("lease_sleep 1") == "ok"
                assert journal.stat().st_mode & 0o777 == 0o600
                process.kill(); process.wait(timeout=5)
            offline_env = dict(clean_env, CODDLE_HELPER_ALLOW_NONROOT="1", CODDLE_HELPER_DRYRUN="1",
                               CODDLE_HELPER_TEST_STATE=str(state), CODDLE_HELPER_TEST_JOURNAL=str(journal))
            restored = subprocess.run([str(binary), "--restore-sleep"], env=offline_env,
                                      capture_output=True, timeout=5)
            assert restored.returncode == 0 and state.read_text() == "0" and not journal.exists()
            state.write_text("1")
            unowned = subprocess.run([str(binary), "--restore-sleep"], env=offline_env,
                                     capture_output=True, timeout=5)
            assert unowned.returncode == 0 and state.read_text() == "1"
            log("PASS: offline uninstall recovery restores owned state; absent journal preserves external ON")
            with server():
                journal.write_text("v1 baseline=0\n")
                journal.chmod(0o666)
                assert call("lease_sleep 1") in ("err journal-unavailable", "err cleanup-pending")
                assert state.read_text() == "0"
                journal.unlink()
                log("PASS: untrusted journal permissions refuse acquisition without writing ON")
            socket_directory.cleanup()
        log("PASS: helper socket regression; no installation or real power writes")
    except BaseException:
        log(traceback.format_exc())
        raise
    finally:
        (args.output_dir / "helper-socket-regression.log").write_text("\n".join(transcript) + "\n")


if __name__ == "__main__":
    main()
