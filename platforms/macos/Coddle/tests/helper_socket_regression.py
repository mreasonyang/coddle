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
                str(source / "helper/main.swift"), str(source / "Sources/HelperCommand.swift"),
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
            # UNIX sockaddr_un is short on macOS; keep socket path independent
            # from the artifact directory's intentionally long retained path.
            socket_directory = tempfile.TemporaryDirectory(prefix="ch-", dir="/tmp")
            path = Path(socket_directory.name) / "s"
            index = 0

            @contextmanager
            def server(ttl=1.2, delay=0):
                nonlocal index
                index += 1
                path.unlink(missing_ok=True)
                state.write_text("1")  # daemon startup must reset stale ON
                env = dict(clean_env, CODDLE_HELPER_ALLOW_NONROOT="1", CODDLE_HELPER_DRYRUN="1",
                           CODDLE_HELPER_TEST_STATE=str(state), CODDLE_HELPER_TEST_LEASE_SECONDS=str(ttl),
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
            with server():
                assert state.read_text() == "0"
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
            socket_directory.cleanup()
        log("PASS: helper socket regression; no installation or real power writes")
    except BaseException:
        log(traceback.format_exc())
        raise
    finally:
        (args.output_dir / "helper-socket-regression.log").write_text("\n".join(transcript) + "\n")


if __name__ == "__main__":
    main()
