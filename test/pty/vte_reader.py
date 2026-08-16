#!/usr/bin/env python3
"""Read what libvte actually holds — the one row-coordinate system it has.

Why this file exists
--------------------
Every VTE harness in this repo read the terminal with some spelling of::

    term.get_text_range_format(Vte.Format.TEXT, -20_000, 0, term.get_row_count(), cols)

carrying a comment that says "negative start rows reach into scrollback". They
do not. **VTE row indices are ABSOLUTE over the whole ring**: row 0 is the first
line the session ever emitted, row N is the (N+1)-th, negative rows are empty,
and the VISIBLE SCREEN is the LAST ``page_size`` rows of the ring — not rows
``0..row_count``.

Measured, on this box, GNOME's own libvte: a shell printing ``LINE001`` ..
``LINE200`` into a 24-row terminal reads back ``row(0) == "LINE001"``,
``row(23) == "LINE024"``, ``row(199) == "LINE200"``, ``row(-1) == ""``. The
first screenful stays at indices 0..23 forever; nothing ever moves.

So ``range(-20_000, row_count)`` is not "scrollback plus screen". It is
**exactly the first screenful of the session, and nothing else, for the whole
run**. A harness using it sees the banner and the first few turns and is blind
to every row after them, permanently.

That is not a subtle inaccuracy, and it produced a false product defect. Driving
OSA through 12 turns on a 50-row terminal and counting committed replies with
the old reader gives 1, 2, 3, 4, 4, 4, 4, 4, 4, 4, 4, 4 — a session that looks
dead after four exchanges. The ceiling moves with the screen (24 rows → 1,
40 → 3, 50 → 4, 60 → 5) which reads as damning evidence of viewport height
math, and is really just the reader's window being ``row_count`` rows tall. The
`POST /api/v1/orchestrate` count over the same run is 12 of 12: OSA accepted and
dispatched every one.

The two coordinates a harness actually wants
--------------------------------------------
``Gtk.Adjustment`` on the terminal is VTE's own statement of both, in the same
absolute units the row reader uses:

* ``value``      — absolute index of the FIRST VISIBLE row
* ``page_size``  — rows on screen
* ``upper``      — one past the LAST row in the ring

so the visible screen is ``[value, value + page_size)`` and the whole buffer is
``[lower, upper)``. [`screen_rows`] and [`buffer_rows`] are those two.

Read one row per call, always
-----------------------------
A MULTI-ROW range read returns LOGICAL lines: VTE un-wraps every soft-wrapped
continuation, so a 68-column table row reads back as 68 columns on a 60-column
screen. Reflow damage is by definition a physical-row phenomenon, so a range
read reports a shredded table as pristine. One call per row costs one IPC
round trip each and is the only way to see the screen as the user does.
"""

from __future__ import annotations


def _row(term, Vte, r: int, width: int) -> str:
    text = term.get_text_range_format(Vte.Format.TEXT, r, 0, r, width)
    if isinstance(text, tuple):
        text = next((x for x in text if isinstance(x, str)), "")
    return (text or "").rstrip("\n")


def screen_bounds(term) -> tuple[int, int]:
    """``(first, last_exclusive)`` absolute row indices of the VISIBLE screen."""
    adj = term.get_vadjustment()
    top = int(adj.get_value())
    return top, top + int(adj.get_page_size())


def buffer_bounds(term) -> tuple[int, int]:
    """``(first, last_exclusive)`` absolute row indices of the WHOLE ring."""
    adj = term.get_vadjustment()
    return int(adj.get_lower()), int(adj.get_upper())


def screen_rows(term, Vte) -> list[str]:
    """Physical rows of the visible screen, top to bottom.

    This is what a photograph of the window would show, which is what a claim
    about layout, chrome placement or a resize wipe is about.
    """
    width = term.get_column_count()
    first, last = screen_bounds(term)
    return [_row(term, Vte, r, width) for r in range(first, last)]


def buffer_rows(term, Vte, limit: int | None = None) -> list[str]:
    """Physical rows of the whole ring — native scrollback plus screen.

    This is what a claim about the TRANSCRIPT is about: content committed
    through ``insert_before`` leaves the screen and lives only here.

    ``limit`` caps how many rows are read, counting back from the bottom, since
    each row is an IPC round trip and a long session's ring runs to thousands.
    """
    width = term.get_column_count()
    first, last = buffer_bounds(term)
    if limit is not None:
        first = max(first, last - limit)
    return [_row(term, Vte, r, width) for r in range(first, last)]
