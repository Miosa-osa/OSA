#!/usr/bin/env python3
"""Real tmux, boot -> a turn -> /clear -> another turn, assert on FULL scrollback.

Team-lead's decisive reproduction (`tmux capture-pane -t <pane> -p -S -400`
against live, long-lived user panes) found 1-3 stacked, chrome-shaped blocks
per pane, ACCUMULATING over the pane's lifetime -- and the oldest copy in one
pane carried a stale session title that the newer copies did not, implying a
`/clear` ran between the first fossil and the later ones.

This is the regression shape that repro implies, driven directly rather than
inferred: boot, run one real turn to completion (so the status bar picks up
session-specific state), `/clear`, run a second turn, then read the ENTIRE
scrollback (not just the visible screen -- `duplicate_probe.py` and
`test_resize.py` are both screen-only and are exactly the blind spot the field
evidence exposed) and assert every chrome marker appears EXACTLY ONCE.
"""

from __future__ import annotations

import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from osa_pty import DEFAULT_BIN, SINGLETON_BANDS, USER_HEADER  # noqa: E402
from stub_backend import StubBackend, end_turn, post_mark, posts_since  # noqa: E402

STUB_PORT = 12849
SOCKET = "osadup190_clearfossil"
SESSION = "dup190clear"
W, H = 100, 30


def sh(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["tmux", "-L", SOCKET, *args], capture_output=True, text=True, check=check
    )


def capture(lines: int = 400) -> str:
    r = sh("capture-pane", "-p", "-t", SESSION, "-S", f"-{lines}", check=False)
    return r.stdout


def counts(text: str) -> dict[str, int]:
    """Singleton-band counts across FULL scrollback, corrected for the two
    known ambiguous markers exactly as `duplicate_probe.py` / `test_resize.py`
    do (USER_HEADER also matches `composer`; `composer_top` is byte-identical
    to a turn separator).
    """
    rendered = [line.rstrip() for line in text.splitlines()]
    out: dict[str, int] = {}
    for name, pat in SINGLETON_BANDS.items():
        if name == "composer_top":
            continue
        out[name] = sum(1 for line in rendered if pat.search(line))
    out["composer"] -= sum(1 for line in rendered if USER_HEADER.search(line))
    return out


def send(keys: str) -> None:
    sh("send-keys", "-t", SESSION, "-l", keys)


def enter() -> None:
    sh("send-keys", "-t", SESSION, "Enter")


def main() -> int:
    failures: list[str] = []
    sh("kill-server", check=False)

    with StubBackend(STUB_PORT) as backend:
        base_url = backend.base_url
        binary = str(DEFAULT_BIN)
        cmd = f"OSA_URL={shlex.quote(base_url)} exec {shlex.quote(binary)}"

        r = sh(
            "new-session", "-d", "-s", SESSION, "-x", str(W), "-y", str(H),
            "/bin/sh", "-c", cmd,
        )
        print("new-session:", r.returncode, r.stderr.strip())

        try:
            # -- boot --
            deadline = time.time() + 20
            booted = False
            while time.time() < deadline:
                if counts(capture()).get("composer", 0) >= 1:
                    booted = True
                    break
                time.sleep(0.25)
            if not booted:
                print("FAIL: osagent never booted in tmux pane")
                print(capture())
                return 1
            time.sleep(1.0)
            after_boot = counts(capture())
            print("after boot:", after_boot)
            bad = {k: v for k, v in after_boot.items() if v != 1}
            if bad:
                failures.append(f"after boot: {bad}")

            # -- turn 1: submit a real prompt, let it complete --
            mark = post_mark()
            send("first turn please")
            time.sleep(0.3)
            enter()
            waited = 0.0
            while waited < 10.0 and not posts_since(mark, "/api/v1/orchestrate"):
                time.sleep(0.25)
                waited += 0.25
            if not posts_since(mark, "/api/v1/orchestrate"):
                print("FAIL: first turn never reached the backend")
                print(capture())
                return 1
            end_turn("first answer")
            time.sleep(1.5)
            after_turn1 = counts(capture())
            print("after turn 1:", after_turn1)
            bad = {k: v for k, v in after_turn1.items() if v != 1}
            if bad:
                failures.append(f"after turn 1: {bad}")

            # -- /clear: typing opens the slash-completion popup, so the FIRST
            # Enter accepts the completion (does not submit); the SECOND
            # actually submits, exactly as `_submit_slash` in test_resize.py --
            send("/clear")
            time.sleep(0.5)
            enter()
            time.sleep(0.5)
            enter()
            time.sleep(1.5)
            after_clear = counts(capture())
            print("after /clear:", after_clear)
            bad = {k: v for k, v in after_clear.items() if v != 1}
            if bad:
                failures.append(f"after /clear: {bad}")

            # -- turn 2: a second real turn, in the post-clear session --
            mark2 = post_mark()
            send("second turn please")
            time.sleep(0.3)
            enter()
            waited = 0.0
            while waited < 10.0 and not posts_since(mark2, "/api/v1/orchestrate"):
                time.sleep(0.25)
                waited += 0.25
            if not posts_since(mark2, "/api/v1/orchestrate"):
                print("FAIL: second turn never reached the backend")
                print(capture())
                return 1
            end_turn("second answer")
            time.sleep(1.5)

            final = capture(400)
            after_turn2 = counts(final)
            print("after turn 2 (final, full scrollback -S -400):", after_turn2)
            bad = {k: v for k, v in after_turn2.items() if v != 1}
            if bad:
                failures.append(f"after turn 2 (FINAL, full scrollback): {bad}")
                print("--- full scrollback dump ---")
                print(final)

        finally:
            sh("kill-server", check=False)

    if failures:
        print("FAILURES:")
        for f in failures:
            print(" -", f)
        return 1
    print("PASS: exactly one chrome block across the entire scrollback at every stage.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
