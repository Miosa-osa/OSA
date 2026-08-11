#!/usr/bin/env python3
"""Does the live region duplicate WITHOUT a resize?

Every previous investigation of "OSA stacks a second composer / status bar on
screen" assumed the trigger was a terminal resize and fixed the resize clear
path. This harness deliberately never resizes for its own sake. It drives the
OTHER things that rebuild, re-anchor, or scroll the inline viewport --

  * the slash-completions popup opening and closing (`popup_changed`)
  * the composer growing and shrinking (`desired_inline_h != cur_inline_h`)
  * a dialog round trip through the alternate screen (`switch_to_full` /
    `switch_to_inline`)
  * `/clear` (`purge_scrollback` + `rebuild_inline`)
  * Ctrl+L (`force_redraw` -> `terminal.clear()`)

-- and counts the singleton bands after each, across the visible screen AND
scrolled-off history.

Two things this shares with the resize harnesses and would be worthless
without:

  * a SCROLLBACK PRELUDE. With an empty transcript nothing above the live
    region can move, so a stranded copy has nowhere to strand and every branch
    passes. `osa_pty.PtySession` execs the binary directly and therefore has
    never had one; this subclass adds it.
  * a CLEAN CHILD ENVIRONMENT (`term_env`). This repo is developed inside tmux
    and an inherited `$TMUX` silently switches the binary onto the multiplexer
    branch.

Run: `python3 test/pty/duplicate_probe.py`
"""

from __future__ import annotations

import os
import pty
import shlex
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import scrollback_prelude  # noqa: E402
import term_env  # noqa: E402
from osa_pty import SETTLE, SINGLETON_BANDS, PtySession  # noqa: E402
from stub_backend import StubBackend  # noqa: E402

STUB_PORT = 12793


class PreludeSession(PtySession):
    """`PtySession`, but with wrapped filler text already in the scrollback.

    Identical in every other respect. The only override is the exec: the child
    becomes `/bin/sh -c 'printf <prelude>; exec <binary>'` so the binary
    inherits a screen with real, wrapping transcript above it -- the condition
    under which a stranded copy is observable at all.
    """

    prelude_lines = 40

    def __enter__(self) -> "PreludeSession":
        port = self.base_url.rsplit(":", 1)[-1]
        pid, fd = pty.fork()
        if pid == 0:  # child
            env = term_env.clean_env(
                TERM="xterm-256color",
                OSA_URL=self.base_url,
                OSA_PORT=port,
                HOME=os.environ.get("OSA_PTY_HOME", os.environ.get("HOME", "/tmp")),
                NO_COLOR="",
            )
            text = scrollback_prelude.prelude_text(lines=self.prelude_lines)
            os.execve(
                "/bin/sh",
                [
                    "/bin/sh",
                    "-c",
                    f"printf %s {shlex.quote(text)}; exec {shlex.quote(str(self.binary))}",
                ],
                env,
            )
            os._exit(127)  # unreachable
        self.pid, self.fd = pid, fd
        self.resize(self.cols, self.rows)
        return self


def counts(s: PtySession) -> dict[str, int]:
    return {name: s.count(pat) for name, pat in SINGLETON_BANDS.items()}


def report(label: str, s: PtySession, failures: list[str], dump_on_fail: bool = True) -> None:
    c = counts(s)
    bad = {k: v for k, v in c.items() if v > 1}
    status = "DUPLICATED" if bad else "ok"
    print(f"  [{status:11}] {label}: {c}")
    if bad:
        failures.append(f"{label}: {bad}")
        if dump_on_fail:
            print("    --- tail of rendered screen+history ---")
            for line in s.dump().splitlines()[-45:]:
                print(f"    {line}")


def settle(s: PtySession, seconds: float = SETTLE * 2) -> None:
    s.pump(seconds)


# --------------------------------------------------------------------------
# Probes. Each is independent; each gets its own process so one leaking state
# cannot explain another's result.
# --------------------------------------------------------------------------


def probe_idle(backend: StubBackend, failures: list[str]) -> None:
    """Control. Boot, sit still, assert one of everything.

    If this fails, nothing below means anything -- the duplication would
    predate every trigger under test.
    """
    print("\n== probe: idle (control, no trigger at all) ==")
    with PreludeSession(backend.base_url, cols=120, rows=40) as s:
        s.boot()
        settle(s, 3.0)
        report("after boot, untouched", s, failures)


def probe_popup_churn(backend: StubBackend, failures: list[str]) -> None:
    """Open and close the slash-completions popup repeatedly.

    `popup_changed` is one of the three exemptions from the shrink debounce, so
    every open and every close takes the immediate clear+`rebuild_inline` path
    -- the same path a resize takes, minus the resize. If a rebuild can strand
    a copy on its own, this is where it shows up, and it costs no SIGWINCH.
    """
    print("\n== probe: slash-popup open/close churn (no resize) ==")
    with PreludeSession(backend.base_url, cols=120, rows=40) as s:
        s.boot()
        settle(s)
        report("before churn", s, failures, dump_on_fail=False)
        for i in range(8):
            s.write(b"/")
            s.pump(0.4)
            s.write(b"\x7f")  # backspace: popup closes, composer shrinks
            s.pump(0.4)
        settle(s, 3.0)
        report("after 8 popup open/close cycles", s, failures)


def probe_composer_grow_shrink(backend: StubBackend, failures: list[str]) -> None:
    """Grow the composer to several lines and shrink it back, repeatedly.

    A pure height change: `desired_inline_h != cur_inline_h` with
    `terminal_resized == false`, so it takes the surgical
    `MoveTo(0, last_inline_top) + FromCursorDown` clear and then
    `rebuild_inline`, whose `Terminal::with_options(Inline)` emits `h-1`
    newlines (`compute_inline_size` -> `Backend::append_lines`). Newlines at the
    bottom of the screen scroll it, and anything scrolled is in history where
    no erase can reach it.
    """
    print("\n== probe: composer grow/shrink churn (no resize) ==")
    with PreludeSession(backend.base_url, cols=120, rows=40) as s:
        s.boot()
        settle(s)
        report("before churn", s, failures, dump_on_fail=False)
        for _ in range(5):
            # Alt+Enter inserts a newline in the composer without submitting.
            for _ in range(4):
                s.write(b"filler")
                s.write(b"\x1b\r")
                s.pump(0.25)
            settle(s, 1.5)
            # Tear it all back down.
            for _ in range(60):
                s.write(b"\x7f")
            s.pump(0.5)
            settle(s, 1.5)
        settle(s, 3.0)
        report("after 5 grow/shrink cycles", s, failures)


def probe_dialog_round_trip(backend: StubBackend, failures: list[str]) -> None:
    """Enter and leave the alternate screen via a dialog, repeatedly.

    `switch_to_full` -> `switch_to_inline`. The return leg clears from the
    remembered `last_inline_top` and then rebuilds, and the rebuild's
    `append_lines` scrolls if the cursor is low on the screen.
    """
    print("\n== probe: dialog alt-screen round trip (no resize) ==")
    with PreludeSession(backend.base_url, cols=120, rows=40) as s:
        s.boot()
        settle(s)
        report("before round trips", s, failures, dump_on_fail=False)
        for i in range(4):
            s.write(b"/help")
            s.pump(0.5)
            s.write(b"\r")
            s.pump(0.5)
            s.write(b"\r")
            settle(s, 1.5)
            for _ in range(3):
                s.write(b"\x1b")
                s.pump(0.4)
            settle(s, 1.5)
        settle(s, 3.0)
        report("after 4 dialog round trips", s, failures)


def probe_dialog_shrink_then_close(backend: StubBackend, failures: list[str]) -> None:
    """Open a dialog, SHRINK the terminal while it owns the screen, then close.

    Targeted at `switch_to_inline`: it erases the old chrome only when
    `clamp_inline_top(prev_inline_top, term_rows)` is `Some`, i.e. only while
    the remembered top row still exists on the (possibly now shorter) screen.
    When the terminal shrank past that row the clear is SKIPPED entirely, and
    the rebuild that follows emits `h-1` newlines from wherever
    `LeaveAlternateScreen` restored the cursor -- which is inside the old
    chrome. That scrolls the old chrome into scrollback and then paints a fresh
    copy below it.

    The resize here is not the mechanism under test; it is only the way to make
    the remembered row fall off the bottom. The duplication, if it happens,
    happens on the DIALOG CLOSE.
    """
    print("\n== probe: dialog open -> terminal shrink -> dialog close ==")
    with PreludeSession(backend.base_url, cols=120, rows=44) as s:
        s.boot()
        settle(s)
        report("before", s, failures, dump_on_fail=False)
        s.write(b"/help")
        s.pump(0.5)
        s.write(b"\r")
        s.pump(0.5)
        s.write(b"\r")
        settle(s, 2.0)
        # Shrink hard while the dialog owns the alternate screen.
        s.resize(120, 14)
        settle(s, 2.0)
        for _ in range(3):
            s.write(b"\x1b")
            s.pump(0.5)
        settle(s, 3.0)
        report("after close at a much shorter height", s, failures)


def probe_slash_clear(backend: StubBackend, failures: list[str]) -> None:
    """`/clear`: `purge_scrollback()` then `rebuild_inline`."""
    print("\n== probe: /clear (purge + rebuild, no resize) ==")
    with PreludeSession(backend.base_url, cols=120, rows=40) as s:
        s.boot()
        settle(s)
        for _ in range(3):
            s.write(b"/clear")
            s.pump(0.5)
            s.write(b"\r")
            s.pump(0.5)
            s.write(b"\r")
            settle(s, 2.0)
        report("after 3 /clear runs", s, failures)


def probe_ctrl_l(backend: StubBackend, failures: list[str]) -> None:
    """Ctrl+L: `force_redraw` -> `terminal.clear()` with no rebuild."""
    print("\n== probe: Ctrl+L hard repaint (no resize) ==")
    with PreludeSession(backend.base_url, cols=120, rows=40) as s:
        s.boot()
        settle(s)
        for _ in range(6):
            s.write(b"\x0c")
            s.pump(0.4)
        settle(s, 3.0)
        report("after 6 Ctrl+L", s, failures)


PROBES = [
    probe_idle,
    probe_popup_churn,
    probe_composer_grow_shrink,
    probe_dialog_round_trip,
    probe_dialog_shrink_then_close,
    probe_slash_clear,
    probe_ctrl_l,
]


def main() -> int:
    only = sys.argv[1:]
    failures: list[str] = []
    with StubBackend(STUB_PORT) as backend:
        for probe in PROBES:
            if only and not any(o in probe.__name__ for o in only):
                continue
            try:
                probe(backend, failures)
            except Exception as e:  # a probe that cannot run is not a pass
                print(f"  [ERROR      ] {probe.__name__}: {type(e).__name__}: {e}")
                failures.append(f"{probe.__name__}: {type(e).__name__}: {e}")
    print("\n=== summary ===")
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("no duplication observed on any non-resize trigger")
    return 0


if __name__ == "__main__":
    sys.exit(main())
