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

# What the fixed backend sends at 159.3k on a 1M model.
PRESSURE = {
    "estimated_tokens": 159_300,
    "max_tokens": 1_048_576,
    "model_context_window": 1_048_576,
    "context_window_clamped": True,
    "utilization": 15.2,
    "context_percent": 15,
    "percent_left": 5,
    "context_low": True,
    "above_compact": False,
    "at_blocking_limit": False,
    "compact_at": 167_000,
    "warn_at": 147_000,
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

            emit("context_pressure", PRESSURE)
            term.pump(1.2)
            idle = term.dump()
            if opts.keep:
                print(idle)

            if "80% ctx" in idle or "79% ctx" in idle:
                problems.append("idle: the bar still reads the 200k budget (80%)")
            if "15% ctx" not in idle:
                problems.append("idle: the bar does not read 15% of the 1M window")
            if "Auto-compact at 167k" not in idle:
                problems.append("idle: the notice does not name the compaction point")
            if "% remaining" in idle:
                problems.append("idle: the notice is still a budget percentage")

            emit("processing_started", {})
            term.pump(0.4)
            emit("compaction_started", {"trigger": "auto", "tokens_before": 159_300})
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
    print("PASS: 1M window reads 15%, notice names 167k, hidden while compacting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
