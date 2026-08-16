#!/usr/bin/env python3
"""A hyperlink must still be clickable, and still point at the right place,
after the terminal is resized.

Why this exists
---------------
OSC 8 hyperlinks were shipped and unit-tested, and then v1.0.104 changed the
ground under them: a resize now **purges the terminal projection and re-renders
every retained `Message` at the new width** (`app::event_loop::replay_scrollback`).
That sends every committed link on a round trip it had never made before —
markdown re-parsed, spans rebuilt, escapes re-emitted — and nothing in the repo
could see whether it came out the other side, because every reader here returns
text with the escapes already consumed. `vte_content_reflow.py` says so in its
own header: "'links still work after a resize' is NOT a claim this instrument
can make."

`osc8_reader.py` is the reader that can; this is the measurement.

THE DEFECT THIS FOUND
=====================
`Message::draw_agent` / `draw_agent_continuation` rendered the markdown body
through `Paragraph`. With no `.wrap()`, ratatui truncates through
`LineTruncator`, which measures a span with `unicode_width` — and that reports
width **1 for ESC**, so a short `https://` hyperlink costs about 45 phantom
columns. `render/cells.rs` exists precisely to stop this and was wired into the
tool-call path only; the markdown path, which is where `[text](url)`, bare-URL
autolinks and attachment chips are linkified, still went through `Paragraph`.

At 100 columns the graded reply happened to fit and looked fine. Narrowed to 70
it did not, and the replayed row came back sheared mid-URL::

    ┃Docs: the OSA guide (htt

with the rest of the sentence gone — permanently, since the row had already been
handed to the terminal's own scrollback. The fix routes both agent draw paths
through `render::cells::render_lines`.

WHAT IS ASSERTED, IN ORDER
==========================
1. **Before any resize** the link exists, is attached to its label's cells, and
   points at the intended URI. If this fails the instrument is wrong, and
   nothing below means anything.
2. **After one resize** the same holds, i.e. the purge-and-replay path
   reconstructed it.
3. **After a narrow -> widen -> narrow drag**, since the replay runs once per
   step and damage in this class is cumulative.
4. **The URI is correct** at every stage, not merely present. A link that
   survives pointing at the wrong target is worse than one that dies.
5. **The negative control**: a plain word in the same reply must carry no URI at
   any stage, and the link must be closed rather than left open. A reader that
   reports links everywhere fails here.

RUN
===
    python3 test/pty/osc8_reader.py        # prove the reader first
    python3 test/pty/osc8_resize_probe.py

Exit 0 = the link survived every stage with the right target.

PROVING IT CAN FAIL
===================
Revert either agent draw path to `Paragraph`::

    priv/rust/tui/src/components/chat/message.rs, in `draw_agent`
    -            let inner = block.inner(content_area);
    -            block.render(content_area, buf);
    -            crate::render::cells::render_lines(&styled_text.lines, inner, buf, body_scroll);
    +            Paragraph::new(styled_text).block(block).scroll((body_scroll, 0))
    +                .render(content_area, buf);

Rebuild and rerun. Expected: stage 1 passes at 100 columns and the narrowed
stages report `label truncated to 'the OSA guide (htt'`.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import osc8_reader  # noqa: E402
from osa_pty import PtySession  # noqa: E402
from stub_backend import StubBackend, push_sse, release_turn  # noqa: E402

STUB_PORT = 12797

# Wide enough that the graded row fits at the starting width even with the
# phantom columns, so stage 1 establishes a real baseline rather than passing by
# accident of a short line.
START_COLS = 100
ROWS = 30

LABEL = "the OSA guide"
URL = "https://osa.dev/guide/streaming"
BARE = "https://osa.dev/bare/autolinked"
# The negative control. Ordinary prose in the same reply, on the same rows the
# link is on, which must never acquire a URI.
PLAIN = "PLAINWORD"

REPLY = (
    f"Docs: [{LABEL}]({URL}) and {PLAIN} here.\n"
    "\n"
    f"Bare: {BARE} follows the same path.\n"
)


def turn(s: PtySession, prompt: str, reply: str, msg_id: str) -> None:
    """Drive one complete turn and let it commit into the transcript.

    Text and Enter are separate writes with a pump between them: sent as one
    burst OSA's paste-burst detector reads the whole thing as a paste, and a
    carriage return inside a paste is a newline, not a submit.
    """
    for ch in prompt:
        s.write(ch.encode())
        s.pump(0.02)
    s.pump(0.4)
    s.write(b"\r")
    s.pump(1.0)
    release_turn()
    push_sse(
        "agent_response",
        {"response": reply, "response_type": "text", "message_id": msg_id},
    )
    s.pump(2.5)


def links_of(screen: osc8_reader.LinkedScreen) -> list[tuple[str, str]]:
    """Every ``(uri, label)`` on screen plus every one that scrolled off."""
    return [(uri, text) for uri, text, _y, _x in screen.all_links()] + list(
        screen.scrolled
    )


def grade(screen: osc8_reader.LinkedScreen, feeder: osc8_reader.LinkFeeder,
          stage: str) -> list[str]:
    faults: list[str] = []
    found = links_of(screen)

    for want_uri, want_label in ((URL, LABEL), (BARE, BARE)):
        runs = [(u, t) for u, t in found if u == want_uri]
        if not runs:
            wrong = [(u, t) for u, t in found if want_label in t]
            if wrong:
                faults.append(
                    f"{stage}: {want_label!r} is linked to {wrong[0][0]!r}, "
                    f"expected {want_uri!r}"
                )
            else:
                faults.append(
                    f"{stage}: no link to {want_uri!r} anywhere; links present: {found!r}"
                )
            continue
        # Present — but is the LABEL intact? A sheared row keeps the escape and
        # loses the text, which is the defect this probe was written for.
        if not any(t.strip() == want_label for _u, t in runs):
            faults.append(
                f"{stage}: label truncated to {runs[0][1].strip()!r}, "
                f"expected {want_label!r}"
            )

    # Negative control: the plain word shares rows with the links and must be
    # unlinked. Its absence is also a fault — that is the row being sheared.
    plain_rows = [y for y in range(screen.lines) if PLAIN in screen.row_text(y)]
    if not plain_rows and not any(PLAIN in t for _u, t in found):
        faults.append(
            f"{stage}: the control word {PLAIN!r} is not on screen at all — "
            "the row carrying the link lost its tail"
        )
    for y in plain_rows:
        col = screen.row_text(y).index(PLAIN)
        for dx in range(len(PLAIN)):
            uri = screen.uri_at(y, col + dx)
            if uri is not None:
                faults.append(
                    f"{stage}: plain text at ({y},{col + dx}) reports a URI "
                    f"{uri!r} — the reader (or the link) is leaking"
                )
                break

    if feeder.unclosed():
        faults.append(
            f"{stage}: the stream ends inside an OPEN hyperlink — anything the "
            "terminal prints next becomes part of the link"
        )
    return faults


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument(
        "--drag",
        default="80,70,90,110,70",
        help="widths to resize through after the baseline (a drag, not a step)",
    )
    args = ap.parse_args()
    drag = [int(c) for c in args.drag.split(",") if c.strip()]

    faults: list[str] = []
    stages: list[tuple[str, list[tuple[str, str]]]] = []

    with StubBackend(STUB_PORT) as backend:
        with PtySession(
            backend.base_url,
            cols=START_COLS,
            rows=ROWS,
            binary=Path(args.binary) if args.binary else None,
            # `supports_hyperlinks` treats a PRESENT `NO_COLOR` as a hard
            # opt-out whatever its value, and the harness sets it to "" for
            # every other test here — so without unsetting it not one OSC 8
            # byte would ever be emitted and this probe would grade a blank.
            env={"NO_COLOR": None, "OSA_HYPERLINKS": "1"},
        ) as s:
            s.boot()

            # Stage 1 — baseline. Mark first so the replay sees the turn being
            # drawn at the starting width and nothing before it.
            mark = s.mark()
            turn(s, "link please", REPLY, "stub-msg-1")
            s.pump(1.0)
            screen, feeder = osc8_reader.replay(
                s.emitted_since(mark), START_COLS, ROWS
            )
            faults += grade(screen, feeder, f"baseline at {START_COLS}")
            stages.append((f"baseline {START_COLS}", links_of(screen)))

            # Stage 2 — one resize. Everything after this mark is the replay
            # path's own output, at the width it settled on.
            mark = s.mark()
            s.resize(drag[0], ROWS)
            s.pump(1.5)
            screen, feeder = osc8_reader.replay(s.emitted_since(mark), drag[0], ROWS)
            faults += grade(screen, feeder, f"after one resize to {drag[0]}")
            stages.append((f"one resize {drag[0]}", links_of(screen)))

            # Stage 3 — the rest of the drag, narrow -> widen -> narrow. The
            # replay runs once per step, so this is where cumulative damage
            # would show.
            for cols in drag[1:-1]:
                s.resize(cols, ROWS)
                s.pump(0.7)
            final = drag[-1]
            mark = s.mark()
            s.resize(final, ROWS)
            s.pump(2.0)
            screen, feeder = osc8_reader.replay(s.emitted_since(mark), final, ROWS)
            faults += grade(screen, feeder, f"after the full drag to {final}")
            stages.append((f"drag {'->'.join(map(str, drag))}", links_of(screen)))

            tail = s.lines()[-ROWS:]

    print(f"\n{'=' * 78}\nLINKED RUNS PER STAGE  (uri, label as it landed in cells)\n{'=' * 78}")
    for name, found in stages:
        print(f"  {name}:")
        for uri, text in found:
            print(f"      {text!r:<40} -> {uri}")
        if not found:
            print("      (none)")

    print(f"\n{'=' * 78}\nFINAL SCREEN\n{'=' * 78}")
    for line in tail:
        if line:
            print(f"  |{line}")

    print(f"\n{'=' * 78}\nVERDICT\n{'=' * 78}")
    if faults:
        for f in faults:
            print(f"  FAIL  {f}")
        return 1
    print("  PASS  the link survived the resize replay, kept its label, and")
    print("        still points at the URI it was rendered with")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
