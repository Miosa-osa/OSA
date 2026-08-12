"""Is the composer readable while a reply streams?

WHAT THIS MEASURES, AND WHY IT IS A SEPARATE PROBE
==================================================

Every other probe in this directory asks whether the screen is *correct*. This
one asks whether the app is *listening*, which is a different failure and was
invisible to all of them: a keystroke that is never read paints nothing wrong —
it paints nothing at all.

Two numbers, taken the same way in both states:

  * **echo latency** — wall time from writing one byte into the PTY to that
    character appearing on the composer row. Taken while idle (the control) and
    again mid-stream (the case).
  * **DSR per turn** — how many `ESC[6n` cursor queries the TUI emits during one
    streaming turn.

They are one measurement, not two. Ratatui anchors `Viewport::Inline` by asking
the terminal where the cursor is; the reply arrives on **stdin**, which the
terminal event reader also owns, so every inline rebuild used to abort the
reader task, run the query, and respawn it. A streaming preview that grows a row
at a time commits one rebuild per row. So the DSR count *is* the number of
windows in which the composer was deaf, and the echo latency is what that felt
like.

Baseline on this harness before the fix (real backend, ollama/llama3.2:3b):
26 DSR in a 5s turn, and 7 of 7 mid-stream keystrokes never echoed within 5s
each, against a ~3-4ms idle median.

USAGE
=====

    python3 test/pty/composer_latency_probe.py --url http://127.0.0.1:19281

Needs a REAL backend (this is a latency measurement, and a stub's timing is not
the timing under test) and the release binary:

    cd priv/rust/tui && cargo build --release

`--binary` points at a different build, which is how a before/after pair is
taken without rebuilding twice.
"""

from __future__ import annotations

import argparse
import os
import select
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from osa_pty import COMPOSER, COMPOSER_HINTS, PtySession  # noqa: E402

# The cursor-position query. Counting these in the raw stream is how the rebuild
# rate is observed from outside the process: two are emitted per rebuild (the
# caller's priming probe and ratatui's own construction), and they arrive in
# pairs under a millisecond apart.
DSR = b"\x1b[6n"

#: Characters typed one at a time to measure echo. Deliberately ordinary letters
#: — a key that triggers a binding would measure the binding, not the read.
ECHO_KEYS = "abcdefg"

#: How long to wait for a single character to appear before calling it lost.
#: The idle median is single-digit milliseconds, so five seconds is not a
#: threshold, it is a verdict.
ECHO_TIMEOUT = 5.0

#: When true, `ESC[6n` is deliberately left UNANSWERED.
#:
#: This is not a fault injection for its own sake — it is the owner's terminal.
#: All of this harness's other evidence is bare Linux, where a DSR reply comes
#: back in well under a millisecond and the reader is only deaf for that long.
#: Inside tmux (and over SSH) the query is passed through a multiplexer that
#: does not reliably answer it, and the code path that follows a dropped reply
#: is the one that hurts: a priming loop of up to 40 x 25 ms of BLOCKING sleep
#: on the event loop's own thread, with the terminal event reader aborted for
#: the duration. Every rebuild becomes a stall of up to a second in which no
#: keystroke is read at all.
#:
#: Dropping the reply here reproduces that without needing tmux, and it is a
#: fair model: a terminal that never answers is the limit of one that sometimes
#: doesn't. After the fix the inline rebuild emits no query, so there is nothing
#: left for a terminal to drop and the mode is a no-op.
DROP_DSR = False


def settle(session: PtySession, seconds: float) -> None:
    """Render for `seconds`, honouring [`DROP_DSR`].

    `PtySession.pump` always answers the cursor query, which is right for every
    other probe and wrong for this one's whole point.
    """
    pump_until(session, lambda _s: False, seconds)


def composer_text(session: PtySession) -> str:
    """Everything currently typed into the composer, as one string.

    Located as *the row directly above the composer's bottom divider*, on the
    visible screen only. That indirection is not fussiness — it is the
    difference between measuring the composer and measuring nothing:

    * `osa_pty.COMPOSER` (`^\\s*❯`) also matches the committed **user-message
      header** (`❯  You    8:28 AM`) that every submitted prompt leaves in
      scrollback, and `PtySession.lines()` includes scrollback. A first draft of
      this probe read that row and duly reported every mid-stream keystroke as
      lost while the app was in fact echoing all of them;
    * the live composer's own prompt glyph is preceded by a mode chip
      (`◈ ❯ …`), so it does not match that anchor at all.

    The bottom divider carries the key hints and belongs to exactly one band, so
    the row above it is the composer's text row and nothing else can be.
    """
    display = list(session.screen.display)
    for idx in range(len(display) - 1, 0, -1):
        if COMPOSER_HINTS.search(display[idx]):
            row = display[idx - 1]
            return row.split("❯", 1)[-1].strip() if "❯" in row else row.strip()
    # No hints row on screen (a dialog owns it): fall back to the prompt glyph.
    rows = [line for line in display if COMPOSER.search(line)]
    return rows[-1].split("❯", 1)[-1].strip() if rows else ""


def pump_until(session: PtySession, predicate, timeout: float) -> float | None:
    """Render output until `predicate(session)` holds. Returns elapsed seconds.

    A shortened `PtySession.pump` — the stock one always runs its full duration,
    which would quantise every latency to the poll interval and bury exactly the
    differences this probe exists to see.
    """
    start = time.perf_counter()
    deadline = start + timeout
    while True:
        if predicate(session):
            return time.perf_counter() - start
        remaining = deadline - time.perf_counter()
        if remaining <= 0:
            return None
        readable, _, _ = select.select([session.fd], [], [], min(0.002, remaining))
        if not readable:
            continue
        try:
            chunk = os.read(session.fd, 65536)
        except OSError:
            return None
        if not chunk:
            return None
        session.raw.extend(chunk)
        session.stream.feed(chunk.decode("utf-8", "replace"))
        if not DROP_DSR:
            for _ in range(chunk.count(DSR)):
                y = session.screen.cursor.y + 1
                x = session.screen.cursor.x + 1
                session.write(b"\x1b[%d;%dR" % (y, x))


def echo_latencies(session: PtySession, keys: str = ECHO_KEYS) -> list[float | None]:
    """Type `keys` one at a time; return each one's time-to-echo (None = lost).

    The expected composer text is tracked cumulatively so the predicate cannot
    be satisfied by a stale frame: character *n* is only counted once all *n*
    characters are on the row.
    """
    out: list[float | None] = []
    # Warm-up keystroke, not measured. An empty composer draws placeholder text
    # that the first real character replaces, so a baseline read before it would
    # never match again and score a phantom loss.
    session.write(b"z")
    settle(session, 0.4)
    base = composer_text(session)
    typed = ""
    for ch in keys:
        typed += ch
        want = base + typed
        session.write(ch.encode())
        elapsed = pump_until(
            # Substring, not suffix: the composer draws a block cursor after the
            # text, so a suffix test would race the cursor's blink and score a
            # phantom loss on a keystroke that in fact arrived.
            session, lambda s, w=want: w in composer_text(s), ECHO_TIMEOUT
        )
        out.append(elapsed)
        if elapsed is None:
            # Keep going. How MANY are lost is the finding; stopping at the
            # first would report a single anecdote.
            base = composer_text(session)
            typed = ""
    return out


def clear_composer(session: PtySession, count: int) -> None:
    for _ in range(count + 2):
        session.write(b"\x7f")
    settle(session, 0.4)


def summarise(name: str, samples: list[float | None]) -> dict:
    got = [s for s in samples if s is not None]
    lost = len(samples) - len(got)
    row = {
        "state": name,
        "n": len(samples),
        "lost": lost,
        "median_ms": None,
        "p95_ms": None,
        "worst_ms": None,
    }
    if got:
        got_ms = sorted(s * 1000 for s in got)
        row["median_ms"] = round(statistics.median(got_ms), 1)
        idx = min(len(got_ms) - 1, int(round(0.95 * (len(got_ms) - 1))))
        row["p95_ms"] = round(got_ms[idx], 1)
        row["worst_ms"] = round(got_ms[-1], 1)
    return row


def run(url: str, binary: Path | None, cols: int, rows: int, prompt: str) -> dict:
    result: dict = {"geometry": f"{cols}x{rows}", "rows": [], "dsr_per_turn": None}
    with PtySession(url, cols=cols, rows=rows, binary=binary) as session:
        session.boot()

        # -- control: the composer while nothing is happening ---------------
        idle = echo_latencies(session)
        result["rows"].append(summarise(f"idle {cols}x{rows}", idle))
        clear_composer(session, len(ECHO_KEYS) + 1)

        # -- case: the composer while a reply streams -----------------------
        mark = session.mark()
        session.write(prompt.encode())
        settle(session, 0.3)
        session.write(b"\r")

        # Wait for the stream to be genuinely under way — the preview has to be
        # GROWING for the defect to be live, so a couple of seconds of tokens is
        # the entry condition, not the first byte.
        turn_start = time.perf_counter()
        settle(session, 2.5)

        streaming = echo_latencies(session)
        result["rows"].append(summarise("mid-stream", streaming))

        # Let the turn finish so the DSR count covers a whole turn, then count.
        settle(session, 4.0)
        turn_elapsed = time.perf_counter() - turn_start
        emitted = session.emitted_since(mark)
        result["dsr_per_turn"] = emitted.count(DSR)
        result["turn_seconds"] = round(turn_elapsed, 1)
        result["dsr_per_second"] = round(result["dsr_per_turn"] / turn_elapsed, 2)
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:19281")
    ap.add_argument("--binary", type=Path, default=None)
    ap.add_argument("--geometry", default="100x30,200x50")
    ap.add_argument(
        "--prompt",
        default="Do not use any tools and do not write any files. In your reply "
        "only, print a 60 line bash script that backs up a directory, with a "
        "comment on every line.",
    )
    ap.add_argument(
        "--drop-dsr",
        action="store_true",
        help="never answer ESC[6n — models tmux/SSH, which is where the owner is",
    )
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    global DROP_DSR
    DROP_DSR = args.drop_dsr

    results = []
    for geom in args.geometry.split(","):
        cols, rows = (int(v) for v in geom.strip().split("x"))
        results.append(run(args.url, args.binary, cols, rows, args.prompt))

    if args.json:
        import json

        print(json.dumps(results, indent=2))

    for res in results:
        print(f"\n=== {res['geometry']} ===")
        print(f"{'state':<20} {'n':>3} {'lost':>5} {'median':>9} {'p95':>9} {'worst':>9}")
        for row in res["rows"]:
            def fmt(v):
                return "—" if v is None else f"{v} ms"
            print(
                f"{row['state']:<20} {row['n']:>3} {row['lost']:>5} "
                f"{fmt(row['median_ms']):>9} {fmt(row['p95_ms']):>9} "
                f"{fmt(row['worst_ms']):>9}"
            )
        print(
            f"DSR (ESC[6n) per turn: {res['dsr_per_turn']} "
            f"over {res['turn_seconds']}s = {res['dsr_per_second']}/s"
        )

    # ---- verdict ---------------------------------------------------------
    #
    # Two properties, both of which the pre-fix build violates and neither of
    # which is a timing threshold (thresholds on a shared machine are how a
    # probe becomes flaky):
    #
    #   * the inline live region rebuilds without asking the terminal where the
    #     cursor is, so a whole turn emits ZERO DSR. Not "few" — the rebuild
    #     paths all place the cursor themselves, so any query means one of them
    #     regressed to reading back a number it wrote;
    #   * no keystroke is lost. Under `--drop-dsr` this is the entire report:
    #     the pre-fix build loses every one of them.
    failures = []
    for res in results:
        if res["dsr_per_turn"] != 0:
            failures.append(
                f"{res['geometry']}: {res['dsr_per_turn']} cursor queries in one "
                f"turn — the inline rebuild is round-tripping again"
            )
        for row in res["rows"]:
            if row["lost"]:
                failures.append(
                    f"{res['geometry']}: {row['lost']}/{row['n']} keystrokes never "
                    f"echoed within {ECHO_TIMEOUT}s ({row['state']})"
                )

    print("\n" + "=" * 70)
    if failures:
        print("VERDICT: FAIL")
        for line in failures:
            print("  " + line)
        return 1
    print("VERDICT: PASS — no cursor queries in a turn, no keystroke lost")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
