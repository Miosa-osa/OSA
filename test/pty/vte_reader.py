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

The adjustment goes STALE after ``ESC[3J``
------------------------------------------
Third failure of the same class, and the nastiest, because unlike the other two
it only appears once the product starts erasing saved lines.

``ESC[3J`` (erase-saved-lines, ``ClearType::Purge``) makes VTE drop its
scrollback. The ring's own row numbering — the coordinates
``get_text_range_format`` takes — does NOT restart; the dropped rows simply stop
being addressable and everything after them keeps the index it always had. The
``Gtk.Adjustment``, however, is left describing the ring as it was: measured on
this box, after a resize drag against a build that purges on every step, the
adjustment reports ``lower=0, upper=116`` with the visible screen at
``[66, 116)`` while ``get_cursor_position()`` — which IS in ring coordinates —
returns row **277**.

Rows 66..116 are inside the purged span, so every one of them reads back empty.
A harness trusting the adjustment therefore reports a blank screen and an absent
transcript, and every content grade comes out DESTROYED with the note "block
markers vanished". The transcript is intact and correctly reflowed the whole
time; only the address is wrong. ``vte_content_reflow.py`` graded a working
build as destroying its own transcript for exactly this reason.

The cursor is the fixed point. It is reported in ring coordinates and it is
always inside the visible screen, so it pins the bottom of the buffer to within
one screenful no matter how far the adjustment has drifted. [`ring_bounds`] uses
it, and falls back to the adjustment verbatim whenever the two still agree — so
a session that never purges reads exactly as it did before.
"""

from __future__ import annotations


def _row(term, Vte, r: int, width: int) -> str:
    text = term.get_text_range_format(Vte.Format.TEXT, r, 0, r, width)
    if isinstance(text, tuple):
        text = next((x for x in text if isinstance(x, str)), "")
    return (text or "").rstrip("\n")


def screen_bounds(term) -> tuple[int, int]:
    """``(first, last_exclusive)`` VISIBLE screen, as the ADJUSTMENT states it.

    Raw. Prefer [`ring_bounds`], which repairs this after ``ESC[3J``.
    """
    adj = term.get_vadjustment()
    top = int(adj.get_value())
    return top, top + int(adj.get_page_size())


def buffer_bounds(term) -> tuple[int, int]:
    """``(first, last_exclusive)`` WHOLE ring, as the ADJUSTMENT states it.

    Raw. Prefer [`ring_bounds`], which repairs this after ``ESC[3J``.
    """
    adj = term.get_vadjustment()
    return int(adj.get_lower()), int(adj.get_upper())


def ring_bounds(term, Vte) -> tuple[int, int, int]:
    """``(buffer_first, screen_first, last_exclusive)`` in RING coordinates.

    The adjustment's numbers when they are still coherent, and cursor-derived
    ones when ``ESC[3J`` has desynchronized them (see the module docstring).

    "Coherent" is decided by the one check that cannot be argued with: the
    cursor is always inside the visible screen, so a cursor row at or past the
    adjustment's ``upper`` proves the adjustment describes a ring that no longer
    exists. Nothing is repaired unless that fires, so a session that never
    purges reads byte-identically to before this function existed.
    """
    adj = term.get_vadjustment()
    lower, upper = int(adj.get_lower()), int(adj.get_upper())
    page = int(adj.get_page_size()) or term.get_row_count()
    top = int(adj.get_value())
    _, cursor_row = term.get_cursor_position()

    if cursor_row < upper:
        return lower, top, upper

    # Stale. The cursor pins the bottom to within one screenful: the screen
    # cannot end more than `page` rows below it. Scan that far and take the
    # last row holding anything, so the chrome under the cursor (hint row,
    # status bar) is included rather than clipped.
    width = term.get_column_count()
    last = cursor_row + 1
    for r in range(cursor_row + 1, cursor_row + page + 1):
        if _row(term, Vte, r, width).strip():
            last = r + 1
    # The ring's span survives the drop even though its origin does not, so it
    # still says how far back there is anything to read.
    return max(0, last - (upper - lower)), max(0, last - page), last


def screen_rows(term, Vte) -> list[str]:
    """Physical rows of the visible screen, top to bottom.

    This is what a photograph of the window would show, which is what a claim
    about layout, chrome placement or a resize wipe is about.
    """
    width = term.get_column_count()
    _, first, last = ring_bounds(term, Vte)
    return [_row(term, Vte, r, width) for r in range(first, last)]


def buffer_rows(term, Vte, limit: int | None = None) -> list[str]:
    """Physical rows of the whole ring — native scrollback plus screen.

    This is what a claim about the TRANSCRIPT is about: content committed
    through ``insert_before`` leaves the screen and lives only here.

    ``limit`` caps how many rows are read, counting back from the bottom, since
    each row is an IPC round trip and a long session's ring runs to thousands.
    """
    width = term.get_column_count()
    first, _, last = ring_bounds(term, Vte)
    if limit is not None:
        first = max(first, last - limit)
    return [_row(term, Vte, r, width) for r in range(first, last)]
