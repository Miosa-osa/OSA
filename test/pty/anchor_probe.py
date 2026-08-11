#!/usr/bin/env python3
"""Where does the inline live region sit after each kind of rebuild?

The whole inline design is BOTTOM-ANCHORED: the live region occupies the last
`inline_h` rows, the transcript is above it, and `Terminal::insert_before`
scrolls the screen to push finalized messages up past it. Every erase in
`event_loop.rs` is written against that geometry (`resize_clear_top_from_bottom`
states it outright: `old_top = old_rows - old_h`).

`clear_screen_for_resize` homes the cursor to (0, 0) before erasing. The
`rebuild_inline` that follows constructs `Viewport::Inline`, which anchors the
new region on wherever `compute_inline_size` finds the cursor — row 0. So the
question this answers is whether the full-screen resize branch leaves the live
region at the TOP of the screen instead of the bottom, which would invert the
invariant and put the chrome ABOVE the line `insert_before` scrolls at.

Prints the visible screen only (no history), with absolute row numbers.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from duplicate_probe import PreludeSession  # noqa: E402
from osa_pty import SETTLE, SINGLETON_BANDS  # noqa: E402
from stub_backend import StubBackend  # noqa: E402

STUB_PORT = 12798


def screen_rows(s):
    """Visible screen only, as (row_index, text)."""
    return [(i, line.rstrip()) for i, line in enumerate(s.screen.display)]


def where_is_chrome(s) -> str:
    rows = screen_rows(s)
    hits = {}
    for name, pat in SINGLETON_BANDS.items():
        hits[name] = [i for i, line in rows if pat.search(line)]
    last_nonblank = max((i for i, line in rows if line.strip()), default=-1)
    return f"rows={len(rows)} chrome_at={hits} last_nonblank_row={last_nonblank}"


def show(s, label):
    print(f"\n--- {label} ---")
    print("   " + where_is_chrome(s))
    for i, line in screen_rows(s):
        if line.strip():
            print(f"   {i:3d}|{line[:110]}")


def main() -> int:
    with StubBackend(STUB_PORT) as backend:
        with PreludeSession(backend.base_url, cols=120, rows=30) as s:
            s.boot()
            s.pump(SETTLE * 2)
            show(s, "booted (expect chrome at the BOTTOM)")

            # Pure height change: takes the surgical `last_inline_top` clear.
            s.write(b"hello")
            s.pump(SETTLE)
            show(s, "after typing (height-change rebuild, surgical clear)")

            # A real terminal resize: takes `clear_screen_for_resize` on this
            # environment (no $TMUX -> ResizeClear::FullScreen).
            s.resize(110, 30)
            s.pump(SETTLE * 3)
            show(s, "after ONE width resize (full-screen wipe branch)")

            s.resize(100, 30)
            s.pump(SETTLE * 3)
            show(s, "after a SECOND width resize")

            # Consequence check. `last_inline_top` is refreshed from the rebuilt
            # viewport, so if the region re-anchored at row 0 the tracked top is
            # now 0 — and the surgical clear used for PURE HEIGHT CHANGES
            # (`MoveTo(0, top)` + `FromCursorDown`) becomes a whole-screen wipe
            # on the next keystroke that changes the composer's height. That is
            # the "it eats the transcript" half of the report.
            s.write(b"a message that lands in the transcript after the resize\r")
            s.pump(SETTLE * 3)
            show(s, "after committing a message post-resize")
            s.write(b"x")
            s.pump(SETTLE * 3)
            show(s, "after ONE keystroke (pure height change, surgical clear)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
