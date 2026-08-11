#!/usr/bin/env python3
"""Shared machinery for driving OSA inside a **real GUI terminal** and reading
the screen back out afterwards.

Why this module exists
----------------------
`wezterm_resize.py`, `ghostty_resize.py`, `kitty_resize.py`,
`alacritty_resize.py` and `xterm_resize.py` all do the same five things:

  1. start a stub backend and build a sanitized child environment
     (`term_env.py`) so the terminal under test is not told it is some other
     terminal — the flaw that made the VTE harness silently measure tmux;
  2. print a **wrapped** scrollback prelude (`scrollback_prelude.py`) so a
     widen actually re-joins content above the live region — without it the
     live region never moves and BOTH resize branches pass vacuously;
  3. locate the terminal's X window and drag it through a range of widths with
     `xdotool`, which drives the real window manager and therefore produces the
     same `SIGWINCH` storm a mouse drag does;
  4. read the resulting screen **and scroll history** back out;
  5. count how many copies of each singleton band survive. One is correct.

Only step 4 differs between terminals, so that is the only thing a terminal
adapter has to implement. Everything else lives here.

Text extraction, per terminal
-----------------------------
| terminal  | mechanism                                            | fidelity |
|-----------|------------------------------------------------------|----------|
| WezTerm   | `wezterm cli get-text`                               | exact    |
| kitty     | `kitty @ get-text --extent all`                      | exact    |
| Ghostty   | `write_scrollback_file` + `write_screen_file` actions | exact    |
| xterm     | `print-everything()` into `printerCommand`           | exact    |
| Alacritty | **none** — pixel band counting (see `pixels.py`)      | derived  |

Ghostty is the notable correction. This harness family long recorded "Ghostty
has no text-extraction API", and asserted only that OSA survived the drag. That
is false: Ghostty ships `write_screen_file` and `write_scrollback_file` keybind
actions, and their `:copy` variant puts the path to a plain-text dump on the
clipboard. Bound to a key in an isolated `$XDG_CONFIG_HOME` and triggered with
`xdotool`, they give the same exact band count every other text API does. See
`ghostty_resize.py`.

Alacritty genuinely has no text API — no control socket, no IPC, no escape
sequence that reports contents — so it is the one terminal here counted from
pixels. That method is not trusted on its own: `pixels.py` is cross-validated
against kitty, where the exact text count is available to check it against.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import scrollback_prelude  # noqa: E402  (needs the sys.path line above)
import term_env  # noqa: E402

# The singleton bands. Exactly one of each must survive a drag.
BANDS = {
    "composer prompt": "❯",
    "hint row": "/ commands",
    "status bar": "ctx",
}

# The width drag every harness performs, in window pixels. Narrow and widen,
# because only the WIDEN direction re-joins wrapped lines and moves the live
# region up underneath a remembered top row.
DRAG_WIDTHS = (1100, 1000, 900, 820, 900, 1000, 1100, 1200)

# Chosen tall enough that 12 wrapped prelude lines plus the inline live region
# fit. OSA wedges on startup when the screen it inherits has too little room.
WINDOW_W, WINDOW_H = 1200, 900


def skip(reason: str) -> int:
    print(f"SKIPPED: {reason}")
    return 0


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def osagent_binary() -> Path:
    return repo_root() / "priv/rust/tui/target/release/osagent"


# --------------------------------------------------------------------------
# X window plumbing
# --------------------------------------------------------------------------


def x_windows(wm_class: str) -> set[str]:
    r = subprocess.run(
        ["xdotool", "search", "--onlyvisible", "--class", wm_class],
        capture_output=True,
        text=True,
    )
    return {w for w in r.stdout.split() if w.strip()}


def await_new_window(wm_class: str, before: set[str], timeout: float = 25.0) -> str | None:
    """The window the harness just spawned, found by DIFFING the class's windows.

    A pid lookup is not usable: several of these terminals route the spawn
    through an already-running process, so the window belongs to that pid and
    not to anything the harness started. Diffing sidesteps the question.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        new = x_windows(wm_class) - before
        if new:
            return sorted(new)[-1]
        time.sleep(0.25)
    return None


def window_geometry(wid: str) -> tuple[int, int, int, int] | None:
    """`(x, y, w, h)` of a window in TRUE ROOT coordinates, for a screenshot bbox.

    Read from `xwininfo`, deliberately not from `xdotool getwindowgeometry`.
    Under a reparenting window manager the client window is a child of a
    decoration frame, and `xdotool` reports its origin relative to that frame.
    Measured on this box: `xdotool` said the kitty window was at (93, 1408)
    while it really began at (79, 1359) — a 49-pixel vertical error, about
    three text rows.

    That error is not cosmetic. A bbox shifted three rows down crops the top of
    the live region away and runs off the bottom of the window into the
    desktop, so the rule the pixel counter exists to find is not in the image
    at all. It reported ZERO bands for a screen that plainly had one — a false
    reading in the direction that hides the bug.
    """
    r = subprocess.run(["xwininfo", "-id", wid], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    vals: dict[str, int] = {}
    for line in r.stdout.splitlines():
        line = line.strip()
        for key, name in (
            ("Absolute upper-left X:", "X"),
            ("Absolute upper-left Y:", "Y"),
            ("Width:", "WIDTH"),
            ("Height:", "HEIGHT"),
        ):
            if line.startswith(key):
                try:
                    vals[name] = int(line[len(key):].strip())
                except ValueError:
                    pass
    try:
        return vals["X"], vals["Y"], vals["WIDTH"], vals["HEIGHT"]
    except KeyError:
        return None


def resize_window(wid: str, w: int, h: int) -> None:
    subprocess.run(["xdotool", "windowsize", wid, str(w), str(h)], capture_output=True)


def kill_window(wid: str) -> None:
    subprocess.run(["xdotool", "windowkill", wid], capture_output=True)


def focus_and_key(wid: str, key: str) -> None:
    """Send `key` as a REAL key event via XTEST, not a synthetic one.

    `xdotool key --window <id>` uses `XSendEvent`, and GTK — which Ghostty uses
    — ignores synthetic key events by default, so a keybind bound inside the
    terminal never fires. Activating the window and injecting through XTEST is
    what actually reaches the application.
    """
    subprocess.run(["xdotool", "windowactivate", "--sync", wid], capture_output=True)
    time.sleep(0.3)
    subprocess.run(["xdotool", "key", "--clearmodifiers", key], capture_output=True)


# --------------------------------------------------------------------------
# The command the terminal runs
# --------------------------------------------------------------------------


def child_command(base_url: str, prelude_lines: int | None = None,
                  settle: int = 5, exit_flag: str | None = None) -> str:
    """The `/bin/sh -c` script every harness hands to its terminal.

    Structure, and why each piece is where it is:

      * `sleep <settle>` first, so the harness can enlarge the window BEFORE
        the prelude prints. Terminals open at roughly 80x24 and the prelude
        plus an inline live region does not fit in 24 rows; OSA then wedges on
        startup and never reaches a composer.
      * the prelude next, printed by the shell rather than by OSA, so it is
        ordinary terminal scrollback the emulator will reflow.
      * `env -u …` immediately before the binary, because some terminals spawn
        the child from a long-running server process whose environment the
        harness cannot set. Carrying the sanitization on the command line is
        the only channel that always works.
      * an optional `exit_flag` touched after the binary returns, which is how
        a harness detects that OSA died when the terminal closes its window on
        child exit (a closed window and a never-opened one look identical by
        the time anyone looks).
    """
    if prelude_lines is None:
        prelude_lines = int(os.environ.get("OSA_PTY_PRELUDE_LINES", "12"))
    prelude = scrollback_prelude.prelude_text(lines=prelude_lines)
    prefix = term_env.sh_env_prefix(
        **term_env.backend_vars(base_url), **term_env.passthrough_override()
    )
    binary = shlex.quote(str(osagent_binary()))
    parts = [
        f"sleep {settle}",
        f"printf %s {shlex.quote(prelude)}",
    ]
    if exit_flag:
        # Cannot `exec` when something has to run afterwards.
        parts.append(f"{prefix} {binary}")
        parts.append(f"echo exited > {shlex.quote(exit_flag)}")
    else:
        # `exec` FIRST: it is a shell builtin, so `env … exec binary` would make
        # `env` look for a program literally named "exec" and fail.
        parts.append(f"exec {prefix} {binary}")
    return "; ".join(parts)


# --------------------------------------------------------------------------
# The drag, and the counting
# --------------------------------------------------------------------------


@dataclass
class DragResult:
    """What a drag produced, in whichever currency the terminal can pay in."""

    counts: dict[str, int] = field(default_factory=dict)
    text: str | None = None
    note: str = ""
    artifacts: list[str] = field(default_factory=list)


def count_bands(text: str) -> dict[str, int]:
    return {name: text.count(needle) for name, needle in BANDS.items()}


def failures_from_counts(counts: dict[str, int], where: str) -> list[str]:
    out = []
    for name, n in counts.items():
        if n > 1:
            out.append(
                f"{name}: {n} copies after the drag (expected 1) — "
                f"stranded chrome in {where}"
            )
    return out


def perform_drag(wid: str, settle_between: float = 0.5, settle_after: float = 3.0,
                 on_step=None) -> None:
    """The reported gesture: narrow, then widen, one resize per step.

    `on_step` lets a pixel-based harness capture a frame per step, which is how
    the CUMULATIVE failure shape (one stranded copy per drag step, as tmux
    produces) is told apart from the BOUNDED one (a single stranded copy for
    the whole gesture, as WezTerm produces).
    """
    for w in DRAG_WIDTHS:
        resize_window(wid, w, WINDOW_H)
        time.sleep(settle_between)
        if on_step is not None:
            on_step(w)
    time.sleep(settle_after)


def await_composer(get_text, tries: int = 45, interval: float = 1.0) -> str | None:
    """Poll until a composer appears, rather than sleeping a fixed interval.

    Startup spans a backend handshake and a provider probe. A fixed wait that
    is occasionally too short degrades into an intermittent SKIP, and a SKIP is
    a green run that asserted nothing.
    """
    text = ""
    for _ in range(tries):
        time.sleep(interval)
        text = get_text()
        if BANDS["composer prompt"] in text:
            return text
    return None


def artifact_dir() -> Path:
    """Where screenshots and text dumps are kept for a human to look at."""
    d = Path(os.environ.get("OSA_PTY_ARTIFACTS", repo_root() / "tmp/pty-artifacts"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def branch_label() -> str:
    """The resize branch this run is exercising, for artifact names."""
    return os.environ.get("OSA_RESIZE_CLEAR", "default")
