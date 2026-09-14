#!/usr/bin/env python3
"""Real tmux 3.6a, real scrollback, detach + reattach at a different size.

Targets the exact confirmed field shape (team-lead, live-machine pull):
  - macOS, tmux 3.6a, TERM=tmux-256color.
  - Long-lived panes (days old, full of real scrollback), detached and
    reattached repeatedly across days, from different devices -- i.e. at
    DIFFERENT SIZES.

Why pyte-based probes are structurally blind to this: pyte does not implement
DECSET 1049 at all, so nothing painted into a "restored primary buffer" can
ever be observed through it. This harness uses a REAL tmux server instead,
which does implement 1049 (and answers DSR from its own per-pane virtual
terminal, not by round-tripping to whatever is attached -- so no fake terminal
emulation is needed on our end for that part).

Shape under test:
  1. Start an isolated tmux server (`-L`, so it can never collide with or be
     confused for the developer's real server) with a detached session running
     a shell that first prints a large wrapping scrollback prelude, then execs
     osagent against the stub backend, at an initial size W1xH1.
  2. Attach a real client (via a PTY of our own) at W1xH1 -- matching, so
     attaching this first client causes no resize -- and wait for the
     composer to appear.
  3. Detach that client (`tmux detach-client`), matching the user's routine
     workflow of leaving a session running unattended.
  4. Attach a SECOND, independent client PTY at a DIFFERENT size W2xH2. tmux
     resizes the window to the new client's size, delivers SIGWINCH to
     osagent, and repaints the pane from its own grid for the new client --
     exactly the "reattach from a different device at a different size" shape
     confirmed from the field.
  5. Assert on `tmux capture-pane -p -S -N`, which includes SCROLLBACK, not
     just the visible screen -- a fossil chrome stranded above the live
     region would show there even if the visible screen looks perfectly
     correct.

Run: `python3 test/pty/tmux_reattach_fossil_probe.py`
"""

from __future__ import annotations

import os
import pty
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import scrollback_prelude  # noqa: E402
from osa_pty import DEFAULT_BIN, SINGLETON_BANDS  # noqa: E402
from stub_backend import StubBackend  # noqa: E402

STUB_PORT = 12847
SOCKET = "osadup190_fossil"
SESSION = "dup190"


def sh(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["tmux", "-L", SOCKET, *args],
        capture_output=True,
        text=True,
        check=check,
    )


def capture(lines: int = 300) -> str:
    r = sh("capture-pane", "-p", "-t", SESSION, "-S", f"-{lines}", check=False)
    return r.stdout


def counts(text: str) -> dict[str, int]:
    rendered = [line.rstrip() for line in text.splitlines()]
    out: dict[str, int] = {}
    for name, pat in SINGLETON_BANDS.items():
        if name == "composer_top":
            continue  # ambiguous with turn separators; see duplicate_probe.py
        out[name] = sum(1 for line in rendered if pat.search(line))
    return out


class ClientPty:
    """A real PTY driving `tmux attach-session`, at a fixed size."""

    def __init__(self, cols: int, rows: int) -> None:
        self.cols, self.rows = cols, rows
        self.pid: int | None = None
        self.fd: int | None = None

    def __enter__(self) -> "ClientPty":
        pid, fd = pty.fork()
        if pid == 0:  # child
            os.execvp(
                "tmux",
                ["tmux", "-L", SOCKET, "attach-session", "-t", SESSION],
            )
            os._exit(127)
        self.pid, self.fd = pid, fd
        import fcntl
        import struct
        import termios

        fcntl.ioctl(
            fd, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.cols, 0, 0)
        )
        # Nudge tmux to notice the size via a second SIGWINCH-equivalent, in
        # case the ioctl raced the client's own initial handshake.
        time.sleep(0.3)
        fcntl.ioctl(
            fd, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.cols, 0, 0)
        )
        return self

    def drain(self, duration: float) -> None:
        """Read and discard output so the pty's buffer never fills and blocks
        tmux's writes to the client."""
        import select

        assert self.fd is not None
        deadline = time.time() + duration
        while time.time() < deadline:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    os.read(self.fd, 65536)
                except OSError:
                    return

    def __exit__(self, *_exc) -> None:
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None
        if self.pid is not None:
            try:
                os.kill(self.pid, 9)
                os.waitpid(self.pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            self.pid = None


def main() -> int:
    failures: list[str] = []
    sh("kill-server", check=False)

    with StubBackend(STUB_PORT) as backend:
        base_url = backend.base_url
        text = scrollback_prelude.prelude_text(lines=80)
        binary = str(DEFAULT_BIN)
        cmd = (
            f"printf %s {shlex.quote(text)}; "
            f"OSA_URL={shlex.quote(base_url)} exec {shlex.quote(binary)}"
        )
        W1, H1 = 100, 30
        W2, H2 = 100, 55  # a materially different size, as a different device would be

        r = sh(
            "new-session", "-d", "-s", SESSION, "-x", str(W1), "-y", str(H1),
            "/bin/sh", "-c", cmd,
        )
        print("new-session:", r.returncode, r.stderr.strip())

        try:
            # -- stage 1: attach the first client, matching size, wait for boot.
            with ClientPty(W1, H1) as c1:
                deadline = time.time() + 20
                booted = False
                while time.time() < deadline:
                    c1.drain(0.25)
                    if counts(capture(400)).get("composer", 0) >= 1:
                        booted = True
                        break
                if not booted:
                    print("FAIL: osagent never booted in tmux pane")
                    print(capture(400))
                    return 1
                c1.drain(2.0)
                before = counts(capture(400))
                print("boot, client A attached (matching size):", before)
                bad = {k: v for k, v in before.items() if v != 1}
                if bad:
                    failures.append(f"after boot (client A): {bad}")

            # -- stage 2: client A detached (context manager __exit__ killed
            # its pty; also explicitly detach-client server-side in case tmux
            # still thinks it's attached via a stale socket).
            sh("detach-client", "-t", SESSION, check=False)
            time.sleep(1.0)

            # -- stage 2b: resize the WINDOW while genuinely NO client is
            # attached. This is the shape behind the field evidence -- a real
            # user's session printed crossterm's "cursor position could not be
            # read within a normal duration" error, i.e. a DSR query with
            # nothing able to answer it. `resize-window` forces the pane's pty
            # (and therefore SIGWINCH to osagent) even with zero clients
            # attached, which a live client's outer-pty resize never tests --
            # there, tmux itself always answers DSR from its per-pane virtual
            # terminal regardless of whether a real client is attached, but
            # this proves the geometry change and any cursor query it
            # triggers both happen while nothing could plausibly desync
            # tmux's own model, isolating the "no client" case on its own.
            W3, H3 = 100, 20
            sh("resize-window", "-t", SESSION, "-x", str(W3), "-y", str(H3), check=False)
            time.sleep(2.0)
            mid = counts(capture(500))
            print(f"resized to {W3}x{H3} while fully detached (no client):", mid)
            bad = {k: v for k, v in mid.items() if v != 1}
            if bad:
                failures.append(f"resized while detached, no client: {bad}")

            # -- stage 3: attach a second, independent client at a DIFFERENT
            # size -- the "reattach from a different device" shape.
            with ClientPty(W2, H2) as c2:
                c2.drain(3.0)
                after = counts(capture(500))
                print(f"after reattach at {W2}x{H2} (different size):", after)
                bad = {k: v for k, v in after.items() if v != 1}
                if bad:
                    failures.append(f"after reattach at {W2}x{H2}: {bad}")
                    print("--- full scrollback+screen capture ---")
                    print(capture(500))
        finally:
            sh("kill-server", check=False)

    print("\n=== summary ===")
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("no duplication observed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
