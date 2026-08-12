"""Measure how *smoothly* streamed assistant text reaches the screen.

Against a REAL backend and a REAL provider — no stub. The owner's complaint is
that output "arrives in chunks and looks ugly", and the established cause is
upstream: the cloud endpoint flushes 4-6 tokens per TCP write, so one SSE delta
carries ~28 characters. Whether that shows on screen is decided by how many
characters a single *paint* reveals, and how far apart the paints that revealed
anything are.

So this probe measures the paint, not the token.

HOW A PAINT IS IDENTIFIED
=========================

OSA wraps every `terminal.draw` in the synchronized-update private mode pair
(`CSI ? 2026 h` … `CSI ? 2026 l`, `app/event_loop.rs`). That makes frame
boundaries unambiguous in the byte stream: a frame is everything from one
`?2026h` to the next. Each frame is fed to a `pyte` screen and the rendered
*body* text (everything that is not the bottom chrome) is remeasured. A frame
whose body grew is a **visible text update**; the growth is how many characters
that one paint revealed.

Reading the byte stream this way is what makes the numbers honest: it counts
what the terminal was actually told to show, at the moment it was told, rather
than when OSA received a delta.

WHAT IS REPORTED
================

* intervals between consecutive visible text updates — median, p90, and the
  share under 1 ms (the "clumping" number: two paints in the same millisecond
  are one visual event, not two);
* characters revealed per visible paint — median, p90, max;
* total latency from the first visible character to the last.

Smoothness is a distribution. A p90 that falls while the median holds is the
shape to want: the long stalls disappear, the base rate does not change.

USAGE
=====

    python3 test/pty/pace_probe.py --url http://127.0.0.1:19341 \
        --label before --model-note glm-5.2:cloud

Compare two runs with `--json out.json` and `--compare a.json b.json`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import select
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pyte  # noqa: E402
from osa_pty import PtySession  # noqa: E402

# Frame delimiter: BeginSynchronizedUpdate. OSA emits this immediately before
# every `terminal.draw` and the matching `?2026l` immediately after.
FRAME_START = b"\x1b[?2026h"

# Rows of bottom chrome to exclude from the "body" measurement. The composer,
# the hint row and the two status rows all repaint constantly (elapsed clock,
# spinner glyph) and would otherwise register as text updates. The streaming
# preview sits ABOVE them, so it is still measured.
DEFAULT_CHROME_ROWS = 6

# Rows that are chrome wherever they appear (the activity/working row carries a
# spinner and an elapsed counter and can float).
# Everything that is not a printable glyph, so a sampled frame reads as text.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b[]P][^\x07\x1b]*(\x07|\x1b\\)?|[\x00-\x08\x0b-\x1f\x7f]")

_CHROME_LINE = re.compile(
    r"(esc to interrupt|ctrl\+c|▌|╭|╰|│\s*$|^\s*[⠁-⣿]\s)|tokens?\b.*\bctx\b",
    re.IGNORECASE,
)


def body_split(screen: pyte.HistoryScreen, chrome_rows: int) -> tuple[int, int]:
    """(scrollback chars, live-screen body chars). Split so a settle — which
    MOVES text from the live region into scrollback — can be told apart from
    text genuinely appearing for the first time."""

    def count(rows):
        n = 0
        for line in rows:
            line = line.rstrip()
            if not line or _CHROME_LINE.search(line):
                continue
            n += len("".join(line.split()))
        return n

    hist = ["".join(c.data for _, c in sorted(r.items())) for r in screen.history.top]
    hist += ["".join(c.data for _, c in sorted(r.items())) for r in screen.history.bottom]
    disp = list(screen.display)
    if chrome_rows > 0:
        disp = disp[:-chrome_rows] if chrome_rows < len(disp) else []
    return count(hist), count(disp)


def body_len(screen: pyte.HistoryScreen, chrome_rows: int) -> int:
    """Printable characters currently visible as conversation body.

    History (scrolled-off rows, where settled blocks live) plus the live screen
    minus the bottom chrome. Whitespace is collapsed so a re-wrap that only
    moves padding around does not read as new text.
    """
    rows: list[str] = []
    for row in screen.history.top:
        rows.append("".join(cell.data for _, cell in sorted(row.items())))
    display = list(screen.display)
    if chrome_rows > 0:
        display = display[:-chrome_rows] if chrome_rows < len(display) else []
    rows.extend(display)
    for row in screen.history.bottom:
        rows.append("".join(cell.data for _, cell in sorted(row.items())))
    total = 0
    for line in rows:
        line = line.rstrip()
        if not line or _CHROME_LINE.search(line):
            continue
        total += len("".join(line.split()))
    return total


class FrameTimeline:
    """Splits a timestamped byte stream into frames and measures each one."""

    def __init__(self, cols: int, rows: int, chrome_rows: int) -> None:
        self.screen = pyte.HistoryScreen(cols, rows, history=8000)
        self.stream = pyte.Stream(self.screen)
        self.chrome_rows = chrome_rows
        # Paints bigger than this get their payload sampled (see `_close`).
        self.sample_over = 50
        self.samples: list[tuple[float, int, str]] = []
        # (t, growth, history chars, display-body chars) for big paints, so a
        # relocation (history up, display down, net zero) can be told apart from
        # a genuine reveal.
        self.split: list[tuple[float, int, int, int]] = []
        self.hist_len = 0
        self.disp_len = 0
        self.pending = bytearray()
        self.pending_t: float | None = None
        self.last_len = 0
        # (timestamp, chars_revealed) for every frame that grew the body.
        self.updates: list[tuple[float, int]] = []
        self.frames = 0

    def feed(self, t: float, chunk: bytes) -> None:
        self.pending.extend(chunk)
        if self.pending_t is None:
            self.pending_t = t
        # Cut on every frame start after the first byte of the buffer.
        while True:
            idx = self.pending.find(FRAME_START, 1)
            if idx < 0:
                break
            self._close(bytes(self.pending[:idx]), self.pending_t or t)
            del self.pending[:idx]
            self.pending_t = t

    def finish(self) -> None:
        if self.pending:
            self._close(bytes(self.pending), self.pending_t or time.monotonic())
            self.pending.clear()

    def _close(self, frame: bytes, t: float) -> None:
        self.frames += 1
        self.stream.feed(frame.decode("utf-8", "replace"))
        self.hist_len, self.disp_len = body_split(self.screen, self.chrome_rows)
        now_len = self.hist_len + self.disp_len
        if now_len > self.last_len:
            grew = now_len - self.last_len
            self.updates.append((t, grew))
            # Keep a sample of what the biggest single paints actually put on
            # screen. A distribution says how bad the flashes are; only the text
            # says WHICH mechanism produced them.
            if grew > self.sample_over:
                self.split.append((round(t, 3), grew, self.hist_len, self.disp_len))
                text = _ANSI.sub("", frame.decode("utf-8", "replace"))
                text = " ".join(text.split())
                self.samples.append((round(t, 3), grew, text[:160]))
        self.last_len = max(self.last_len, now_len)


def pct(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = min(len(s) - 1, max(0, int(round(q * (len(s) - 1)))))
    return s[k]


def summarize(tl: FrameTimeline) -> dict:
    ts = [t for t, _ in tl.updates]
    chars = [c for _, c in tl.updates]
    gaps = [(b - a) * 1000.0 for a, b in zip(ts, ts[1:])]
    return {
        "visible_updates": len(tl.updates),
        "frames_total": tl.frames,
        "chars_total": sum(chars),
        "gap_ms_p50": round(statistics.median(gaps), 2) if gaps else 0.0,
        "gap_ms_p90": round(pct(gaps, 0.90), 2),
        "gap_ms_max": round(max(gaps), 2) if gaps else 0.0,
        "gap_under_1ms_share": (
            round(sum(1 for g in gaps if g < 1.0) / len(gaps), 4) if gaps else 0.0
        ),
        "chars_per_paint_p50": statistics.median(chars) if chars else 0,
        "chars_per_paint_p90": pct(chars, 0.90),
        "chars_per_paint_max": max(chars) if chars else 0,
        "first_to_last_visible_ms": round((ts[-1] - ts[0]) * 1000.0, 1) if len(ts) > 1 else 0.0,
        # Raw samples, so several runs can be POOLED rather than averaged.
        # Averaging percentiles across short runs hides exactly the tail this
        # probe exists to measure.
        "gaps_ms": [round(g, 3) for g in gaps],
        "chars_per_paint": chars,
    }


IDLE_MARKERS = re.compile(r"esc to interrupt", re.IGNORECASE)


def run_turn(args) -> dict:
    env_home = os.environ.get("OSA_PTY_HOME")
    if env_home:
        os.environ["OSA_PTY_HOME"] = env_home
    binary = Path(args.binary) if args.binary else None
    with PtySession(args.url, cols=args.cols, rows=args.rows, binary=binary) as s:
        s.boot(timeout=args.boot_timeout)
        tl = FrameTimeline(args.cols, args.rows, args.chrome_rows)
        assert s.fd is not None

        def drain(budget: float) -> bool:
            """Read for `budget` seconds, feeding the timeline. True if any byte
            arrived. Every read is timestamped and answered for DSR here rather
            than in `PtySession.pump`, so no frame is consumed unmeasured."""
            end = time.monotonic() + budget
            got = False
            while True:
                remaining = end - time.monotonic()
                if remaining <= 0:
                    return got
                readable, _, _ = select.select([s.fd], [], [], min(0.02, remaining))
                if not readable:
                    continue
                now = time.monotonic()
                try:
                    chunk = os.read(s.fd, 65536)
                except OSError:
                    return got
                if not chunk:
                    return got
                got = True
                tl.feed(now, chunk)
                # The TUI blocks on cursor-position queries when it re-anchors
                # the inline viewport; a real terminal always answers.
                for _ in re.findall(rb"\x1b\[6n", chunk):
                    y = tl.screen.cursor.y + 1
                    x = tl.screen.cursor.x + 1
                    s.write(b"\x1b[%d;%dR" % (y, x))

        # Type character by character, exactly as `throughput_probe` does. A
        # single bulk write lands as one burst and the composer's paste path
        # handles it differently from real typing.
        for ch in args.prompt:
            s.write(ch.encode())
            drain(0.02)
        drain(0.4)
        s.write(b"\r")

        t_submit = time.monotonic()
        deadline = t_submit + args.timeout
        while time.monotonic() < deadline:
            drain(0.05)
            # The turn is over once nothing has *revealed text* for `quiet`
            # seconds. Keying this on bytes instead was wrong and cost an hour:
            # the TUI repaints on its 200 ms bookkeeping tick forever, so "no
            # output" never happens and every run sat until its hard timeout.
            if tl.updates and (time.monotonic() - tl.updates[-1][0]) > args.quiet:
                break
        tl.finish()

        # Only paints after submit are the turn's. Everything before (the
        # banner, the composer echo) shares the same screen so the baseline is
        # correct, but it is not what is being measured.
        tl.updates = [(t, c) for t, c in tl.updates if t >= t_submit]
        first_visible = tl.updates[0][0] if tl.updates else None

        out = summarize(tl)
        out["label"] = args.label
        out["model_note"] = args.model_note
        out["submit_to_first_visible_ms"] = (
            round((first_visible - t_submit) * 1000.0, 1) if first_visible else None
        )
        out["samples"] = tl.samples
        out["split"] = tl.split
        if args.dump:
            rows = [
                "".join(cell.data for _, cell in sorted(row.items()))
                for row in tl.screen.history.top
            ] + list(tl.screen.display)
            out["screen"] = "\n".join(line.rstrip() for line in rows[-args.dump_rows :])
        return out


def print_row(r: dict) -> None:
    print(
        f"  {r['label']:<10} {r['model_note']:<18} "
        f"updates={r['visible_updates']:<5} "
        f"gap p50={r['gap_ms_p50']:>7.2f}ms  p90={r['gap_ms_p90']:>7.2f}ms  "
        f"<1ms={r['gap_under_1ms_share'] * 100:>5.1f}%  "
        f"chars/paint p50={r['chars_per_paint_p50']:>4}  p90={r['chars_per_paint_p90']:>4}  "
        f"max={r['chars_per_paint_max']:>4}  "
        f"span={r['first_to_last_visible_ms'] / 1000:>6.1f}s  "
        f"ttfp={r['submit_to_first_visible_ms']}ms"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:19341")
    ap.add_argument("--binary", default=None)
    ap.add_argument("--cols", type=int, default=100)
    ap.add_argument("--rows", type=int, default=30)
    ap.add_argument("--chrome-rows", type=int, default=DEFAULT_CHROME_ROWS)
    ap.add_argument(
        "--prompt",
        default="Write four paragraphs about why terminals redraw. No lists, no code, no tools.",
    )
    ap.add_argument("--label", default="before")
    ap.add_argument("--model-note", default="")
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--quiet", type=float, default=6.0)
    ap.add_argument("--boot-timeout", type=float, default=30.0)
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--json", default=None)
    ap.add_argument("--dump", action="store_true")
    ap.add_argument("--dump-rows", type=int, default=40)
    args = ap.parse_args()

    runs = []
    for i in range(args.repeat):
        r = run_turn(args)
        runs.append(r)
        print_row(r)
        if args.dump and "screen" in r:
            print(r["screen"])
    if args.json:
        Path(args.json).write_text(json.dumps(runs, indent=2))
    return 0 if any(r["visible_updates"] > 0 for r in runs) else 1


if __name__ == "__main__":
    raise SystemExit(main())
