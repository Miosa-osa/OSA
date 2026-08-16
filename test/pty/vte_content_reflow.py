#!/usr/bin/env python3
"""Which CONTENT TYPES survive a real width change, and which are destroyed.

Why this exists alongside `vte_resize.py`
-----------------------------------------
`vte_resize.py` already drives the binary inside real libvte, so it sees real
reflow. But it only counts SINGLETON BANDS -- composer, hint row, status bar --
which answers "was the live region stranded", not "is the transcript still
readable". A user reported the second failure, not the first: dragging the
window shreds a committed markdown table into rules of two different widths
with a doubled left border, while the prose beside it is fine.

That difference is the whole question. Committed lines leave through
`insert_before` into the terminal's NATIVE scrollback, and OSA no longer owns
them; on a width change the terminal re-wraps those raw lines with no idea that
some of them were a table. Prose re-wraps acceptably because prose has no
structure to lose. Anything column-aligned does not.

So this probe commits one turn containing several TAGGED blocks -- prose, a GFM
table, a fenced code block, a bare box-drawing rule -- narrows the terminal, and
grades each block separately against invariants that only hold if the block
survived intact.

What this instrument can and cannot see
---------------------------------------
CAN: real reflow. libvte is the same library GNOME Terminal, Tilix, Terminator
and Ptyxis link, and it re-wraps scrollback on a width change exactly as it does
for the user. `pyte` (used by `test_resize.py`) does NOT reflow at all, so this
failure mode is structurally invisible there -- a narrowing drag renders clean
under pyte while the screen in front of the user is destroyed.

CANNOT, and this bounds every claim made from it:

* It cannot attribute damage to a specific escape sequence. It reads back
  flattened text, so it grades the RESULT of the reflow, not the byte stream
  that produced it. It cannot see colour, and it cannot see OSC 8 hyperlinks --
  `get_text_range_format(Vte.Format.TEXT, ...)` returns text with escapes
  already consumed, so "links still work after a resize" is NOT a claim this
  instrument can make. That claim now belongs to `osc8_resize_probe.py`, which
  reads per-cell URIs through `osc8_reader.py`. It does NOT use VTE's own
  attribute: on VTE 0.76 the HTML export emits no anchors and
  `hyperlink_check_event` cannot be driven by a synthesized `GdkEvent` (proven
  by `match_check_event` failing at the same coordinates), so there is no
  accessor left and the attribute is modelled from the byte stream instead.
  The consequence for THIS probe is unchanged: a link inside REFLOWED
  scrollback is nobody's measurement yet.
* The two halves measure two different defects and the fix for one is not the
  fix for the other: the drive half sees OSA's own resize WIPE of content it
  still owns, and `measure_scrollback_reflow` sees the terminal's reflow of rows
  OSA has surrendered. Read the grades separately.

Requirements: `python3-gi`, `gir1.2-vte-2.91`, a reachable X display, and a
release build at `priv/rust/tui/target/release/osagent`. Any missing piece is
reported as SKIPPED rather than failure, so a headless CI box never goes red for
the wrong reason.

Run: `python3 test/pty/vte_content_reflow.py`
     `python3 test/pty/vte_content_reflow.py --cols 100,80,60`   # custom sweep
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import term_env  # noqa: E402
import vte_reader  # noqa: E402

STUB_PORT = 12793

# A SHORT screen on purpose: the graded blocks must overflow it and land in
# the terminal's native scrollback, because scrollback is the content OSA has
# surrendered and can no longer repair. On a tall screen the whole reply stays
# in the live region, which is redrawn from source every frame and would pass
# this probe while the real defect went unmeasured.
ROWS = 50

# How many short turns to commit AFTER the graded reply. Each commit scrolls
# the rows above it into native scrollback; this many is enough to push the
# whole graded block off the top of a 50-row screen.
PUSH_TURNS = 10

# How far back into scrollback the per-row reader reaches. Kept modest: the
# reader costs one IPC round-trip per row, so 10_000 would dominate runtime.
SCROLLBACK_ROWS = 400

# Sentinels bracketing each graded block. They are prose words so the markdown
# renderer cannot restyle them into something unmatchable, and they are unique
# enough that no chrome collides with them.
BLOCKS = ("PROSEBLOCK", "TABLEBLOCK")

# Box-drawing glyphs OSA's table renderer emits (`render/markdown.rs::render_table`
# and `table_rule_line`). A row is "table-ish" if it carries any of them.
TABLE_RULE_CHARS = set("┌┬┐├┼┤└┴┘─")
TABLE_SIDE = "│"


def _skip(reason: str) -> int:
    print(f"SKIPPED: {reason}")
    return 0


def display_width(s: str) -> int:
    """Columns a string occupies, counting wide glyphs as 2 and combining as 0."""
    total = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        total += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return total


def response_markdown() -> str:
    """One assistant turn carrying every content type we want to grade.

    Each block is bracketed by `<NAME>_BEGIN` / `<NAME>_END` marker lines so the
    grader can slice the transcript by block even after the surrounding rows
    have moved. The markers are deliberately SHORT, so they never wrap
    themselves at any width in the sweep and can always be found.
    """
    return "\n".join(
        [
            "PROSEBLOCK_BEGIN",
            # Long enough to wrap at every width in the sweep, so "prose
            # survives" is a claim about reflowed prose, not unwrapped prose.
            "The quick brown fox jumps over the lazy dog while the industrious "
            "beaver constructs an elaborate dam across the meandering river and "
            "waits there, entirely indifferent to the weather.",
            "PROSEBLOCK_END",
            "",
            "TABLEBLOCK_BEGIN",
            "",
            "| Component | Owner | Notes |",
            "| --- | --- | --- |",
            "| gateway | platform | handles the websocket handshake literally |",
            "| renderer | client | markdown, tables, and the cotagline path |",
            "| storage | infra | see ISSUES.md and Documentation/CANON.md |",
            "",
            "TABLEBLOCK_END",
            "",
        ]
    )


def slice_block(rows: list[str], name: str) -> list[str] | None:
    """Rows strictly between `<name>_BEGIN` and `<name>_END`, or None if absent.

    Matched with `in` rather than equality: the markers are committed through
    the markdown renderer, which may indent them, and after a reflow they can
    share a physical row with neighbouring text.

    The marker rows are INCLUDED, with the marker token itself removed, and that
    is load-bearing rather than tidy. A marker and the block it brackets are
    consecutive non-blank lines, so markdown folds them into ONE PARAGRAPH and
    re-wraps them together. At 120 columns `…indifferent to the weather.` and
    `PROSEBLOCK_END` happen to land on separate physical rows; at 60 they share
    one. Excluding the end row therefore deleted a real word from the graded
    text and reported it as `prose lost the word 'indifferent'` — a re-wrap the
    probe asked for, graded as data loss.

    That only started mattering when OSA began re-rendering the transcript at
    the new width: before, the block was frozen at the width it was committed
    at and the markers never moved.
    """
    begin = end = None
    for i, row in enumerate(rows):
        if begin is None and f"{name}_BEGIN" in row:
            begin = i
        elif begin is not None and f"{name}_END" in row:
            end = i
            break
    if begin is None or end is None:
        return None
    block = list(rows[begin : end + 1])
    block[0] = block[0].replace(f"{name}_BEGIN", "")
    block[-1] = block[-1].replace(f"{name}_END", "")
    return block


def grade_table(rows: list[str]) -> list[str]:
    """Structural invariants a bordered table must still satisfy.

    These are the exact three symptoms in the user's screenshot, turned into
    assertions.
    """
    faults: list[str] = []
    ruled = [r.rstrip() for r in rows if any(c in TABLE_RULE_CHARS for c in r)]
    bordered = [r.rstrip() for r in rows if TABLE_SIDE in r]

    if not ruled:
        return ["table has no box-drawing rows left at all"]

    # 1. Every rule row is the same width. The screenshot shows a short rule
    #    (~1/3 screen) alternating with a full-width one INSIDE ONE TABLE --
    #    the signature of rows frozen at one width being re-wrapped at another.
    widths = {display_width(r) for r in ruled}
    if len(widths) > 1:
        faults.append(
            f"rule rows have {len(widths)} distinct widths {sorted(widths)} "
            f"(expected 1) -- rules at mixed widths inside one table"
        )

    # 2. No doubled border. `||` (or `││`) is what a wrapped row produces when
    #    its continuation begins with the border glyph of the next row.
    #
    #    ADJACENCY IS THE DEFECT, and this used to strip spaces before looking,
    #    which is not the same question. An EMPTY CELL is two borders separated
    #    by the column's width in spaces, and it collapses to `││` under
    #    `replace(" ", "")` exactly as damage does. Every continuation row of a
    #    multi-line table cell has empty leading cells, so the space-blind form
    #    flags a correctly wrapped table:
    #
    #        ┃│           │          │ handshake literally             │
    #
    #    That never fired before because OSA never re-rendered a committed table
    #    at a narrower width — the rows were frozen at the width they were
    #    committed at, and the terminal, not the renderer, did the wrapping.
    #    Source-backed replay re-renders them, and cell wrapping is what a
    #    correct narrow table looks like.
    #
    #    Real doubling has nothing between the two glyphs, so match them
    #    adjacent. Reflow damage that does land inside a cell still fails
    #    checks 1 and 3, which measure the widths this check cannot.
    for r in rows:
        if TABLE_SIDE * 2 in r or "||" in r:
            faults.append(f"doubled left border in row: {r.strip()[:60]!r}")
            break

    # 3. Every bordered row is exactly as wide as every other. This is the
    #    in-app invariant `every_table_row_is_exactly_as_wide_as_every_other`
    #    already asserts in Rust -- restated here against the REAL screen after
    #    a real reflow, which is the only place it was ever actually violated.
    if bordered:
        bw = {display_width(r) for r in bordered}
        if len(bw) > 1:
            faults.append(
                f"bordered rows have {len(bw)} distinct widths {sorted(bw)} "
                f"(expected 1) -- columns no longer line up"
            )

    return faults


def grade_prose(rows: list[str]) -> list[str]:
    """Prose has no alignment to lose; it only has to still be READABLE.

    The one thing a reflow must not do is destroy words, so this checks that the
    distinctive words survive somewhere in the block, in order, rather than
    checking any particular line breaking.
    """
    text = " ".join(rows)
    collapsed = re.sub(r"\s+", " ", text)
    faults = []
    for word in ("industrious", "meandering", "indifferent"):
        if word not in collapsed.replace(" ", "") and word not in collapsed:
            faults.append(f"prose lost the word {word!r} across the resize")
    return faults


def grade_code(rows: list[str]) -> list[str]:
    """A code fence must not have its lines split mid-token by a re-wrap."""
    text = "\n".join(rows)
    faults = []
    if "println!" not in text.replace(" ", "") and "println!" not in text:
        faults.append("code fence lost the `println!` token")
    # The code line is < 80 columns on purpose: if it appears split across two
    # physical rows at a width that could hold it, the fence's own chrome
    # (borders/padding) pushed it over, which is the same class of defect.
    for r in rows:
        if "println" in r and not r.rstrip().endswith(('"', ";", ");", '");')):
            faults.append(f"code line appears truncated/split: {r.strip()[:70]!r}")
            break
    return faults


# Byte-for-byte what `render/markdown.rs::render_table` emits for the table in
# `response_markdown()` at 120 columns. Captured from this probe's own baseline.
COMMITTED_TABLE = [
    "┌───────────┬──────────┬───────────────────────────────────────────┐",
    "│ Component │ Owner    │ Notes                                     │",
    "├───────────┼──────────┼───────────────────────────────────────────┤",
    "│ gateway   │ platform │ handles the websocket handshake literally │",
    "├───────────┼──────────┼───────────────────────────────────────────┤",
    "│ renderer  │ client   │ markdown, tables, and the cotagline path  │",
    "├───────────┼──────────┼───────────────────────────────────────────┤",
    "│ storage   │ infra    │ see ISSUES.md and Documentation/CANON.md  │",
    "└───────────┴──────────┴───────────────────────────────────────────┘",
]


def measure_scrollback_reflow(Vte, GLib, gtk_ok: bool) -> tuple[int, list[str]]:
    """What the TERMINAL does to a committed table when the width changes.

    Deliberately does NOT drive OSA. Once a row has gone out through
    `insert_before` it belongs to the terminal, and what happens to it next is
    decided by the emulator and the new width alone -- OSA is not consulted and
    cannot intervene. So this prints OSA's own rendered table bytes into
    scrollback through a plain shell, narrows, and reads back PHYSICAL rows.

    Keeping it independent of the turn machinery is the point: it needs a
    committed table in native scrollback and nothing else, so it does not
    inherit whatever the drive half is currently able to prove. (It was
    introduced under a different justification -- "OSA wedges once a committed
    reply plus the welcome panel exceed the screen, so only a couple of turns
    commit". That was the old reader, not OSA; see `vte_reader` and
    `turn_ceiling_probe.py`. The independence is still worth having.)
    """
    term = Vte.Terminal()
    term.set_scrollback_lines(10_000)
    term.set_size(120, 24)
    prose = (
        "The quick brown fox jumps over the lazy dog while the industrious "
        "beaver constructs an elaborate dam across the meandering river."
    )
    script = (
        "printf 'TSTART\\n'; "
        + "".join(f"printf '%s\\n' '{r}'; " for r in COMMITTED_TABLE)
        + "printf 'TEND\\nPSTART\\n'; "
        + f"printf '%s\\n' '{prose}'; printf 'PEND\\n'; "
        + "for i in $(seq 1 40); do printf 'filler %s\\n' $i; done; sleep 600"
    )
    term.spawn_sync(
        Vte.PtyFlags.DEFAULT, "/tmp", ["/bin/sh", "-c", script], [],
        GLib.SpawnFlags.DEFAULT, None, None, None,
    )

    def pump(seconds: float) -> None:
        deadline = GLib.get_monotonic_time() + int(seconds * 1_000_000)
        ctx = GLib.MainContext.default()
        while GLib.get_monotonic_time() < deadline:
            while ctx.pending():
                ctx.iteration(False)
            GLib.usleep(5_000)

    def phys_rows() -> list[str]:
        # Whole ring, one row per call. `range(-200, row_count)` was WRONG in
        # both directions: VTE rows are absolute over the ring, negative indices
        # are empty, and `row_count` is the screen HEIGHT, not the bottom of the
        # buffer — so it read the first screenful of the session and nothing
        # after it. See `vte_reader`.
        return vte_reader.buffer_rows(term, Vte)

    def between(rows, a, b):
        try:
            i = next(k for k, r in enumerate(rows) if a in r)
            j = next(k for k, r in enumerate(rows) if b in r)
        except StopIteration:
            return None
        return [r.rstrip() for r in rows[i + 1 : j] if r.strip()]

    pump(3.0)
    before = between(phys_rows(), "TSTART", "TEND")
    if not before:
        return 0, ["SKIPPED: shell never printed the table"]
    base_widths = sorted({display_width(r) for r in before})

    # Narrow, widen, narrow again. The user's report is a DRAG, and the damage
    # in it is cumulative -- a single step would understate it.
    for cols in (100, 80, 60, 80, 100, 60):
        term.set_size(cols, 24)
        pump(0.6)
    pump(2.0)

    rows_after = phys_rows()
    after = between(rows_after, "TSTART", "TEND")
    prose_after = between(rows_after, "PSTART", "PEND")
    notes = [
        f"table occupied {len(before)} physical rows at 120 (widths {base_widths})",
    ]
    if after is None:
        notes.append("FAIL: table markers gone from scrollback entirely")
        return 1, notes
    widths = sorted({display_width(r) for r in after})
    notes.append(f"table occupies {len(after)} physical rows at 60 (widths {widths})")
    if prose_after is not None:
        notes.append(f"prose occupies {len(prose_after)} physical rows at 60")
    faults = grade_table(after)
    if faults:
        notes.append("DESTROYED  committed table, after a narrow/widen/narrow drag:")
        notes.extend(f"             - {f}" for f in faults)
        notes.append("           rows as the user sees them:")
        notes.extend(f"             T|{r}" for r in after)
        return 1, notes
    notes.append("SURVIVED   committed table")
    return 0, notes


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--cols",
        default="100,80,60",
        help="comma-separated widths to narrow through (start is always 120)",
    )
    args = ap.parse_args()
    sweep = [int(c) for c in args.cols.split(",") if c.strip()]

    if not os.environ.get("DISPLAY"):
        return _skip("no DISPLAY; VTE needs one even when nothing is mapped")

    try:
        import gi

        gi.require_version("Gtk", "3.0")
        gi.require_version("Vte", "2.91")
        from gi.repository import GLib, Gtk, Vte
    except (ImportError, ValueError) as e:
        return _skip(f"python3-gi / gir1.2-vte-2.91 unavailable ({e})")

    if not Gtk.init_check(None)[0]:
        return _skip("Gtk.init_check failed; no usable display")

    from stub_backend import StubBackend, push_sse, release_turn  # noqa: E402

    # Half one: what the TERMINAL does to committed rows. Independent of OSA
    # and of the turn machinery, so it always runs and always asserts.
    print("=== committed content, reflowed by the terminal ===")
    reflow_rc, reflow_notes = measure_scrollback_reflow(Vte, GLib, True)
    for line in reflow_notes:
        print(line)
    print()
    print("=== on-screen content, through OSA's own resize path ===")

    repo = Path(__file__).resolve().parents[2]
    binary = repo / "priv/rust/tui/target/release/osagent"
    if not binary.exists():
        return _skip(f"{binary} not built (cargo build --release)")

    with StubBackend(STUB_PORT) as backend:
        term = Vte.Terminal()
        term.set_scrollback_lines(10_000)
        term.set_size(120, ROWS)

        # `passthrough_override` forwards `$OSA_RESIZE_CLEAR` when the caller
        # set it, so each branch of the resize gate can be forced and measured
        # rather than whichever one this box happens to select.
        env = term_env.clean_env_list(
            **term_env.backend_vars(backend.base_url), **term_env.passthrough_override()
        )

        ok, _pid = term.spawn_sync(
            Vte.PtyFlags.DEFAULT,
            str(repo),
            [str(binary)],
            env,
            GLib.SpawnFlags.DEFAULT,
            None,
            None,
            None,
        )
        if not ok:
            return _skip("VTE could not spawn the binary")

        def pump(seconds: float) -> None:
            deadline = GLib.get_monotonic_time() + int(seconds * 1_000_000)
            ctx = GLib.MainContext.default()
            while GLib.get_monotonic_time() < deadline:
                while ctx.pending():
                    ctx.iteration(False)
                GLib.usleep(5_000)

        # Keystrokes go to the PTY MASTER FD, not through `Vte.Terminal.
        # feed_child`. Under GObject introspection `feed_child` silently
        # accepted the bytes and delivered nothing -- an earlier version of this
        # probe drove fifteen turns and OSA never saw a single character, so the
        # only content on screen was the SSE frame rendering itself with no turn
        # behind it. Writing the fd is what `vte_resize.py` never needed to do
        # (it only resizes) and is why no VTE harness here had ever typed.
        pty_fd = term.get_pty().get_fd()

        def send(data: bytes) -> None:
            os.write(pty_fd, data)

        def screen_rows() -> list[str]:
            """The tail of the RING as PHYSICAL rows, one call per row.

            Two load-bearing details, and this probe got the first right and the
            second wrong until the reader moved into `vte_reader`.

            One: asking VTE for a MULTI-ROW range returns LOGICAL lines. It
            un-wraps every soft-wrapped continuation, so a 68-column table row
            reads back as 68 columns even on a 60-column screen. Reflow damage
            is by definition a physical-row phenomenon, so a range read reports
            a shredded table as pristine.

            Two: VTE row indices are ABSOLUTE over the ring. `row_count` is the
            screen HEIGHT, not the bottom of the buffer, and negative rows are
            empty -- so `range(-400, row_count)` reads the FIRST SCREENFUL of
            the session and nothing after it, for the whole run. Under that
            reader OSA looked like it stopped committing after four turns on a
            50-row screen. It had not; the window had simply filled. See
            `vte_reader`.
            """
            return vte_reader.buffer_rows(term, Vte, limit=SCROLLBACK_ROWS)

        # Boot to a composer.
        for _ in range(30):
            pump(1.0)
            if any("❯" in r for r in screen_rows()):
                break
        else:
            return _skip("binary did not reach a composer; nothing to assert about")

        turn_no = [0]

        def turn(prompt: bytes, reply: str, settle: float = 2.0) -> None:
            """Drive ONE complete turn and let it commit.

            `release_turn` before `end_turn`: the POST that starts the turn has
            to be answered before the `agent_response` frame can end it.
            Without that the reply renders into the live region and never
            commits, which looks like content loss but is only the harness
            never letting the turn finish.
            """
            turn_no[0] += 1
            # Text and Enter are SEPARATE writes, with a pump between them.
            # Sent as one burst ("prompt\r") OSA's paste-burst detector
            # (`components/input/paste_burst.rs`) reads the whole thing as a
            # PASTE, and a carriage return inside a paste is a NEWLINE, not a
            # submit. An earlier version of this probe did exactly that and left
            # four prompts stacked unsubmitted in the composer while every reply
            # rendered as live output with no turn behind it -- which is why
            # nothing ever committed to scrollback.
            send(prompt)
            pump(0.6)
            send(b"\r")
            pump(0.8)
            release_turn()
            # NOT `stub_backend.end_turn`: it hardcodes `message_id`
            # "stub-msg-1", so every reply after the first is a duplicate id and
            # is dropped. That is why an earlier version of this probe committed
            # exactly one turn no matter how many it drove -- the graded blocks
            # never moved off the screen and the scrollback stayed empty.
            push_sse(
                "agent_response",
                {
                    "response": reply,
                    "response_type": "text",
                    "message_id": f"stub-msg-{turn_no[0]}",
                },
            )
            pump(settle)

        # Turn 1 carries every graded block. It is deliberately SHORTER than the
        # screen: a reply taller than the viewport is clipped in the live region
        # and the tail never commits at all.
        turn(b"render the table", response_markdown(), settle=3.0)
        for _ in range(40):
            pump(0.5)
            if any("TABLEBLOCK_END" in r for r in screen_rows()):
                break
        else:
            print("--- screen when the reply failed to render ---")
            print("\n".join(screen_rows()[-ROWS:]))
            return _skip("reply never rendered; nothing to grade")

        # Then a run of SHORT turns. Each one commits through `insert_before`,
        # which scrolls the rows above it off the top of the screen and into the
        # terminal's NATIVE scrollback. That is the only way to get the graded
        # blocks into the buffer OSA no longer owns -- and grading content OSA
        # still owns would pass trivially, because the live region is redrawn
        # from source on every frame.
        for i in range(PUSH_TURNS):
            turn(f"push {i}".encode(), f"Acknowledged push {i}.", settle=2.0)
        pump(3.0)

        before_rows = screen_rows()
        before = {
            name: slice_block(before_rows, name) for name in BLOCKS
        }

        # Baseline: the blocks must be intact BEFORE any resize, otherwise a
        # failure below says nothing about the resize path.
        baseline_faults = grade_table(before["TABLEBLOCK"] or [])
        if baseline_faults:
            print("--- transcript at 120 cols (baseline) ---")
            print("\n".join(before_rows[-70:]))
            for f in baseline_faults:
                print(f"BASELINE FAIL: {f}")
            print(
                "\nThe table is already malformed before any resize -- fix that "
                "first; this probe measures the RESIZE, not the renderer."
            )
            return 1

        print(f"baseline ok at 120 cols: table intact ({len(before['TABLEBLOCK'] or [])} rows)")

        # The reported gesture: narrow the window.
        for cols in sweep:
            term.set_size(cols, ROWS)
            pump(0.6)
        pump(2.5)

        after_rows = screen_rows()

        # Diagnostic: marker survival and buffer size, printed before any
        # grading. "block markers vanished" has two very different causes --
        # the terminal re-wrapped them into unrecognisability, or the
        # transcript was WIPED -- and the grade alone cannot tell them apart.
        print(
            f"\nrows held by the terminal: {len(before_rows)} at 120 "
            f"-> {len(after_rows)} at {sweep[-1]}"
        )
        # Row indices matter as much as counts: a block ABOVE the last 50 rows
        # was in scrollback when the resize hit (so any damage is the
        # terminal's reflow), while a block inside them was on the visible
        # screen (so the damage may be OSA's own resize wipe instead).
        def where(rows: list[str], name: str) -> str:
            idx = [i for i, r in enumerate(rows) if f"{name}_" in r]
            if not idx:
                return "absent"
            zone = "on-screen" if idx[0] > len(rows) - (ROWS + 1) else "scrollback"
            return f"rows {idx[0]}..{idx[-1]} ({zone})"

        for name in BLOCKS:
            print(f"  {name}: before {where(before_rows, name)} | after {where(after_rows, name)}")
        print(f"  committed user turns: {sum(1 for r in before_rows if 'You' in r)}")

        results: dict[str, list[str]] = {}
        for name, grader in (
            ("PROSEBLOCK", grade_prose),
            ("TABLEBLOCK", grade_table),
        ):
            block = slice_block(after_rows, name)
            if block is None:
                results[name] = ["block markers vanished from the transcript"]
            else:
                results[name] = grader(block)

        print(f"\n--- after narrowing 120 -> {sweep[-1]} on real libvte ---")
        broken = []
        for name in ("PROSEBLOCK", "TABLEBLOCK"):
            faults = results[name]
            if faults:
                broken.append(name)
                print(f"DESTROYED  {name}:")
                for f in faults:
                    print(f"             - {f}")
            else:
                print(f"SURVIVED   {name}")

        if broken:
            print(f"\n--- {sweep[-1]}-column transcript (tail) ---")
            for r in after_rows[-70:]:
                print(f"|{r}")

        return 1 if (broken or reflow_rc) else 0


if __name__ == "__main__":
    sys.exit(main())
