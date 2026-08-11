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

It matters because the fix for tmux is environment-scoped, and a scoped fix
demands evidence from OUTSIDE its scope: that the path taken everywhere else is
still correct on an emulator that is neither tmux nor libvte. WezTerm is the
only such emulator here that can be checked without a human watching.

What the scoped fix IS
----------------------
The surgical clear from the remembered live-region top (`event_loop.rs`,
`resize_clear_strategy`): the old chrome is overwritten in place, so it never
becomes scroll history in the first place.

It is NOT an ED3 history purge. That was v1.0.71 only, reverted in v1.0.72
because it worked by destroying the user's scrollback on every resize, and
`layout_invariants.rs` now carries an unconditional test banning ED3 on the
resize path. This docstring used to describe the purge as the shipped fix; a
stale comment naming a reverted approach is how someone reintroduces it, which
is the same reason CHANGELOG records both rejected approaches by name.

What the scope is keyed on
--------------------------
Not "is this a multiplexer", and not "does this terminal reflow". The older
rationale here — that the surgical clear is valid under tmux "because tmux never
reflows" — is false. tmux has reflowed since 2.5, and `test/pty/reflow_matrix.py`
measures tmux 3.4 on this box re-wrapping an 85-column line to one row when the
pane widens to 140, exactly as libvte, WezTerm and Ghostty do. Every terminal
measurable here reflows, so reflow cannot be what separates them. See
`resize_clear_strategy` for what the gate keys on instead.

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

import scrollback_prelude  # noqa: E402  (needs the sys.path line above)
import term_env  # noqa: E402

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

    def _x_windows() -> set[str]:
        r = subprocess.run(
            ["xdotool", "search", "--onlyvisible", "--class", "org.wezfurlong.wezterm"],
            capture_output=True, text=True,
        )
        return {w for w in r.stdout.split() if w.strip()}

    windows_before = _x_windows()

    with StubBackend(STUB_PORT) as backend:
        # `wezterm cli spawn` is executed by the already-running mux SERVER, so
        # the child inherits that server's environment and nothing set here
        # would reach it. The sanitization and `OSA_BASE_URL` therefore travel
        # inside the command line. Without this the child inherits whatever the
        # user's wezterm was started from — including `$TMUX` when that was a
        # tmux session, which would make this "WezTerm" test measure tmux.
        prefix = term_env.sh_env_prefix(
            OSA_BASE_URL=backend.base_url, **term_env.passthrough_override()
        )
        # A scrollback of WRAPPED lines, so a widen actually re-joins content
        # above the live region and the drag can strand something. With an
        # empty transcript nothing moves and the assertion is vacuous.
        prelude = scrollback_prelude.prelude_text(
            lines=int(os.environ.get("OSA_PTY_PRELUDE_LINES", "12"))
        )
        import shlex as _shlex

        # The leading sleep gives the harness time to enlarge the window
        # BEFORE the prelude prints. A WezTerm window opens at roughly 80x24,
        # and 12 wrapped lines plus an inline live region do not fit in 24 rows
        # — the binary then wedges on startup and never reaches a composer.
        # (That wedge is a real OSA defect in its own right; see the report.)
        cmd = (
            "sleep 5; "
            f"printf %s {_shlex.quote(prelude)}; "
            # `exec` FIRST: it is a shell builtin, so `env … exec binary` would
            # have `env` look for a program literally named "exec" and fail.
            f"exec {prefix} {_shlex.quote(str(binary))}"
        )

        # `--new-window` gives a fresh GUI window, which is what gets resized.
        try:
            pane = subprocess.run(
                ["wezterm", "cli", "spawn", "--new-window", "--", "/bin/sh", "-c", cmd],
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
            """The X window of the pane we just spawned.

            Found by DIFFING the visible windows of WezTerm's class before and
            after the spawn. The previous implementation looked the window up by
            pid — `xdotool search --pid` fed with WezTerm's own *window_id*
            field, which is a WezTerm mux id and not a process id at all, so the
            search never matched and this harness reported SKIPPED on every run.
            Diffing avoids the question entirely: a pid is not usable here in
            any case, because `cli spawn` routes through the already-running
            gui process and the window belongs to THAT pid, not to anything the
            harness started.
            """
            # Poll: the window is mapped by the gui process asynchronously and
            # is not visible to X the instant `cli spawn` returns.
            for _ in range(60):
                new = _x_windows() - windows_before
                if new:
                    return sorted(new)[-1]
                time.sleep(0.25)
            return None

        try:
            wid = window_id()
            if not wid:
                return _skip("could not locate the wezterm X window to resize")
            # Enlarge before the prelude lands (see the `sleep 5` above), and
            # start WIDE so the drag below has room to narrow into.
            subprocess.run(["xdotool", "windowsize", wid, "1200", "900"],
                           capture_output=True)

            # Poll rather than sleep a fixed 8s. Startup spans a backend
            # handshake and a provider probe; a fixed wait that is occasionally
            # short degrades into an intermittent SKIP, which is a green run
            # that asserted nothing.
            before = ""
            for _ in range(45):
                time.sleep(1.0)
                before = get_text()
                if BANDS["composer prompt"] in before:
                    break
            else:
                if os.environ.get("WEZ_DEBUG"):
                    print("--- pane text (debug) ---")
                    print("\n".join(before.splitlines()[-30:]))
                return _skip("binary did not reach a composer inside wezterm")

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
