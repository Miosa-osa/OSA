#!/usr/bin/env python3
"""Opt-in real release smoke, only inside a disposable network-isolated container.

Requires a headless installation at /smoke-home/.osa and Python standard library.
Never sends hello_ok or claims backend enrollment, PTY, or desktop support.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import time
import urllib.request


def main():
    assert Path("/.dockerenv").exists(), "Run only in a disposable Docker container"
    routes = Path("/proc/net/route").read_text().splitlines()[1:]
    assert not routes, "Disconnect Docker networking before this runtime smoke"
    home = Path("/smoke-home/.osa")
    evidence = Path("/evidence")
    evidence.mkdir(exist_ok=True)
    assert (home / "install_mode").read_text() == "headless\n"
    assert not (home / "bin/osagent-tui").exists()
    assert not Path("/usr/lib/x86_64-linux-gnu/libasound.so.2").exists()
    for name in (".env", ".open_computers_enabled"):
        assert not (home / name).exists(), name
    env = {"PATH": "/usr/bin:/bin", "HOME": "/smoke-home", "OSA_HOME": str(home), "LANG": "C.UTF-8"}
    osa = str(home / "bin/osa")
    with (evidence / "runtime-cli.log").open("w") as log:
        for args in (["version"], ["opencomputers", "login", "--key",
                    "oc_host_disposable_smoke_only_0000000000000000", "--control-url",
                    "ws://127.0.0.1:18765/api/v1/opencomputers/hosts/ws", "--force"]):
            subprocess.run([osa, *args], env=env, stdout=log, stderr=log, check=True, timeout=40)
        result = subprocess.run([osa], env=env, stdout=log, stderr=log, timeout=10)
        assert result.returncode == 1, "Interactive invocation must fail without starting a daemon"
        assert not (home / "run/backend.pid").exists()
    assert (home / "open_computers.toml").stat().st_mode & 0o777 == 0o600
    with socket.socket() as listener, (evidence / "runtime-serve.log").open("w") as log:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 18765))
        listener.listen(1)
        listener.settimeout(40)
        process = subprocess.Popen([osa, "serve"], env=env | {"OSA_OPEN_COMPUTERS_ENABLED": "true"},
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(10)
                request = b""
                while b"\r\n\r\n" not in request:
                    chunk = connection.recv(4096)
                    assert chunk, "EOF during upgrade"
                    request += chunk
                assert request.startswith(b"GET /api/v1/opencomputers/hosts/ws HTTP/1.1\r\n")
                headers = dict(line.lower().split(b": ", 1) for line in request.split(b"\r\n")[1:] if b": " in line)
                assert headers[b"sec-websocket-protocol"] == b"miosa-opencomputers-v1"
                # The key is case-sensitive; recover its original value.
                key = next(line.split(b": ", 1)[1] for line in request.split(b"\r\n") if line.lower().startswith(b"sec-websocket-key:"))
                accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
                connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\nSec-WebSocket-Protocol: miosa-opencomputers-v1\r\n\r\n")

                def read(n):
                    data = b""
                    while len(data) < n:
                        chunk = connection.recv(n - len(data))
                        assert chunk, "EOF during hello"
                        data += chunk
                    return data

                header = read(2)
                assert header[0] == 0x82 and header[1] & 0x80, "Expected masked binary frame"
                size = header[1] & 127
                if size == 126:
                    size = struct.unpack("!H", read(2))[0]
                elif size == 127:
                    size = struct.unpack("!Q", read(8))[0]
                assert size < 65536
                mask = read(4)
                payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(read(size)))
                assert payload.startswith(b"\x83h\x02w\x05hello"), "Expected ETF hello"
                version = (home / "version").read_text().strip().removeprefix("v")
                assert version.encode() in payload
                assert b"oc_host_disposable_smoke_only_0000000000000000" in payload
                (evidence / "runtime-ws.log").write_text(request.decode() + "\nCLIENT_HELLO " + repr(payload) + "\nLOCAL MOCK ONLY; no backend acceptance asserted\n")
            for attempt in range(30):
                try:
                    with urllib.request.urlopen("http://127.0.0.1:9089/health", timeout=1) as response:
                        health = json.load(response)
                    break
                except OSError:
                    time.sleep(1)
            else:
                raise AssertionError("HTTP health did not become ready")
            assert health["status"] == "ok" and health["version"] == version
            (evidence / "runtime-health.json").write_text(json.dumps(health) + "\n")
            assert process.poll() is None
            for name in (".env", ".open_computers_enabled"):
                assert not (home / name).exists(), name
            print("PASS: no TUI/ALSA; login 0600; environment-only local WS hello and HTTP health; marker absent")
            print("NOT VERIFIED: backend enrollment, remote execution, desktop, or PTY (root PTY unsupported)")
        finally:
            os.killpg(process.pid, 15)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, 9)
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
