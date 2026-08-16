#!/usr/bin/env python3
"""Regression tests for `scripts/tool_call_shape.py`.

Every number in `docs/research/tool-call-shape.md` depends on four things being
right, and each of them has a plausible wrong answer that would look fine:

  1. `tool_call` is emitted twice per call (`phase` start/end) and
     `llm_response` twice per model response. Counting events instead of calls
     doubles everything, and doubling BOTH the numerator and the turn count
     still corrupts the batch-size distribution.
  2. A run that predates `args_hash` must be dropped WHOLE. Counting it
     partially deflates every repeat rate, which is how a real effect gets
     explained away.
  3. Keying a duplicate on the RESULT payload counts distinct calls that share
     a constant success string. That is the entire difference between the
     published 9.4% and the honest 4.25%, so the two must not converge.
  4. `tool_call.args` is a 60-char display hint. It may be read for content
     only when `args_bytes` proves it complete -- three findings have been
     retracted for ignoring this.

Run standalone:  python3 scripts/test_tool_call_shape.py
Or under pytest: pytest scripts/test_tool_call_shape.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import tool_call_shape as tcs  # noqa: E402


# --------------------------------------------------------------------------
def _write(tmp, run, task, events):
    d = os.path.join(tmp, "runs", run, "harbor", "stamp", task, "agent")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "osa-events.jsonl")
    with open(p, "w") as fh:
        for e in events:
            fh.write(json.dumps(e) + "\n")
    return p


def _turn(calls, in_tok=1000):
    """One model response carrying `calls`, in the real doubled-event shape."""
    out = [{"type": "llm_response", "duration_ms": 0,
            "usage": {"input_tokens": in_tok, "output_tokens": 10}},
           {"type": "llm_response", "duration_ms": 900,
            "usage": {"input_tokens": in_tok, "output_tokens": 10}}]
    for name, ahash, result, tcid in calls:
        out.append({"type": "tool_call", "phase": "start", "name": name,
                    "args_hash": ahash, "args": "clip", "args_bytes": 999,
                    "tool_call_id": tcid})
        out.append({"type": "tool_call", "phase": "end", "name": name,
                    "args_hash": ahash, "tool_call_id": tcid, "success": True})
        out.append({"type": "tool_result", "name": name, "result": result,
                    "tool_call_id": tcid})
    return out


# --------------------------------------------------------------------------
def test_doubled_events_are_not_double_counted():
    """Trap 1: two events per call, two per model response -- one call, one turn."""
    with tempfile.TemporaryDirectory() as tmp:
        p = _write(tmp, "r", "t", _turn([("file_read", "h1", "body", "c1")]))
        s = tcs.load_session(p)
        assert len(s.turns) == 1, f"expected 1 turn, got {len(s.turns)}"
        assert len(s.calls) == 1, f"expected 1 call, got {len(s.calls)}"
        assert not s.turns[0].batched


def test_batched_turn_is_one_turn_with_many_calls():
    """A turn's size drives the whole batching analysis; it must be the number
    of calls in ONE model response, not the number of tool_call events."""
    with tempfile.TemporaryDirectory() as tmp:
        p = _write(tmp, "r", "t", _turn([
            ("file_read", "h1", "a", "c1"),
            ("file_read", "h2", "b", "c2"),
            ("file_read", "h3", "c", "c3")]))
        s = tcs.load_session(p)
        assert len(s.turns) == 1
        assert s.turns[0].n == 3
        assert s.turns[0].batched


def test_run_below_hash_coverage_is_dropped_whole():
    """Trap 2: partial coverage must remove the RUN, not be averaged over."""
    with tempfile.TemporaryDirectory() as tmp:
        good = []
        for i in range(60):
            good += _turn([("file_read", f"h{i}", "x", f"g{i}")])
        _write(tmp, "modern", "t", good)

        old = []
        for i in range(60):
            ev = _turn([("file_read", None, "x", f"o{i}")])
            for e in ev:
                e.pop("args_hash", None)
            old += ev
        _write(tmp, "ancient", "t", old)

        sessions, dropped, _ = tcs.load(os.path.join(tmp, "runs"))
        assert dropped == ["ancient"], f"expected ancient dropped, got {dropped}"
        assert {s.run for s in sessions} == {"modern"}


def test_result_keying_inflates_where_args_keying_does_not():
    """Trap 3: two DIFFERENT edits returning the same confirmation string are
    one result-keyed 'duplicate' and zero real ones."""
    with tempfile.TemporaryDirectory() as tmp:
        confirm = "Replaced in /app/vm.js"
        p = _write(tmp, "r", "t",
                   _turn([("file_edit", "argsA", confirm, "c1")]) +
                   _turn([("file_edit", "argsB", confirm, "c2")]))
        s = tcs.load_session(p)
        a, b = s.calls
        assert a.args_hash != b.args_hash, "distinct edits must have distinct args"
        assert a.result_hash == b.result_hash, "…but a shared constant result"
        assert a.key != b.key, "args-keyed identity must keep them distinct"


def test_clipped_args_are_never_offered_as_content():
    """Trap 4: args_bytes disagrees with len(args) -> the hint is withheld, and
    argtext() falls back to the full command when one exists."""
    with tempfile.TemporaryDirectory() as tmp:
        p = _write(tmp, "r", "t", _turn([("shell_execute", "h1", "out", "c1")]))
        s = tcs.load_session(p)
        c = s.calls[0]
        assert not c.args_complete
        assert c.argtext() is None, "clipped display hint must not be served"

    with tempfile.TemporaryDirectory() as tmp:
        ev = _turn([("shell_execute", "h1", "out", "c1")])
        ev.append({"type": "command_output_delta", "tool_call_id": "c1",
                   "command": "cd /app && make -j8 && ./run --all", "seq": 0})
        p = _write(tmp, "r", "t", ev)
        s = tcs.load_session(p)
        assert s.calls[0].argtext() == "cd /app && make -j8 && ./run --all"


def test_identical_call_needs_three_so_a_pair_is_invisible():
    """The finding that the detector is calibrated above the population: a pair
    of byte-identical calls draws nothing at the shipped thresholds, and a
    triple draws a nudge."""
    def sess(n):
        with tempfile.TemporaryDirectory() as tmp:
            ev = []
            for i in range(n):
                ev += _turn([("file_read", "same", "identical bytes", f"c{i}")])
            return tcs.load_session(_write(tmp, "r", "t", ev))

    assert dict(tcs.simulate_identical_call([sess(2)])) == {}, \
        "a pair must stay invisible at the shipped thresholds"
    assert tcs.simulate_identical_call([sess(3)])["nudge"] >= 1, \
        "a triple must nudge"


def test_poll_exemption_hides_bash_output_spin():
    """bash_output heads @poll_tools, so even a long byte-identical poll spin is
    exempt -- the mechanism behind 65% of the measured waste going unseen."""
    with tempfile.TemporaryDirectory() as tmp:
        ev = []
        for i in range(5):
            ev += _turn([("bash_output", "same", "still running", f"c{i}")])
        s = tcs.load_session(_write(tmp, "r", "t", ev))
        assert dict(tcs.simulate_identical_call([s])) == {}, "poll spin is exempt"
        assert tcs.simulate_identical_call([s], exempt=False), \
            "…and visible only once the exemption is lifted"


# --------------------------------------------------------------------------
if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except AssertionError as exc:
            failed += 1
            print(f"  FAIL {fn.__name__}: {exc}")
    print(f"\n{len(fns) - failed}/{len(fns)} passed")
    sys.exit(1 if failed else 0)
