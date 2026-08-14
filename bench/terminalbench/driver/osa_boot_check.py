#!/usr/bin/env python3
"""Install-time gate: prove the injected OSA release can actually *boot*.

Why this exists
---------------

The install step used to run ``osagent version`` and treat success as proof
that the artefact worked. It is not. ``bin/osagent version`` is::

    exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.version()"

and a Mix release's ``eval`` starts the VM and loads code but does **not** start
the OTP application tree. Nothing that fails at boot -- a NIF whose ``.so`` is
missing, corrupt, or built against a newer glibc than the task image ships, a
supervisor that raises in ``init/1``, a missing system binary -- is exercised by
it. So an artefact that cannot boot passed the gate, reached the episode, and
scored a zero that Harbor attributed to the model. That happened on all 89 tasks
of one run: ``install_or_boot_failed`` everywhere, on a release whose ``version``
command had succeeded on four different base images.

This probe checks the *real* capability the episode needs, by the same route the
episode uses: boot ``osagent serve`` and wait for its HTTP ``/health`` to answer.
Reaching ``/health`` means the application tree started, which means every NIF
loaded at boot (crypto, exqlite, bcrypt) resolved and every supervisor survived
``init``. If it does not answer, this exits non-zero and Harbor records an
install failure instead of charging the model for a zero.

It also reports which ``libcrypto``/``libssl`` the booted VM actually mapped, so
the release's vendored copies are demonstrably in use rather than assumed.

Stdlib only: task images may have no pip and no egress.
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

VENDOR_SONAMES = ("libcrypto.so", "libssl.so")


def log(msg: str) -> None:
    print(f"[osa-boot-check] {msg}", flush=True)


def _health(port: int) -> tuple[int, str]:
    with urllib.request.urlopen(
        f"http://127.0.0.1:{port}/health", timeout=5
    ) as r:
        return r.status, r.read().decode("utf-8", "replace")[:200]


def _beam_pids(release: Path) -> list[int]:
    """PIDs of processes running out of this release (the VM is a grandchild)."""
    pids = []
    root = str(release)
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            cmdline = (entry / "cmdline").read_bytes().decode("utf-8", "replace")
        except OSError:
            continue
        if root in cmdline and "beam" in cmdline:
            pids.append(int(entry.name))
    return pids


def _mapped_libs(pids: list[int]) -> dict[str, str]:
    """soname -> resolved path, as actually mapped by the running VM."""
    found: dict[str, str] = {}
    for pid in pids:
        try:
            maps = Path(f"/proc/{pid}/maps").read_text("utf-8", "replace")
        except OSError:
            continue
        for line in maps.splitlines():
            path = line.split(" ", 5)[-1].strip() if " " in line else ""
            if not path.startswith("/"):
                continue
            base = os.path.basename(path)
            for soname in VENDOR_SONAMES:
                if base.startswith(soname):
                    found.setdefault(soname, path)
    return found


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("release", type=Path)
    ap.add_argument("--port", type=int, default=19898)
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument(
        "--require-vendor",
        action="store_true",
        help="fail unless the VM mapped the release's own vendored libcrypto",
    )
    args = ap.parse_args()

    release: Path = args.release
    binary = release / "bin" / "osagent"
    if not binary.exists():
        log(f"FAIL: {binary} does not exist")
        return 2

    logdir = Path(tempfile.mkdtemp(prefix="osa-boot-check-"))
    serve_log = logdir / "serve.log"

    env = os.environ.copy()
    env["OSA_HTTP_PORT"] = str(args.port)
    env.setdefault("HOME", "/root")
    # Same two quirks the episode driver has to set: erlexec's Erlang side reads
    # USER to decide whether it is root, and its port program exits 4 when SHELL
    # is unset. Probing without them would test a different configuration than
    # the one the episode runs.
    env.setdefault("USER", "root")
    env.setdefault("SHELL", "/bin/bash")

    log(f"booting {binary} serve on port {args.port} (timeout {args.timeout}s)")
    with serve_log.open("wb") as fh:
        proc = subprocess.Popen(
            [str(binary), "serve"],
            stdout=fh,
            stderr=subprocess.STDOUT,
            env=env,
            cwd=str(release),
            start_new_session=True,
        )

        t0 = time.monotonic()
        deadline = t0 + args.timeout
        healthy = False
        why = "never became healthy"
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                why = f"serve exited during boot with code {proc.returncode}"
                break
            try:
                status, body = _health(args.port)
                if status == 200:
                    healthy = True
                    log(f"OK: /health answered {status} in "
                        f"{time.monotonic() - t0:.1f}s: {body}")
                    break
                why = f"/health answered HTTP {status}"
            except (urllib.error.URLError, OSError):
                pass
            time.sleep(2)

        libs: dict[str, str] = {}
        if healthy:
            libs = _mapped_libs(_beam_pids(release))
            for soname, path in sorted(libs.items()):
                inside = path.startswith(str(release))
                log(f"{soname} -> {path} ({'release vendor' if inside else 'system'})")

        if proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                proc.wait(timeout=20)
            except Exception:  # noqa: BLE001
                proc.kill()

    if not healthy:
        log(f"FAIL: {why}")
        try:
            lines = serve_log.read_text("utf-8", "replace").splitlines()
        except OSError:
            lines = ["<no serve log>"]
        # A failed boot ends in dozens of "Application x exited: :stopped"
        # notices, so a plain tail buries the cause. Surface the diagnostic
        # lines first, then the tail.
        interesting = [
            l for l in lines
            if ("error" in l.lower() or "GLIBC" in l or "** (" in l
                or "failed" in l.lower() or "cannot" in l.lower()
                or "no such file" in l.lower())
            and "exited: :stopped" not in l
        ]
        log(f"--- diagnostic lines from {serve_log} ---")
        for line in interesting[:40]:
            print(line, flush=True)
        log("--- tail ---")
        for line in lines[-25:]:
            print(line, flush=True)
        return 3

    if args.require_vendor:
        vendor = release / "vendor"
        if vendor.is_dir() and any(vendor.glob("libcrypto.so*")):
            crypto = libs.get("libcrypto.so")
            if crypto is None:
                log("FAIL: VM mapped no libcrypto at all -- cannot confirm "
                    "the vendored copy is in use")
                return 4
            if not crypto.startswith(str(vendor)):
                log(f"FAIL: VM mapped {crypto}, not the vendored "
                    f"{vendor}/libcrypto.so* -- LD_LIBRARY_PATH is not wired, "
                    "so the release silently depends on the task image's "
                    "system libcrypto")
                return 4

    log("boot check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
