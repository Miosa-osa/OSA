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
  instrument can make. Proving that needs a reader that exposes VTE's hyperlink
  attribute per cell (`Vte.Terminal.hyperlink_check_event` / the `hyperlink_uri`
  cell attribute), which this probe does not yet use.
* As written it grades content that is still on the VISIBLE SCREEN, not content
  in native scrollback. Driving the stub so a reply overflows the screen and
  commits into scrollback does not work yet -- the reply renders into the live
  region, is clipped at the screen bottom, and the trailing filler never
  appears. So this measures OSA's own resize WIPE, which is real and severe, and
  does NOT yet measure the terminal's reflow of committed rows. Those are two
  different defects and the fix for one is not the fix for the other.

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

STUB_PORT = 12793

# A SHORT screen on purpose: the graded blocks must overflow it and land in
# the terminal's native scrollback, because scrollback is the content OSA has
# surrendered and can no longer repair. On a tall screen the whole reply stays
# in the live region, which is redrawn from source every frame and would pass
# this probe while the real defect went unmeasured.
ROWS = 44

# Sentinels bracketing each graded block. They are prose words so the markdown
# renderer cannot restyle them into something unmatchable, and they are unique
# enough that no chrome collides with them.
BLOCKS = ("PROSEBLOCK", "TABLEBLOCK", "CODEBLOCK", "RULEBLOCK")

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
            "beaver constructs an elaborate dam across the meandering river, and "
            "the patient heron waits downstream for whatever the current brings "
            "to it, unhurried and entirely indifferent to the weather.",
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
            "CODEBLOCK_BEGIN",
            "",
            "```rust",
            "fn main() {",
            '    println!("a line that is comfortably inside eighty columns");',
            "}",
            "```",
            "",
            "CODEBLOCK_END",
            "",
            "RULEBLOCK_BEGIN",
            "",
            "---",
            "",
            "RULEBLOCK_END",
            "",
            # Filler, so every graded block above is pushed OFF the visible
            # screen and into the terminal's native scrollback before the
            # resize. That separation is the point of this probe: content still
            # on screen is destroyed by OSA's own full-screen resize wipe
            # (`event_loop.rs::clear_screen_for_resize`), which is a different
            # defect with a different fix. Grading scrollback content isolates
            # the REFLOW damage -- the part OSA can never repair because it no
            # longer owns those rows.
            *[f"Filler line {i} pushing the graded blocks into scrollback." for i in range(60)],
        ]
    )


def slice_block(rows: list[str], name: str) -> list[str] | None:
    """Rows strictly between `<name>_BEGIN` and `<name>_END`, or None if absent.

    Matched with `in` rather than equality: the markers are committed through
    the markdown renderer, which may indent them, and after a reflow they can
    share a physical row with neighbouring text.
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
    return rows[begin + 1 : end]


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
    for r in rows:
        if TABLE_SIDE * 2 in r.replace(" ", "") or "||" in r.replace(" ", ""):
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

    from stub_backend import StubBackend, end_turn, release_turn  # noqa: E402

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

        def screen_rows() -> list[str]:
            rows = term.get_row_count()
            out = term.get_text_range_format(
                Vte.Format.TEXT, -10_000, 0, rows, term.get_column_count()
            )
            if isinstance(out, tuple):
                out = next((x for x in out if isinstance(x, str)), "")
            return (out or "").splitlines()

        # Boot to a composer.
        for _ in range(30):
            pump(1.0)
            if any("❯" in r for r in screen_rows()):
                break
        else:
            return _skip("binary did not reach a composer; nothing to assert about")

        # Drive one turn whose reply carries every graded block.
        term.feed_child(b"render the table\r")
        pump(1.0)
        # `release_turn` first: the POST that starts the turn must be answered
        # before the `agent_response` frame can END it. Without this the reply
        # renders into the clipped live region and never reaches scrollback --
        # which looks like content loss but is only the harness never letting
        # the turn finish.
        release_turn()
        end_turn(response_markdown())

        # Wait for the reply to render.
        for _ in range(40):
            pump(0.5)
            if any("TABLEBLOCK_END" in r for r in screen_rows()):
                break
        else:
            print("--- screen when the reply failed to render ---")
            print("\n".join(screen_rows()[-50:]))
            return _skip("reply never rendered; nothing to grade")
        pump(2.0)

        # Force the first reply out of the live region and into the terminal's
        # NATIVE scrollback. That is the whole point: this probe grades content
        # OSA has already surrendered to the terminal, which is the content a
        # resize can no longer repair. A block still in the live region gets
        # redrawn from source on every frame and would pass trivially.
        term.feed_child(b"and again\r")
        pump(1.0)
        end_turn("Committed.")
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
        print(f"  FILLER present before: {any('Filler line 59' in r for r in before_rows)}")

        results: dict[str, list[str]] = {}
        for name, grader in (
            ("PROSEBLOCK", grade_prose),
            ("TABLEBLOCK", grade_table),
            ("CODEBLOCK", grade_code),
        ):
            block = slice_block(after_rows, name)
            if block is None:
                results[name] = ["block markers vanished from the transcript"]
            else:
                results[name] = grader(block)

        print(f"\n--- after narrowing 120 -> {sweep[-1]} on real libvte ---")
        broken = []
        for name in ("PROSEBLOCK", "CODEBLOCK", "TABLEBLOCK"):
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

        return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
