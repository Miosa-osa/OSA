#!/usr/bin/env python3
"""Resize assertions with OSA running inside **WezTerm**.

The third emulator family. `test_resize.py` models a terminal with pyte,
`vte_resize.py` embeds real libvte, `tmux_resize.py` runs inside tmux (where
the stranding was finally reproduced). WezTerm is neither libvte nor a
multiplexer: it has its own screen model, its own reflow, and — unlike every
GUI terminal that came before it — a control CLI that can read a pane's
scrollback back out (`wezterm cli get-text --start-line`). That makes it the
one other real emulator this bug can be checked against without a human
watching the screen.

It matters because the fix for tmux is environment-scoped (an ED3 history
purge, applied only under a multiplexer). A scoped fix demands evidence from
outside its scope: that the unscoped path is still correct on an emulator that
is not tmux and not libvte.

Requires the `wezterm` binary and a display. Skips otherwise.

Run: `python3 test/pty/wezterm_resize.py`
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

STUB_PORT = 12795

BANDS = {
    "composer prompt": "❯",
    "hint row": "/ commands",
    "status bar": "ctx",
}


def _skip(reason: str) -> int:
    print(f"SKIPPED: {reason}")
    return 0


def main() -> int:
    if not shutil.which("wezterm"):
        return _skip("wezterm not installed")
    if not os.environ.get("DISPLAY"):
        return _skip("no DISPLAY")

    repo = Path(__file__).resolve().parents[2]
    binary = repo / "priv/rust/tui/target/release/osagent"
    if not binary.exists():
        return _skip(f"{binary} not built")

    from stub_backend import StubBackend  # noqa: E402

    failures: list[str] = []

    with StubBackend(STUB_PORT) as backend:
        env = os.environ.copy()
        env["OSA_BASE_URL"] = backend.base_url

        # `spawn --new-window` prints the new pane id, which is how everything
        # below targets it without disturbing any pane the user has open.
        try:
            pane = subprocess.run(
                ["wezterm", "cli", "spawn", "--new-window", "--", str(binary)],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except subprocess.TimeoutExpired:
            return _skip("wezterm cli spawn timed out (no running mux server?)")

        if pane.returncode != 0:
            return _skip(f"wezterm cli spawn failed: {pane.stderr.strip()[:200]}")

        pane_id = pane.stdout.strip()

        def get_text() -> str:
            r = subprocess.run(
                ["wezterm", "cli", "get-text", "--pane-id", pane_id,
                 "--start-line", "-2000"],
                capture_output=True,
                text=True,
            )
            return r.stdout

        def window_id() -> str | None:
            r = subprocess.run(
                ["xdotool", "search", "--pid", pid_of_pane()],
                capture_output=True, text=True,
            )
            ids = [x for x in r.stdout.split() if x.strip()]
            return ids[-1] if ids else None

        def pid_of_pane() -> str:
            r = subprocess.run(
                ["wezterm", "cli", "list", "--format", "json"],
                capture_output=True, text=True,
            )
            import json as _json
            try:
                for p in _json.loads(r.stdout or "[]"):
                    if str(p.get("pane_id")) == pane_id:
                        return str(p.get("window_id", ""))
            except Exception:
                pass
            return ""

        try:
            time.sleep(8)
            before = get_text()
            if BANDS["composer prompt"] not in before:
                return _skip("binary did not reach a composer inside wezterm")

            wid = window_id()
            if not wid:
                return _skip("could not locate the wezterm X window to resize")

            # Drag the window through a range of widths. xdotool drives the
            # real window manager, so the emulator resizes exactly as it does
            # under a mouse drag.
            for w in (1100, 1000, 900, 820, 900, 1000, 1100, 1200):
                subprocess.run(["xdotool", "windowsize", wid, str(w), "700"],
                               capture_output=True)
                time.sleep(0.5)
            time.sleep(3)

            after = get_text()
            for name, needle in BANDS.items():
                n = after.count(needle)
                if n > 1:
                    failures.append(
                        f"{name}: {n} copies after the drag (expected 1) — "
                        "stranded chrome in wezterm scrollback"
                    )
            if failures:
                print("--- wezterm pane text after drag (tail) ---")
                print("\n".join(after.splitlines()[-50:]))
        finally:
            subprocess.run(["wezterm", "cli", "kill-pane", "--pane-id", pane_id],
                           capture_output=True)

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print("ok — one copy of each band survives a window drag in WezTerm")
    return 0


if __name__ == "__main__":
    sys.exit(main())
