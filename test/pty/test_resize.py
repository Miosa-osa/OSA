#!/usr/bin/env python3
"""Layout assertions against the real `osagent` binary on a real PTY.

Run: `test/pty/run.sh` (see test/pty/README.md).

Each test boots the binary, does something to the terminal, and then asserts
that exactly ONE copy of each singleton band (composer, context hint, status
bar) is on screen. That single assertion is the whole point: the defect this
harness exists for — a resize stranding one copy of the live region per resize
step — presents as N copies, and is invisible to the in-process Rust suite
because `VT100Backend` answers cursor queries from a perfect model.

Deliberately a plain script, not pytest: it must be runnable on a bare checkout
with nothing but `pyte` installed, and its failure output has to be a screen
dump rather than a pytest traceback, because the screen IS the evidence.
"""

from __future__ import annotations

import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from osa_pty import SETTLE, SINGLETON_BANDS, PtySession  # noqa: E402
from stub_backend import StubBackend  # noqa: E402

# A high, unlikely-to-collide port. The stub binds loopback only.
STUB_PORT = 12787


def assert_single_live_region(session: PtySession, context: str) -> None:
    """Exactly one composer, one hint row, one status bar. Anything else is a
    stranded copy (too many) or a lost band (too few)."""
    counts = {name: session.count(pat) for name, pat in SINGLETON_BANDS.items()}
    wrong = {name: n for name, n in counts.items() if n != 1}
    if wrong:
        raise AssertionError(
            f"{context}: expected exactly one of each live-region band, got "
            f"{counts} (offending: {wrong}).\n"
            f"--- rendered screen ---\n{session.dump()}"
        )


# --- tests -----------------------------------------------------------------


def test_resize_sweep(backend: StubBackend) -> None:
    """A width drag must leave exactly one live region.

    This is the regression the harness was built for. Dragging a window emits
    one resize per intermediate width; the shipped defect rebuilt and
    re-anchored the inline viewport on each one while erasing only the rect it
    had just computed, stranding the previous copy. Nine drag steps produced
    nine stacked composers.

    The sweep is deliberately step-by-step with no pause between widths, which
    is what a drag looks like, and what the event loop's resize settle window
    has to coalesce.
    """
    with PtySession(backend.base_url, cols=120, rows=30) as s:
        s.boot()
        assert_single_live_region(s, "after boot at 120x30")

        for width in range(119, 79, -5):
            s.resize(width, 30)
            # Just enough pumping to deliver SIGWINCH and let the child read
            # it — NOT enough to outlast the settle window. A drag does not
            # wait for the app between steps.
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after narrowing sweep 120 -> 80")

        for width in range(85, 125, 5):
            s.resize(width, 30)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after widening sweep 80 -> 120")


def test_height_resize(backend: StubBackend) -> None:
    """A vertical drag must also leave exactly one live region.

    Height changes are the harsher case: they change how many bands FIT, so
    the arbiter sheds and restores bands on the way down and back up. A band
    that is shed and then re-drawn at a stale offset is the same stranding
    class arriving by a different route.
    """
    with PtySession(backend.base_url, cols=100, rows=40) as s:
        s.boot()
        assert_single_live_region(s, "after boot at 100x40")

        for rows in range(38, 19, -2):
            s.resize(100, rows)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after shortening sweep 40 -> 20")

        for rows in range(22, 42, 2):
            s.resize(100, rows)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after heightening sweep 20 -> 40")


def test_small_viewport(backend: StubBackend) -> None:
    """On a viewport too short for every band, the composer still survives.

    The arbiter's contract (`fit_bands`) is that the live region DEGRADES
    rather than overflows: bands shed in priority order and the composer keeps
    at least `INPUT_FLOOR` rows on any viewport. In-process tests pin that
    against the arbiter's arithmetic; this pins it against a real terminal,
    where an overflow shows up as chrome scribbled outside the viewport (and
    therefore as a duplicate composer or a lost status bar).
    """
    with PtySession(backend.base_url, cols=80, rows=10) as s:
        s.boot()
        assert_single_live_region(s, "after boot at 80x10")

        # Squeeze to a genuinely hostile height, then back.
        s.resize(80, 8)
        s.pump(SETTLE * 2)
        composers = s.count(SINGLETON_BANDS["composer"])
        if composers != 1:
            raise AssertionError(
                f"at 80x8 expected exactly one composer, got {composers}.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        s.resize(80, 24)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after growing back to 80x24")


TESTS = [test_resize_sweep, test_height_resize, test_small_viewport]


def main() -> int:
    failed = []
    with StubBackend(STUB_PORT) as backend:
        for test in TESTS:
            name = test.__name__
            sys.stdout.write(f"  {name} ... ")
            sys.stdout.flush()
            try:
                test(backend)
            except Exception:  # noqa: BLE001 - a harness reports, it does not raise
                failed.append(name)
                print("FAIL")
                traceback.print_exc()
            else:
                print("ok")

    total = len(TESTS)
    if failed:
        print(f"\n{len(failed)}/{total} PTY tests FAILED: {', '.join(failed)}")
        return 1
    print(f"\n{total}/{total} PTY tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
