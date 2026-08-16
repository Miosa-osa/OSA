#!/usr/bin/env python3
"""Read the terminal the way a hyperlink-aware emulator does: per-cell URIs.

Why this file exists
--------------------
Every other reader in this harness returns text with the escapes already
consumed, so a hyperlink is gone before a test can look at it:

* ``pyte`` parses ``ESC ]8;;URI ESC\\`` correctly enough to keep it off the
  screen — its OSC branch dispatches only codes ``0``/``1``/``2`` and drops
  everything else — so ``PtySession.lines()`` shows the label and no link;
* ``vte_reader.screen_rows`` calls ``get_text_range_format(Vte.Format.TEXT, …)``,
  which is text by definition;
* ``vte_exit_dump`` reads a dump OSA has *deliberately* stripped of escapes, so
  a half-open hyperlink cannot be inherited by the shell prompt.

So "links still work after a resize" was recorded as an expectation nothing in
the repo could measure. This is the reader that can.

Why not libvte
--------------
libvte does hold the attribute — ``VteCell`` carries a hyperlink index into the
ring's URI pool — but on this box (**VTE 0.76**, GTK 3) it is unreachable from a
test process:

* ``Vte.Format.HTML`` export does **not** emit anchors. Verified, not assumed:
  the same export renders colour faithfully (``<font color="#C00000">RED</font>``)
  and returns the linked row as bare ``<pre>LINKED tail</pre>``.
* ``Vte.Terminal.hyperlink_check_event`` is the only accessor, and it needs a
  ``GdkEvent`` that VTE will convert to an internal mouse event. A synthesized
  ``Gdk.Event.new(MOTION_NOTIFY)`` carrying a window, a device and correct
  widget-relative coordinates returns ``None`` for every cell — including a
  brute-force sweep of the whole 722x434 pixel allocation of a realized, mapped
  terminal. **This is the coordinate path, not the hyperlink storage**:
  ``match_check_event``, which resolves its position through the same
  ``rowcol_from_event``, also returns ``None`` at coordinates where the regex it
  was given plainly matches the text on screen. There is no accessor left.

So the per-cell attribute is modelled here instead, from the byte stream OSA
actually writes — which is the input every real emulator builds that attribute
from, including libvte.

What this reader CAN see
------------------------
* the URI attached to any individual cell, at the position it landed on screen
  after wrapping and scrolling (:meth:`LinkedScreen.uri_at`);
* contiguous linked runs per row with their visible text (:meth:`row_links`),
  which is what "the label is clickable and points at X" means;
* truncation of a linked row — the label lands in cells, so a sheared row is a
  short run, not a missing escape;
* an OSC 8 sequence that never closes, and one whose URI is not what it should
  be.

What it CANNOT see, and this bounds every claim made from it
------------------------------------------------------------
* **Reflow.** pyte does not re-wrap on resize; libvte does. Rows OSA has
  surrendered to native scrollback are re-wrapped by the emulator, and this
  reader models none of that. It is the right instrument for OSA's *own*
  source-backed resize replay — which purges the projection and re-renders every
  retained message, so the content under test is re-emitted rather than
  re-wrapped — and the wrong instrument for anything about surrendered rows.
  Use ``vte_content_reflow.py`` for those.
* **What the emulator does with the URI.** Whether a terminal makes the run
  clickable, how it groups runs sharing an ``id=`` parameter, and whether it
  honours a scheme are the emulator's business. This reports the attribute
  arriving, not the click.
* **Anything before the mark it replays from.** :func:`replay` starts from an
  empty screen.

Proving the reader wrong before trusting it
-------------------------------------------
Four separate instrument faults have been found in this area, so the negative
case is asserted, not assumed: :func:`selfcheck` (``python3 osc8_reader.py``)
drives linked text, unlinked text, a link overwritten by plain text, an erase,
and a scroll, and fails unless the reader reports ``None`` for every cell that
must not carry a URI. A reader that says "linked" everywhere passes no test here.
"""

from __future__ import annotations

import re
import sys

try:
    import pyte
    from wcwidth import wcwidth
except ImportError:  # pragma: no cover - environment guard
    import pyte
    from pyte.screens import wcwidth  # type: ignore[attr-defined]

# `ESC ]8; params ; URI ST` — ST being either `ESC \` or a bare BEL. Params and
# URI may not contain ESC or BEL (a terminator inside either would end the
# string early, which is the injection `render::sanitize::sanitize_osc_uri`
# percent-encodes against).
OSC8_RE = re.compile("\x1b\\]8;([^;\x1b\x07]*);([^\x1b\x07]*)(?:\x1b\\\\|\x07)")

#: The introducer, used to hold back a sequence split across two PTY reads.
_INTRO = "\x1b]8;"


class LinkedScreen(pyte.HistoryScreen):
    """A pyte screen that also carries libvte's per-cell ``hyperlink_uri``.

    Tags live at ``(row, column)`` on the VISIBLE screen and are maintained
    through every operation that can move or destroy the cell they describe:

    * a write clears the tag it overwrites, so a linked cell repainted with
      plain text stops reporting a URI (without this the reader would report a
      link that is no longer on screen — the whole failure mode this harness
      keeps finding);
    * ``index`` / ``reverse_index`` / ``insert_lines`` / ``delete_lines`` shift
      tags with the rows they move, and drop what scrolls out of the region;
    * the erase family drops tags over the cells it blanks;
    * ``reset`` and ``resize`` drop everything.

    Rows that scroll off the top are gone from here, as they are from
    ``screen.display``. Read the screen before it scrolls, or replay a bounded
    stretch of the stream (see :func:`replay`).
    """

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.links: dict[tuple[int, int], str] = {}
        self._uri: str | None = None
        #: ``(uri, text)`` for every linked run that scrolled off the top.
        #: A transcript longer than the screen puts committed rows here, and a
        #: reader that only looked at ``display`` would call that a lost link.
        self.scrolled: list[tuple[str, str]] = []

    # -- the attribute under test -----------------------------------------

    def set_hyperlink(self, uri: str | None) -> None:
        """Open (non-empty ``uri``) or close (empty/``None``) the active link."""
        self._uri = uri or None

    def uri_at(self, y: int, x: int) -> str | None:
        """The URI attached to the cell at row ``y``, column ``x``, or ``None``."""
        return self.links.get((y, x))

    def row_text(self, y: int) -> str:
        return self.display[y].rstrip() if 0 <= y < self.lines else ""

    def row_links(self, y: int) -> list[tuple[str, str, int, int]]:
        """Contiguous linked runs on row ``y`` as ``(uri, text, x0, x1)``.

        ``text`` is the visible label as it landed in cells, so a run sheared by
        truncation reports the short label rather than the intended one — the
        difference between "the link survived" and "the link's escape survived
        while its text was cut".
        """
        runs: list[tuple[str, str, int, int]] = []
        row = self.buffer[y]
        x = 0
        while x < self.columns:
            uri = self.links.get((y, x))
            if uri is None:
                x += 1
                continue
            x0 = x
            text = []
            while x < self.columns and self.links.get((y, x)) == uri:
                text.append(row[x].data)
                x += 1
            runs.append((uri, "".join(text), x0, x - 1))
        return runs

    def all_links(self) -> list[tuple[str, str, int, int]]:
        """Every linked run on the visible screen, top row first."""
        out = []
        for y in range(self.lines):
            for uri, text, x0, x1 in self.row_links(y):
                out.append((uri, text, y, x0))
        return out

    # -- keeping the tags honest ------------------------------------------

    def draw(self, data: str) -> None:
        # One character at a time so the landing cell is knowable: after pyte
        # has handled autowrap and scrolling, the cell just written is at
        # `(cursor.y, cursor.x - width)`. A bulk draw hides that.
        for char in data:
            super().draw(char)
            width = max(wcwidth(char), 0) or 1
            x = self.cursor.x - width
            y = self.cursor.y
            if x < 0:
                # Wrapped exactly at the margin with DECAWM off; pyte left the
                # cursor pinned, so the cell is the last column.
                x = max(self.columns - width, 0)
            if self._uri is None:
                self.links.pop((y, x), None)
            else:
                self.links[(y, x)] = self._uri
            for dx in range(1, width):
                self.links.pop((y, x + dx), None)

    def _shift(self, top: int, bottom: int, by: int) -> None:
        """Move tags on rows ``[top, bottom]`` by ``by`` rows, dropping strays."""
        moved: dict[tuple[int, int], str] = {}
        for (y, x), uri in self.links.items():
            if top <= y <= bottom:
                ny = y + by
                if top <= ny <= bottom:
                    moved[(ny, x)] = uri
            else:
                moved[(y, x)] = uri
        self.links = moved

    def index(self) -> None:
        top, bottom = self.margins or pyte.screens.Margins(0, self.lines - 1)
        scrolls = self.cursor.y == bottom
        if scrolls:
            for uri, text, _x0, _x1 in self.row_links(top):
                self.scrolled.append((uri, text))
        super().index()
        if scrolls:
            self._shift(top, bottom, -1)

    def reverse_index(self) -> None:
        top, bottom = self.margins or pyte.screens.Margins(0, self.lines - 1)
        scrolls = self.cursor.y == top
        super().reverse_index()
        if scrolls:
            self._shift(top, bottom, 1)

    def insert_lines(self, count: int | None = None) -> None:
        top, bottom = self.margins or pyte.screens.Margins(0, self.lines - 1)
        count = count or 1
        if top <= self.cursor.y <= bottom:
            self._shift(self.cursor.y, bottom, count)
        super().insert_lines(count)

    def delete_lines(self, count: int | None = None) -> None:
        top, bottom = self.margins or pyte.screens.Margins(0, self.lines - 1)
        count = count or 1
        if top <= self.cursor.y <= bottom:
            self._shift(self.cursor.y, bottom, -count)
        super().delete_lines(count)

    def _drop_row(self, y: int, x0: int = 0, x1: int | None = None) -> None:
        x1 = self.columns - 1 if x1 is None else x1
        for x in range(x0, x1 + 1):
            self.links.pop((y, x), None)

    def erase_in_line(self, how: int = 0, private: bool = False) -> None:
        if how == 0:
            self._drop_row(self.cursor.y, self.cursor.x)
        elif how == 1:
            self._drop_row(self.cursor.y, 0, self.cursor.x)
        else:
            self._drop_row(self.cursor.y)
        super().erase_in_line(how, private)

    def erase_in_display(self, how: int = 0, *args, **kwargs) -> None:
        if how == 0:
            self._drop_row(self.cursor.y, self.cursor.x)
            for y in range(self.cursor.y + 1, self.lines):
                self._drop_row(y)
        elif how == 1:
            self._drop_row(self.cursor.y, 0, self.cursor.x)
            for y in range(0, self.cursor.y):
                self._drop_row(y)
        else:
            self.links.clear()
        super().erase_in_display(how, *args, **kwargs)

    def erase_characters(self, count: int | None = None) -> None:
        count = count or 1
        self._drop_row(self.cursor.y, self.cursor.x, min(self.cursor.x + count - 1,
                                                         self.columns - 1))
        super().erase_characters(count)

    def reset(self) -> None:
        super().reset()
        self.links = {}
        self._uri = None

    def resize(self, lines: int | None = None, columns: int | None = None) -> None:
        super().resize(lines, columns)
        # pyte does not reflow, so no tag can be trusted across a geometry
        # change. Dropping them is the honest option; replay instead.
        self.links = {}


class LinkFeeder:
    """Feed a byte stream to a :class:`LinkedScreen`, honouring OSC 8.

    pyte's own OSC branch swallows code 8 (it dispatches 0/1/2 only), so the
    sequences are lifted out here and turned into
    :meth:`LinkedScreen.set_hyperlink` calls before the surrounding text reaches
    the emulator.

    Partial sequences are held back: a PTY read can split ``ESC ]8;;https://…``
    anywhere, and feeding half of it would put the URI on screen as text.
    """

    def __init__(self, screen: LinkedScreen) -> None:
        self.screen = screen
        self.stream = pyte.Stream(screen)
        self._pending = ""
        #: Every (params, uri) pair seen, in order — including the empty-URI
        #: closers, so an unbalanced sequence is visible.
        self.sequences: list[tuple[str, str]] = []

    def feed(self, data: str) -> None:
        buf = self._pending + data
        self._pending = ""
        pos = 0
        while True:
            match = OSC8_RE.search(buf, pos)
            if match is None:
                break
            if match.start() > pos:
                self.stream.feed(buf[pos:match.start()])
            params, uri = match.group(1), match.group(2)
            self.sequences.append((params, uri))
            self.screen.set_hyperlink(uri)
            pos = match.end()
        rest = buf[pos:]
        hold = _partial_osc8_start(rest)
        if hold is not None:
            self.stream.feed(rest[:hold])
            self._pending = rest[hold:]
        else:
            self.stream.feed(rest)

    def unclosed(self) -> bool:
        """True if the stream ends inside an open hyperlink.

        A live hazard, not a nicety: an unterminated OSC 8 handed to the shell
        makes the prompt after OSA exits part of the link.
        """
        return self.screen._uri is not None


def _partial_osc8_start(rest: str) -> int | None:
    """Index at which ``rest`` starts something that may become an OSC 8, else None.

    Anchored on the INTRODUCER, never on the last ESC. Anchoring on the last ESC
    is wrong and quietly so: an open sequence whose read ended one byte into its
    terminator (``ESC ]8;;https://…  ESC``) has its final ESC *inside* the
    sequence, so the last-ESC rule fed ``ESC ]8;;https://…`` to the emulator as
    a complete-looking OSC and dropped the link. That is how the first draft of
    this reader lost a URI it had been handed correctly.
    """
    start = rest.rfind(_INTRO)
    if start != -1:
        tail = rest[start + len(_INTRO):]
        if "\x1b\\" not in tail and "\x07" not in tail:
            return start
    # A fragment of the introducer itself, split mid-way. Longest match wins.
    for k in range(len(_INTRO) - 1, 0, -1):
        if rest.endswith(_INTRO[:k]):
            return len(rest) - k
    return None


def replay(
    data: bytes,
    cols: int,
    rows: int,
    history: int = 4000,
) -> tuple[LinkedScreen, LinkFeeder]:
    """Render ``data`` into a fresh hyperlink-aware screen of the given size.

    Intended use is a stretch of ``PtySession.emitted_since(mark)`` at the
    geometry that stretch was drawn for. That keeps the reader clear of every
    coordinate question the other readers in this directory got wrong: the
    replay starts at a known origin, at one known width, with no scrollback
    history to address.
    """
    screen = LinkedScreen(cols, rows, history=history)
    feeder = LinkFeeder(screen)
    feeder.feed(data.decode("utf-8", "replace"))
    return screen, feeder


# --- the negative case, asserted ------------------------------------------


def selfcheck() -> int:
    """Fail unless the reader can tell a linked cell from an unlinked one."""
    failures: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if not cond:
            failures.append(msg)

    def osc8(text: str, uri: str) -> str:
        return f"\x1b]8;;{uri}\x1b\\{text}\x1b]8;;\x1b\\"

    # 1. Positive and negative on one row: only the linked run carries a URI.
    screen, feeder = replay(
        ("PLAIN " + osc8("LINKED", "https://osa.dev/a") + " TAIL").encode(), 40, 6
    )
    check(screen.row_text(0) == "PLAIN LINKED TAIL",
          f"visible text mangled: {screen.row_text(0)!r}")
    check(screen.uri_at(0, 0) is None, "an unlinked cell reported a URI")
    check(screen.uri_at(0, 5) is None, "the space before the link reported a URI")
    check(screen.uri_at(0, 6) == "https://osa.dev/a",
          f"linked cell reported {screen.uri_at(0, 6)!r}")
    check(screen.uri_at(0, 11) == "https://osa.dev/a", "last linked cell lost its URI")
    check(screen.uri_at(0, 12) is None, "the link leaked past its terminator")
    check(screen.row_links(0) == [("https://osa.dev/a", "LINKED", 6, 11)],
          f"row_links wrong: {screen.row_links(0)!r}")
    check(not feeder.unclosed(), "a closed link was reported open")

    # 2. A stream that never closes its link IS reported open.
    _, open_feeder = replay(("x\x1b]8;;https://osa.dev/b\x1b\\open").encode(), 40, 6)
    check(open_feeder.unclosed(), "an unterminated hyperlink was not detected")

    # 3. Overwriting a linked cell with plain text drops the URI. Without this
    #    the reader reports links that are no longer on screen.
    screen, _ = replay(
        (osc8("LINKED", "https://osa.dev/a") + "\r" + "plains").encode(), 40, 6
    )
    check(screen.row_text(0) == "plains", f"overwrite failed: {screen.row_text(0)!r}")
    check(all(screen.uri_at(0, x) is None for x in range(6)),
          f"a URI survived being overwritten: {screen.row_links(0)!r}")

    # 4. Erasing the row drops the URI.
    screen, _ = replay(
        (osc8("LINKED", "https://osa.dev/a") + "\r\x1b[2K").encode(), 40, 6
    )
    check(screen.all_links() == [], f"a URI survived an erase: {screen.all_links()!r}")

    # 5. A link scrolls with its row, and reports its new position.
    screen, _ = replay(
        (osc8("LINKED", "https://osa.dev/a") + "\r\n" * 3 + "end").encode(), 40, 4
    )
    check(screen.uri_at(0, 0) == "https://osa.dev/a",
          f"link lost across newlines: {screen.all_links()!r}")
    screen, _ = replay(
        (osc8("LINKED", "https://osa.dev/a") + "\r\n" * 6 + "end").encode(), 40, 4
    )
    check(screen.all_links() == [],
          f"a scrolled-off link stayed addressable: {screen.all_links()!r}")
    check(screen.scrolled == [("https://osa.dev/a", "LINKED")],
          f"a scrolled-off link was not recorded: {screen.scrolled!r}")

    # 6. A split feed must not put the URI on screen as text.
    screen = LinkedScreen(40, 4)
    feeder = LinkFeeder(screen)
    blob = "A" + osc8("LINKED", "https://osa.dev/c") + "B"
    for i in range(0, len(blob), 3):
        feeder.feed(blob[i:i + 3])
    check(screen.row_text(0) == "ALINKEDB",
          f"split feed leaked escape text: {screen.row_text(0)!r}")
    check(screen.uri_at(0, 1) == "https://osa.dev/c",
          "split feed lost the URI")

    # 7. Two different links on one row keep their own URIs.
    screen, _ = replay(
        (osc8("one", "https://osa.dev/1") + " " + osc8("two", "https://osa.dev/2")).encode(),
        40, 4,
    )
    check([r[0] for r in screen.row_links(0)] == ["https://osa.dev/1", "https://osa.dev/2"],
          f"adjacent links merged or swapped: {screen.row_links(0)!r}")

    for f in failures:
        print(f"  FAIL  {f}")
    if failures:
        print("\nThe reader is wrong. Nothing measured with it means anything.")
        return 1
    print("  PASS  linked cells report their URI; unlinked cells report None")
    print("        (overwrite, erase, scroll-off and split feeds all clear it)")
    return 0


if __name__ == "__main__":
    sys.exit(selfcheck())
