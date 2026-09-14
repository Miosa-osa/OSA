"""Hunt the streaming paint corruption from the owner's screenshot.

THE DEFECT BEING HUNTED
=======================

A real session rendered, verbatim:

    Build's1greene— 976rmodules,xclean typecheck.

against an intended `Build's green — 976 modules, clean typecheck.` Aligning
the two shows SINGLE CHARACTERS SUBSTITUTED FOR SPACES at text columns 7, 13,
19 and 28 — `1`, `e`, `r`, `x`. Not escape parameters left in place (that was a
different, already-fixed defect in `render/sanitize.rs`); not truncation.

A space is precisely the cell that fails to overwrite when a writer only emits
the cells it believes changed. So the shape of the corruption names its own
mechanism: SOMETHING PAINTED A ROW WITHOUT EMITTING ITS BLANK CELLS, over a row
that still held older glyphs. `blank_rows_probe.py` drives one clean turn and
cannot see this, because a clean turn never puts two writers on one row.

WHAT THIS PROBE DOES DIFFERENTLY
================================

It recreates the conditions of the frame that broke, which `blank_rows_probe`
does not have:

  * a LONG streamed assistant message (the preview slot grows and shrinks
    repeatedly, which is what drives OSA's manual scroll/clear path in
    `app/event_loop.rs`);
  * a tool cell LIVE ABOVE it at the same time — the screenshot showed the
    composer's `tsc -b && vite build` interleaved with the Bash output block,
    so the tool had not finished when the message streamed;
  * ANSI-coloured build output on the tool;
  * a narrow-ish terminal, and (in the stress variant) resizes mid-stream.

And it samples CONTINUOUSLY rather than at two settle points: overpaint is
transient by nature — the next full repaint erases the evidence. Every
intermediate screen is checked.

THE CHECKS
==========

1. **Space substitution.** Each sentinel sentence is unique, fits one row at the
   probe width, and is rich in interior spaces. On every sampled frame, any row
   carrying a sentinel anchor must be a contiguous whole-word slice of the
   streamed reply. A space that failed to overwrite glues two words into one
   token, which can never be a slice, and the row is reported byte for byte.
2. **Transcript bleeding into the composer band.** Nothing from the
   conversation may appear at or below the composer's top divider.
3. **Escape remnants** printed as text.
4. **Duplicated live region** (more than one composer on screen).
4b. **Every viewport rebuild lands inside the span that was just erased**,
   checked from the emitted escape sequences (CUP/ED/DSR) rather than from the
   rendering. `rebuild_inline` installs a `Terminal` whose buffers are all
   spaces and which never clears the screen, so its first draw emits only
   non-space cells; a rebuild anchored above the erase leaves rows nothing will
   repaint. The hole exists whether or not stale glyphs happen to sit under a
   blank, so asserting on the emission is strictly stronger than waiting for
   the corruption to become visible.
5. **Raw markdown on screen.** A second turn streams markdown whose bold run,
   link and inline code are all long enough that the renderer must wrap INSIDE
   them at the probe width. `render/markdown.rs` used to wrap the raw source and
   only then parse each half for inline markup, so the wrap left `**` and
   `label](https://…)` visible. Measured before the fix at `--cols 62`:
   three such rows; after: none.

STATUS OF THE HUNT
==================

Checks 1-4 have NOT reproduced the screenshot's corruption in any configuration
tried here (plain, `--stress`, `--stress --surgical`, widths 62/100, heights
15/21/24/30, ~90 sampled frames each). They are kept as a standing gate. Check 5
found and now guards a real, separate rendering defect.

Exits non-zero on any of the five.

Run:  python3 test/pty/stream_paint_probe.py [--binary PATH] [--stress]
                                             [--surgical] [--cols N] [--rows N]
"""

from __future__ import annotations

import argparse
import json
import queue
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from osa_pty import COMPOSER_HINTS, PtySession  # noqa: E402

PORT = 19137

_HEALTH = {
    "status": "ok",
    "version": "0.0.0-pty-stream-paint",
    "uptime_seconds": 0,
    "provider": "pty-stub",
    "model": "pty-stub",
    "context_window": 200000,
    "effort": "medium",
    "billing": None,
    "update": None,
}

GREEN = "\x1b[32m"
RESET = "\x1b[0m"
BOLD = "\x1b[1m"
OSC8_ON = "\x1b]8;;http://localhost:5173\x1b\\"
OSC8_OFF = "\x1b]8;;\x1b\\"

BUILD_OUTPUT = [
    f"{BOLD}vite v5.4.10{RESET} building for production...",
    "transforming...",
    f"{GREEN}✓{RESET} 976 modules transformed.",
    f"dist/index.html  {GREEN}0.46 kB{RESET}",
    f"dist/assets/index-4f2c.css  {GREEN}12.10 kB{RESET}",
    f"dist/assets/index-9e1b.js  {GREEN}184.22 kB{RESET}",
    f"{GREEN}✓ built in 3.41s{RESET}",
    f"preview at {OSC8_ON}http://localhost:5173{OSC8_OFF}",
]

# The screenshot's line, character for character, plus companions that are long
# enough to make the preview slot grow and shrink while the tool is still live.
# Every one of them is one row at 100 columns and carries interior spaces at
# many different offsets, which is what makes a non-overwriting blank visible.
SENTINELS = [
    "Build's green — 976 modules, clean typecheck.",
    "Ran the typecheck first, then the production bundle, in that order.",
    "No errors, no warnings, and the bundle came in under the budget.",
    "Every module resolved, every import checked, nothing left dangling.",
]

# Anchors decide "this row is meant to be reply text". Each must survive the
# corruption being hunted, so each is a run with NO interior space, and each is
# unique within the reply so one anchor never claims another sentence's row, and
# none of them occurs in the tool's build output (which is not reply text).
ANCHORS = ["Build's", "typecheck.", "warnings,", "dangling."]

LONG_REPLY = " ".join(SENTINELS)
REPLY_WORDS = LONG_REPLY.split()

# A second turn, streamed as markdown. Every construct here is long enough that
# the renderer MUST wrap inside it at the probe width — which is exactly the
# case `render/markdown.rs` used to get wrong, because it wrapped the RAW
# markdown and only then parsed each half for inline markup. A wrap landing
# inside `**…**` left the asterisks on screen; a wrap inside a link label left
# `label](https://…)` verbatim with no link emitted.
MD_REPLY = (
    "The regression was **entirely confined to the incremental typecheck "
    "cache**, which is why a clean build never reproduced it. "
    "See [the upstream issue thread about incremental caches]"
    "(https://example.com/issues/4712) for the full history, and note that "
    "`tsc --build --force --verbose` is the only invocation that bypasses it.\n"
)


class _Bus:
    def __init__(self) -> None:
        self.q: "queue.Queue[tuple[str, dict]]" = queue.Queue()

    def send(self, event: str, data: dict) -> None:
        self.q.put((event, data))

    def script_markdown(self) -> None:
        """A second turn whose reply is markdown that must wrap mid-construct."""

        def run() -> None:
            time.sleep(0.3)
            for chunk in re.findall(r"\S+\s*", MD_REPLY):
                self.send(
                    "streaming_token",
                    {"text": chunk, "session_id": "s", "message_id": "m2"},
                )
                time.sleep(0.04)
            self.send(
                "agent_response",
                {
                    "response": MD_REPLY,
                    "response_type": "text",
                    "signal": None,
                    "message_id": "m2",
                },
            )

        threading.Thread(target=run, daemon=True).start()

    def script(self) -> None:
        """One turn: a tool streams coloured output WHILE a long reply streams."""

        def run() -> None:
            time.sleep(0.4)
            # ── a shell tool starts and stays live for the whole turn ──
            self.send(
                "tool_call",
                {
                    "name": "shell_execute",
                    "phase": "start",
                    "args": json.dumps({"command": "tsc -b && vite build"}),
                    "tool_call_id": "call-1",
                },
            )
            for i, line in enumerate(BUILD_OUTPUT[:4]):
                self.send(
                    "command_output_delta",
                    {
                        "command": "tsc -b && vite build",
                        "chunk": line + "\n",
                        "tail": line,
                        "seq": i,
                        "tool_call_id": "call-1",
                    },
                )
                time.sleep(0.08)

            # ── the long reply streams while that tool cell is still live ──
            # Token-sized deltas, no artificial pause between most of them: the
            # point is to make the preview grow a row at a time under a fast
            # arrival rate, which is when the height-change path fires.
            chunks = re.findall(r"\S+\s*", LONG_REPLY)
            for n, chunk in enumerate(chunks):
                self.send(
                    "streaming_token",
                    {"text": chunk, "session_id": "s", "message_id": "m1"},
                )
                # Interleave the rest of the tool's output into the same window,
                # so two live regions are repainting from the same frames.
                if n == 6 or n == 14:
                    idx = 4 if n == 6 else 5
                    self.send(
                        "command_output_delta",
                        {
                            "command": "tsc -b && vite build",
                            "chunk": BUILD_OUTPUT[idx] + "\n",
                            "tail": BUILD_OUTPUT[idx],
                            "seq": idx,
                            "tool_call_id": "call-1",
                        },
                    )
                time.sleep(0.09)

            self.send(
                "agent_response",
                {
                    "response": LONG_REPLY,
                    "response_type": "text",
                    "signal": None,
                    "message_id": "m1",
                },
            )
            time.sleep(0.3)
            self.send(
                "tool_result",
                {
                    "name": "shell_execute",
                    "result": "\n".join(BUILD_OUTPUT),
                    "success": True,
                    "tool_call_id": "call-1",
                },
            )
            self.send(
                "tool_call",
                {
                    "name": "shell_execute",
                    "phase": "end",
                    "duration_ms": 3400,
                    "success": True,
                    "tool_call_id": "call-1",
                },
            )

        threading.Thread(target=run, daemon=True).start()


BUS = _Bus()
TURN = {"n": 0}


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_a):
        pass

    def _json(self, payload, status: int = 200) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            self.wfile.write(b'event: connected\ndata: {"session_id":"s"}\n\n')
            self.wfile.flush()
            while True:
                try:
                    ev, data = BUS.q.get(timeout=1.0)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    continue
                blob = json.dumps(data).encode()
                self.wfile.write(b"event: " + ev.encode() + b"\ndata: " + blob + b"\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            return self._json(_HEALTH)
        if path == "/onboarding/status":
            return self._json({"needs_onboarding": False, "providers": []})
        if path.startswith("/api/v1/stream/"):
            return self._sse()
        if path == "/api/v1/commands":
            return self._json({"commands": []})
        if path == "/api/v1/tools":
            return self._json({"tools": []})
        if path in ("/api/v1/sessions", "/api/v1/sessions/recent"):
            return self._json({"sessions": []})
        if path == "/api/v1/permission-rules":
            return self._json({"rules": []})
        return self._json({})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if path in ("/api/v1/auth/login", "/api/v1/auth/refresh"):
            return self._json({"token": "t", "refresh_token": "r", "expires_in": 3600})
        if path == "/api/v1/sessions":
            return self._json({"session_id": "s", "id": "s"})
        if path == "/api/v1/orchestrate":
            if TURN["n"] == 0:
                BUS.script()
            else:
                BUS.script_markdown()
            TURN["n"] += 1
            return self._json({"session_id": "s", "status": "accepted"})
        return self._json({})


def type_and_submit(s: PtySession, text: str) -> None:
    for ch in text:
        s.write(ch.encode())
        s.pump(0.02)
    s.pump(0.35)
    s.write(b"\r")


# --- the checks -----------------------------------------------------------


def check_sentinels(rows: list[str], label: str) -> list[str]:
    """Any row claiming to be a sentinel must BE that sentinel, verbatim.

    This is the corruption gate. A blank cell that failed to overwrite leaves a
    foreign glyph where a space belongs, so the anchor still matches while the
    sentence no longer does.
    """
    bad = []
    for y, row in enumerate(rows):
        if not any(a in row for a in ANCHORS):
            continue
        # Strip the gutter/quote decoration and the streaming cursor, then
        # require what is left to be a contiguous whole-word slice of the reply.
        # A substituted space glues two words into one token, which can never be
        # a slice — that is the whole detector.
        frag = row.strip().strip("┃│▌█⏎… ").strip()
        if _is_word_run(frag):
            continue
        bad.append(f"{label}: row {y} is not reply text: {row!r}")
    return bad


def _is_word_run(frag: str) -> bool:
    """True if `frag` is a contiguous whole-word slice of the streamed reply.

    The final token is allowed to be a PREFIX of its expected word: the live
    preview can be clipped at the right edge mid-word.
    """
    fw = frag.split()
    if not fw:
        return True
    n = len(fw)
    for i in range(len(REPLY_WORDS) - n + 1):
        window = REPLY_WORDS[i : i + n]
        if window[:-1] == fw[:-1] and window[-1].startswith(fw[-1]):
            return True
    return False


# Words that belong to the TRANSCRIPT (reply prose and tool output) and to
# nothing the composer band ever draws. Finding one below the composer's top
# divider means a transcript row survived under a freshly-rebuilt live region:
# a new ratatui `Terminal` starts with all-space buffers, so its first draw
# emits only non-space cells and whatever the screen still held shows through
# at exactly the blank positions. That is the corruption's shape.
BLEED_VOCAB = [
    "modules",
    "typecheck",
    "bundle",
    "dangling",
    "vite",
    "transforming",
    "dist/",
    "Bash(",
    "verify the build",
]

DIVIDER = re.compile(r"^─{20,}$")


def check_region_bleed(rows: list[str], label: str) -> list[str]:
    """No transcript text may appear at or below the composer's top divider.

    The composer band draws a divider, a prompt line, a hint line and the status
    line — none of which contain any transcript vocabulary. Anything from the
    conversation appearing there did not come from this frame's render.
    """
    top = None
    for y, row in enumerate(rows):
        if DIVIDER.match(row.strip()):
            top = y
            break
    if top is None:
        return []
    bad = []
    for y in range(top, len(rows)):
        row = rows[y]
        for word in BLEED_VOCAB:
            if word in row:
                bad.append(
                    f"{label}: transcript text {word!r} bled into the composer "
                    f"band at row {y}: {row!r}"
                )
                break
    return bad


# Raw markup that must NEVER reach the screen. Each is what a wrap landing
# inside an inline construct used to leave behind.
RAW_MARKUP = ["**", "](", "](h", "`tsc"]


def check_raw_markup(rows: list[str], label: str) -> list[str]:
    """No markdown source markers may be visible in rendered prose."""
    bad = []
    for y, row in enumerate(rows):
        for pat in RAW_MARKUP:
            if pat in row:
                bad.append(
                    f"{label}: raw markdown {pat!r} rendered as text on row "
                    f"{y}: {row!r}"
                )
                break
    return bad


# --- the emission-level invariant -----------------------------------------
#
# CUP  — `ESC[<row>;<col>H` (bare `ESC[H` means 1;1). 1-based.
# ED   — `ESC[J` / `ESC[0J` erase from the cursor DOWN; `ESC[2J` / `ESC[3J`
#        take the whole screen.
# DSR  — `ESC[6n`. Ratatui's `Viewport::Inline` construction is the only thing
#        that asks where the cursor is, so a DSR marks a VIEWPORT REBUILD and
#        the cursor row at that moment is the row the rebuilt region anchors to.
_CUP = re.compile(rb"\x1b\[(?:(\d*)(?:;(\d*))?)?H")
_ED = re.compile(rb"\x1b\[([0-3]?)J")
_DSR = re.compile(rb"\x1b\[6n")
_ANY = re.compile(rb"\x1b\[(?:(?:\d*)(?:;\d*)?H|[0-3]?J|6n)")


def check_clear_covers_rebuild(raw: bytes, label: str) -> list[str]:
    """Every viewport rebuild must land inside the span that was just erased.

    `rebuild_inline` installs a fresh `Terminal::with_options`, whose buffers are
    `Buffer::empty` — cells of `" "` with the default style — and which never
    clears the screen itself. Its first draw therefore diffs against all-spaces
    and emits ONLY non-space cells, so any row under the new region that nobody
    erased keeps its old glyphs at exactly the blank positions.

    This is checked from the emitted bytes rather than from the rendering,
    because the bleed is only VISIBLE when the stale glyphs happen to sit under
    a blank — the hole is there whether or not it shows. Deterministic, and it
    does not require manufacturing the visible corruption.
    """
    bad = []
    cursor_row = 0  # 0-based
    erase_top: int | None = None
    for m in _ANY.finditer(raw):
        seq = m.group(0)
        if seq.endswith(b"H"):
            g = _CUP.match(seq)
            row = g.group(1) if g else b""
            cursor_row = (int(row) - 1) if row else 0
        elif seq.endswith(b"J"):
            g = _ED.match(seq)
            kind = (g.group(1) or b"0") if g else b"0"
            if kind in (b"0",):
                erase_top = cursor_row
            elif kind in (b"2", b"3"):
                erase_top = 0
            # ED1 (erase to cursor) clears nothing below, so it cannot cover a
            # region that starts at or after the cursor.
        else:  # DSR — a viewport rebuild is anchoring here
            if erase_top is not None and erase_top > cursor_row:
                bad.append(
                    f"{label}: viewport rebuilt at row {cursor_row} but the "
                    f"preceding erase started at row {erase_top} — rows "
                    f"{cursor_row}..{erase_top - 1} were never cleared, and a "
                    f"fresh all-space buffer will not repaint them"
                )
            erase_top = None
    # Collapse duplicates: one rebuild emits a burst of identical probes.
    return list(dict.fromkeys(bad))


def check_escape_leakage(rows: list[str], label: str) -> list[str]:
    bad = []
    for y, row in enumerate(rows):
        if "\x1b" in row:
            bad.append(f"{label}: raw ESC on row {y}: {row!r}")
        for pat in ("[0m", "[1m", "[32m", "]8;;", "]0;"):
            if pat in row:
                bad.append(f"{label}: escape remnant {pat!r} as text, row {y}: {row!r}")
    return bad


def check_single_composer(s: PtySession, label: str) -> list[str]:
    n = sum(1 for line in s.screen.display if COMPOSER_HINTS.search(line))
    if n > 1:
        return [f"{label}: {n} composers on screen at once"]
    return []


def snapshot(s: PtySession) -> list[str]:
    return [s.screen.display[y].rstrip() for y in range(s.rows)]


def dump(rows: list[str], label: str) -> None:
    print(f"\n{'=' * 78}\n{label}\n{'=' * 78}")
    for y, row in enumerate(rows):
        print(f"{y:>3} |{row}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument("--cols", type=int, default=100)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument(
        "--stress",
        action="store_true",
        help="resize mid-stream, which exercises OSA's manual scroll/clear path",
    )
    ap.add_argument(
        "--surgical",
        action="store_true",
        help=(
            "force OSA_RESIZE_CLEAR=surgical, the strategy every multiplexer "
            "gets by default (tmux, screen). The non-multiplexer default wipes "
            "the whole screen on resize, which hides this class of defect."
        ),
    )
    ap.add_argument("--dump-all", action="store_true")
    ap.add_argument("--shrink", type=int, default=3)
    ap.add_argument("--frames", type=int, default=90)
    args = ap.parse_args()

    if args.surgical:
        import os

        os.environ["OSA_RESIZE_CLEAR"] = "surgical"

    srv = ThreadingHTTPServer(("127.0.0.1", PORT), _Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    failures: list[str] = []
    worst: list[str] | None = None

    with PtySession(
        f"http://127.0.0.1:{PORT}",
        cols=args.cols,
        rows=args.rows,
        binary=Path(args.binary) if args.binary else None,
    ) as s:
        s.boot()
        type_and_submit(s, "verify the build")

        # Sample CONTINUOUSLY. Overpaint is transient: the frame after it is
        # usually clean, so a two-point probe cannot see it.
        for frame in range(args.frames):
            s.pump(0.1)
            if args.stress and 4 <= frame <= 26:
                # A resize is what forces the region to be re-anchored and
                # re-cleared, which is the path that can leave a row half-owned.
                # Both axes: a HEIGHT change moves the bottom-anchored region to
                # a different row than the surgical clear's remembered top, and
                # that gap is uncleared screen the rebuilt viewport paints over.
                narrow = frame % 2 == 0
                short = args.shrink > 0 and frame % 4 == 2
                s.resize(
                    args.cols - (7 if narrow else 0),
                    args.rows - (args.shrink if short else 0),
                )
                s.pump(0.12)
            rows = snapshot(s)
            if args.dump_all:
                dump(rows, f"FRAME {frame}")
            found = (
                check_sentinels(rows, f"frame {frame}")
                + check_region_bleed(rows, f"frame {frame}")
                + check_escape_leakage(rows, f"frame {frame}")
                + check_single_composer(s, f"frame {frame}")
            )
            if found and worst is None:
                worst = rows
            failures += found

        s.pump(2.0)
        end = snapshot(s)
        dump(end, "AFTER THE TURN SETTLES")
        failures += check_sentinels(end, "settled")
        failures += check_region_bleed(end, "settled")
        failures += check_escape_leakage(end, "settled")
        if any(row.count("http://localhost:5173") > 1 for row in end):
            failures.append("settled: tool hyperlink target was printed twice")

        # ── second turn: markdown that must wrap inside its own constructs ──
        type_and_submit(s, "why did it regress")
        for frame in range(40):
            s.pump(0.1)
            md = snapshot(s)
            if args.dump_all:
                dump(md, f"MD FRAME {frame}")
            failures += check_raw_markup(md, f"md frame {frame}")
        s.pump(1.5)
        md_end = snapshot(s)
        dump(md_end, "MARKDOWN TURN, SETTLED")
        failures += check_raw_markup(md_end, "markdown settled")

        # The emission-level gate, over everything the child wrote all run.
        failures += check_clear_covers_rebuild(bytes(s.raw), "emission")

        if worst is not None:
            dump(worst, "FIRST CORRUPTED FRAME")

        print("\n===== FULL HISTORY (scrolled-off + visible) =====")
        print(s.dump())

    srv.shutdown()

    if TURN["n"] < 2:
        failures.append(f"coverage: expected two submitted turns, observed {TURN['n']}")

    print(f"\n{'=' * 78}\nVERDICT\n{'=' * 78}")
    if failures:
        seen = set()
        for f in failures:
            if f.split(":", 1)[1] in seen:
                continue
            seen.add(f.split(":", 1)[1])
            print(f"  FAIL  {f}")
        return 1
    print(f"  PASS  {args.frames} sampled frames, no corrupted row")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
