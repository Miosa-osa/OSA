"""Visual proof that a 1M-window model is not reported as nearly full.

Drives the REAL `osagent` binary over a real PTY and replays the frames the
backend sends for the reported session: `deepseek-v4.1-flash:cloud`
(1,048,576-token window) at 159.3k tokens, inside the auto-compact band.

The reported screen was:

    Context low (4% remaining) · Run /compact to compact & continue
    ⟐ deepseek-v4.1-flash:cloud │ ⣿⣿⣿⣿⣿⣿⢿░ 80% ctx

Both numbers were shares of the 200k compaction budget. This probe asserts the
bar reads the real window, the notice names the compaction point in tokens,
and the notice gets out of the way while a compaction is already running.

Usage:
    python3 test/pty/context_window_probe.py [--port N] [--keep]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import compaction_probe  # noqa: E402
import stub_backend  # noqa: E402
from osa_pty import PtySession  # noqa: E402

emit = compaction_probe.emit

# What the backend sends on a 1,048,576-token model.
WINDOW = 1_048_576
COMPACT_AT = 891_289
WARN_AT = 871_289


def pressure(tokens: int) -> dict:
    return {
        "estimated_tokens": tokens,
        "max_tokens": WINDOW,
        "model_context_window": WINDOW,
        "context_window_clamped": False,
        "utilization": round(tokens / WINDOW * 100, 1),
        "context_percent": round(tokens / WINDOW * 100),
        "percent_left": max(0, round((COMPACT_AT - tokens) / COMPACT_AT * 100)),
        "context_low": tokens >= WARN_AT,
        "above_compact": tokens >= COMPACT_AT,
        "at_blocking_limit": False,
        "compact_at": COMPACT_AT,
        "warn_at": WARN_AT,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=12934)
    ap.add_argument("--keep", action="store_true", help="print every screen")
    opts = ap.parse_args()

    stub_backend._Handler._sse = compaction_probe._sse_with_events
    problems: list[str] = []

    with stub_backend.StubBackend(opts.port) as stub:
        with PtySession(stub.base_url, cols=110, rows=24) as term:
            term.boot()

            # The reported session: 159.3k of a 1M window.
            emit("context_pressure", pressure(159_300))
            term.pump(1.2)
            early = term.dump()
            if opts.keep:
                print(early)

            if "80% ctx" in early or "79% ctx" in early:
                problems.append("159.3k: the bar reads a 200k budget (80%)")
            if "15% ctx" not in early:
                problems.append("159.3k: the bar does not read 15% of the 1M window")
            if "/compact" in early or "Context low" in early:
                problems.append("159.3k: a low-context notice is up at 15% of the window")

            # Just below the fold point: the notice appears, in tokens.
            emit("context_pressure", pressure(880_000))
            term.pump(1.2)
            idle = term.dump()
            if opts.keep:
                print(idle)

            if "84% ctx" not in idle:
                problems.append("880k: the bar does not read 84% of the 1M window")
            if "Auto-compact at 891k" not in idle:
                problems.append("880k: the notice does not name the compaction point")
            if "% remaining" in idle:
                problems.append("880k: the notice is still a budget percentage")

            emit("processing_started", {})
            term.pump(0.4)
            emit("compaction_started", {"trigger": "auto", "tokens_before": 880_000})
            emit("compaction_progress", {"chunk_index": 12, "chunk_total": 24})
            term.pump(1.2)
            running = term.dump()
            if opts.keep:
                print(running)

            if "Compacting" not in running:
                problems.append("running: precondition, the spinner never said Compacting")
            if "/compact" in running:
                problems.append("running: the notice still says to run /compact during compaction")

    if problems:
        print("FAIL")
        for p in problems:
            print("  -", p)
        return 1
    print("PASS: 1M window reads 15% at 159.3k, notice names 891k near the fold, hidden while compacting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
