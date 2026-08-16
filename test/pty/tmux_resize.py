#!/usr/bin/env python3
"""Resize assertions with OSA running **inside tmux** — the reported environment.

Why a third harness
-------------------
`test_resize.py` renders with pyte; `vte_resize.py` embeds real libvte. OSA
passes both, and the stranded-chrome report persisted anyway. The reason is
that neither is what the reporter runs: their session is
`TERM=tmux-256color`, i.e. OSA inside a tmux pane inside some outer terminal.

tmux is not a passthrough. It is its own emulator with its own screen model,
and two of its properties bear directly on this defect:

  * **It does not reflow on width change.** It re-lays-out panes and repaints,
    so anything already committed to its history keeps the width it had.
  * **It can drop a DSR cursor-position query**, which `rebuild_inline` issues
    on every inline viewport rebuild. `event_loop.rs` already says so in
    exactly those words. A dropped reply means the rebuild cannot anchor, and
    an unanchored rebuild is how a copy of the live region gets abandoned.

So this harness drives the real binary in a real tmux pane and reads back the
pane's history with `capture-pane -S`, which is where an abandoned copy lands.

Requires the `tmux` binary. Skips (rather than fails) without it, so the two
always-runnable harnesses stay the baseline.

Run: `python3 test/pty/tmux_resize.py`
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import term_env  # noqa: E402  (needs the sys.path line above)

STUB_PORT = 12793
SESSION = "osa-resize-probe"

BANDS = {
    "welcome banner": "Welcome",
    "composer prompt": "❯",
    "hint row": "/ commands",
    "status bar": "ctx",
}


def _skip(reason: str) -> int:
    print(f"SKIPPED: {reason}")
    return 0


def tmux(*args: str, check: bool = True) -> str:
    """Run a tmux command against an isolated server, never the user's."""
    cmd = ["tmux", "-L", SESSION, *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {r.stderr.strip()}")
    return r.stdout


def pane_id() -> str:
    """Resolve the pane by id rather than assuming window index 0 — a user's
    `base-index` setting makes `session:0` wrong on many configurations."""
    out = tmux("list-panes", "-t", SESSION, "-F", "#{pane_id}").strip()
    return out.splitlines()[0]


def capture(pane: str) -> str:
    """Pane history plus visible screen — where stranded chrome ends up."""
    return tmux("capture-pane", "-p", "-t", pane, "-S", "-5000")


def main() -> int:
    if not shutil.which("tmux"):
        return _skip("tmux not installed")

    repo = Path(__file__).resolve().parents[2]
    binary = repo / "priv/rust/tui/target/release/osagent"
    if not binary.exists():
        return _skip(f"{binary} not built")

    from stub_backend import StubBackend  # noqa: E402

    failures: list[str] = []

    with StubBackend(STUB_PORT) as backend:
        # A dedicated tmux SERVER (-L), so nothing here can touch the user's
        # sessions and a stuck probe cannot outlive this process.
        tmux("kill-server", check=False)
        # tmux sets its own TERM/TMUX in the pane, but the harness's outer
        # identity (TERM_PROGRAM, WEZTERM_*, VTE_VERSION) would otherwise leak
        # straight through it and misidentify the terminal. See `term_env.py`.
        env = term_env.clean_env(
            **term_env.backend_vars(backend.base_url), **term_env.passthrough_override()
        )

        subprocess.run(
            [
                "tmux", "-L", SESSION, "new-session", "-d", "-s", SESSION,
                "-x", "120", "-y", "30", str(binary),
            ],
            env=env,
            check=True,
            capture_output=True,
        )
        try:
            time.sleep(8)
            pane = pane_id()
            before = capture(pane)
            if BANDS["composer prompt"] not in before:
                return _skip("binary did not reach a composer inside tmux")
            if BANDS["welcome banner"] not in before:
                failures.append("welcome banner was absent before the resize")

            # The reported gesture. `resize-window` changes the pane geometry,
            # which is what a real drag of the outer terminal produces.
            for cols in (115, 110, 105, 100, 95, 90):
                tmux("resize-window", "-t", SESSION, "-x", str(cols), "-y", "30")
                time.sleep(0.4)
            for cols in (95, 100, 105, 110, 115, 120):
                tmux("resize-window", "-t", SESSION, "-x", str(cols), "-y", "30")
                time.sleep(0.4)
            time.sleep(3)

            after = capture(pane)

            for name, needle in BANDS.items():
                n = after.count(needle)
                if n != 1:
                    failures.append(
                        f"{name}: {n} copies after the drag (expected exactly 1) — "
                        "chrome was either stranded or erased during resize replay"
                    )

            if failures:
                print("--- tmux pane history after drag (tail) ---")
                print("\n".join(after.splitlines()[-60:]))
        finally:
            tmux("kill-server", check=False)

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print("ok — one copy of each band survives a width drag inside tmux")
    return 0


if __name__ == "__main__":
    sys.exit(main())
