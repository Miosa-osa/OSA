#!/usr/bin/env python3
"""A width drag while the TRANSCRIPT is being committed, on a diagnosable PTY.

`vte_live_probe.py` reproduces stranded copies on real VTE once a transcript
exists, on the branch the existing VTE harness declares clean. VTE gives back
only flattened text, so this reruns the same gesture on the `pyte` PTY harness,
where the RAW BYTE STREAM is available and a stranded row can be attributed to
the sequence that deposited it.

pyte does not reflow, so this cannot reproduce a reflow-dependent strand. That
is the point of running both: whatever reproduces HERE is scroll-driven, not
reflow-driven, and scroll-driven strands are the ones `insert_before` and
`Backend::append_lines` produce.

Run: `python3 test/pty/transcript_resize_probe.py`
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from duplicate_probe import PreludeSession  # noqa: E402
from osa_pty import SETTLE, SINGLETON_BANDS  # noqa: E402
from stub_backend import StubBackend  # noqa: E402

STUB_PORT = 12797

# Every sequence that can move content into scrollback or re-anchor the region.
SEQS = {
    "ED0 (erase fwd, in place)": re.compile(rb"\x1b\[0?J"),
    "ED2 (VTE scrolls this!)": re.compile(rb"\x1b\[2J"),
    "ED3 (purge history)": re.compile(rb"\x1b\[3J"),
    "DSR cursor query": re.compile(rb"\x1b\[6n"),
    "alt screen enter": re.compile(rb"\x1b\[\?1049h"),
    "alt screen leave": re.compile(rb"\x1b\[\?1049l"),
}


def counts(s):
    return {n: s.count(p) for n, p in SINGLETON_BANDS.items()}


def newline_runs(raw: bytes) -> int:
    """How many bare `\\n` the child emitted.

    `Backend::append_lines` — the scroll primitive behind BOTH
    `Terminal::insert_before` and every `Viewport::Inline` (re)construction —
    is implemented as exactly this. A newline at the bottom row scrolls the
    screen, and a scrolled row is in history where no erase can reach it. So
    this is the count that matters for stranding, and it is invisible to any
    Buffer-level assertion.
    """
    return raw.count(b"\n")


def describe(label: str, s, raw: bytes) -> None:
    c = counts(s)
    bad = {k: v for k, v in c.items() if v > 1}
    print(f"  [{'DUPLICATED' if bad else 'ok':10}] {label}: {c}")
    found = {n: len(p.findall(raw)) for n, p in SEQS.items()}
    found["bare newlines (append_lines)"] = newline_runs(raw)
    print(f"      emitted: { {k: v for k, v in found.items() if v} }")
    return bad


def main() -> int:
    failures = []
    with StubBackend(STUB_PORT) as backend:
        with PreludeSession(backend.base_url, cols=120, rows=40) as s:
            s.boot()
            s.pump(SETTLE * 2)
            m = s.mark()
            describe("booted", s, s.emitted_since(m))

            # Six rapid submits, exactly as vte_live_probe.py does. The stub
            # never answers, so OSA stays in Processing and the later submits
            # pile into a growing composer — which is itself a height change
            # per keystroke on top of the transcript commit.
            m = s.mark()
            for i in range(6):
                s.write(
                    f"probe message {i:02d} ".encode()
                    + b"padding words that make this line wrap at any width under test " * 2
                    + b"\r"
                )
                s.pump(0.5)
            s.pump(SETTLE * 2)
            describe("after 6 rapid submits", s, s.emitted_since(m))

            m = s.mark()
            for cols in (115, 110, 105, 100, 95, 90, 95, 100, 105, 110, 115, 120):
                s.resize(cols, 40)
                s.pump(0.4)
            s.pump(SETTLE * 3)
            bad = describe("after width drag with transcript", s, s.emitted_since(m))
            if bad:
                failures.append(f"width drag: {bad}")
                print("\n--- full rendered screen + history (tail 60) ---")
                for line in s.dump().splitlines()[-60:]:
                    print("   " + line)

    print("\n=== summary ===")
    for f in failures:
        print(f"FAIL: {f}")
    if not failures:
        print("no duplication on pyte — the VTE strand is reflow-dependent, not scroll-driven")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
