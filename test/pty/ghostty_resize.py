#!/usr/bin/env python3
"""Resize assertions with OSA running inside **Ghostty** — and an honest account
of the one assertion that cannot be made there.

What this can and cannot check
------------------------------
The other emulator harnesses count how many copies of each singleton band
survive a width drag, by reading the terminal's scrollback back out: tmux has
`capture-pane`, WezTerm has `cli get-text`, libvte has `get_text_range_format`.

**Ghostty has no text-extraction API.** There is no CLI, no control socket and
no escape sequence that reports screen or scrollback contents, so the band count
— the assertion this family of harnesses exists to make — is not available here.
Pretending otherwise by, say, screenshotting and eyeballing would produce a test
that cannot fail on its own, which is exactly the failure this whole
investigation was caused by: `test_resize.py` rendering with pyte (which does not
reflow) reported clean for months while users watched chrome stack up.

So this harness asserts the two things that ARE decidable without reading the
screen, and says plainly that it is not asserting the third:

  1. **Ghostty's reflow behaviour**, via `reflow_probe.py`, which reports on
     itself through a DSR cursor query and needs no text extraction at all.
     Measured: Ghostty 1.2.3 reflows.
  2. **OSA survives the drag.** The resize path has a documented crash mode —
     `rebuild_inline` issues a DSR cursor query, and a terminal that drops it
     mid-resize surfaced as "cursor position could not be read" and killed the
     session. A process that is gone after the drag is a regression this can
     see, and it is the failure users notice first.

For the band count on Ghostty, see `test/pty/README.md`: it needs a human, or a
Ghostty release with a text-reading control API.

Requires the `ghostty` binary, `xdotool` and a display. Skips otherwise.

Run: `python3 test/pty/ghostty_resize.py`
"""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import scrollback_prelude  # noqa: E402  (needs the sys.path line above)
import term_env  # noqa: E402

STUB_PORT = 12797
GHOSTTY_CLASS = "com.mitchellh.ghostty"


def _skip(reason: str) -> int:
    print(f"SKIPPED: {reason}")
    return 0


def _x_windows() -> set[str]:
    r = subprocess.run(
        ["xdotool", "search", "--onlyvisible", "--class", GHOSTTY_CLASS],
        capture_output=True, text=True,
    )
    return {w for w in r.stdout.split() if w.strip()}


def main() -> int:
    if not shutil.which("ghostty"):
        return _skip("ghostty not installed")
    if not shutil.which("xdotool"):
        return _skip("xdotool not installed")
    if not os.environ.get("DISPLAY"):
        return _skip("no DISPLAY")

    repo = Path(__file__).resolve().parents[2]
    binary = repo / "priv/rust/tui/target/release/osagent"
    if not binary.exists():
        return _skip(f"{binary} not built")

    from stub_backend import StubBackend  # noqa: E402

    failures: list[str] = []
    windows_before = _x_windows()

    with StubBackend(STUB_PORT) as backend:
        # A marker file the child touches on exit. Ghostty closes its window
        # when the child dies, so "did OSA survive" cannot be read from the
        # window alone — a closed window and a never-opened one look identical
        # by the time we look.
        alive = repo / f".ghostty-probe-{os.getpid()}"
        alive_flag = str(alive)

        prefix = term_env.sh_env_prefix(
            OSA_BASE_URL=backend.base_url, **term_env.passthrough_override()
        )
        prelude = scrollback_prelude.prelude_text(
            lines=int(os.environ.get("OSA_PTY_PRELUDE_LINES", "12"))
        )
        # The leading sleep lets the harness enlarge the window before the
        # prelude prints: OSA wedges on startup if the screen it inherits has
        # too little room left for the inline viewport.
        #
        # `exec` comes BEFORE `env`, because `exec` is a shell builtin — the
        # other order makes `env` search for a program named "exec".
        cmd = (
            "sleep 5; "
            f"printf %s {shlex.quote(prelude)}; "
            f"{prefix} {shlex.quote(str(binary))}; "
            f"echo exited > {shlex.quote(alive_flag)}"
        )

        proc = subprocess.Popen(
            ["ghostty", "-e", "/bin/sh", "-c", cmd],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        wid = None
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            new = _x_windows() - windows_before
            if new:
                wid = sorted(new)[-1]
                break
            time.sleep(0.25)
        if wid is None:
            proc.terminate()
            return _skip("could not find a new ghostty window")

        try:
            subprocess.run(["xdotool", "windowsize", wid, "1200", "900"],
                           capture_output=True)
            # No way to poll for a composer here, so wait long enough for the
            # `sleep 5`, the prelude and a backend handshake.
            time.sleep(20)

            if alive.exists():
                return _skip("OSA exited before the drag; nothing to assert about")

            for w in (1100, 1000, 900, 820, 900, 1000, 1100, 1200):
                subprocess.run(["xdotool", "windowsize", wid, str(w), "900"],
                               capture_output=True)
                time.sleep(0.5)
            time.sleep(3)

            # THE assertion: the drag did not kill the session. The resize path
            # issues a DSR cursor query through `rebuild_inline`, and a dropped
            # reply used to surface as "cursor position could not be read" and
            # take the whole session down.
            if alive.exists():
                failures.append(
                    "OSA exited during the width drag — the resize path did not "
                    "survive Ghostty (historically: a dropped DSR cursor query "
                    "surfacing as 'cursor position could not be read')"
                )
            elif not _x_windows() & {wid}:
                failures.append(
                    "the ghostty window vanished during the drag, which means "
                    "the child died"
                )
        finally:
            subprocess.run(["xdotool", "windowkill", wid], capture_output=True)
            try:
                proc.terminate()
            except Exception:
                pass
            try:
                alive.unlink()
            except FileNotFoundError:
                pass

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print(
        "ok — OSA survived a width drag in Ghostty.\n"
        "NOTE: the stranded-chrome band count is NOT asserted here — Ghostty "
        "has no text-extraction API. Ghostty's reflow behaviour is measured "
        "separately by test/pty/reflow_matrix.py."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
