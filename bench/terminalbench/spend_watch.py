#!/usr/bin/env python3
"""Watch what OpenRouter is actually BILLING, for the duration of a long run.

## Why this exists, and why the token counts are not a substitute

`report.py` derives dollars from the token counters OSA emits, priced at
`z-ai/glm-5.2`'s headline OpenRouter rate. On this route that figure is a lower
bound and not a small one: the model has dozens of endpoints spanning a ~6x
price range at mixed quantisation, OpenRouter chooses one per request, and
nothing in our telemetry records which one served a call. On the eight-task
probe the token-derived total came to **$0.70/task** and the account was billed
**$1.56/task** -- a 2.2x gap that no amount of care with the token arithmetic
can close, because the missing fact was never logged.

So the only sound dollar figure is the account's own. This polls
`GET /api/v1/credits` (`total_usage`, a monotonic lifetime counter), records it
against a baseline taken before the run, and is the thing a cost claim should
be sourced from. The token-derived number stays worth reporting -- it is the
one that moves when caching starts working -- but it is reported *beside* this,
never instead of it.

## And it enforces the ceiling the operator set

`quota_watch.py` deliberately does not abort a run: it watches for the provider
dying, and killing hours of work on one failed probe is a bad trade. A budget
ceiling is the opposite case. Overshooting it cannot be undone afterwards and
every extra minute makes it worse, so `--hard-stop` terminates the run and says
so, rather than leaving a number for someone to be unhappy about later.

`--hard-stop` is enforced against **billed** spend, which is the figure that
can actually overrun. There is no equivalent guard available inside the agent:
OSA's own `max_budget_usd` is a per-session cap, and setting it would inject a
``- Budget: $x / $y`` line into every prompt (`Agent.Context.build/1`), which
changes what the model is told and makes the arm non-comparable to a baseline
run that had no such line. A ceiling enforced from outside the container
changes nothing about the measurement until the moment it fires.

Usage:
    ./spend_watch.py baseline
    ./spend_watch.py watch --out runs/<id>/spend-watch.jsonl \
        --baseline 1176.769878 --hard-stop 250 --kill-pid <pid>
    ./spend_watch.py report runs/<id>/spend-watch.jsonl
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CREDITS_URL = "https://openrouter.ai/api/v1/credits"
KEY_FILE = Path.home() / ".osa" / "openrouter.key"

#: Long enough not to hammer the endpoint over a 13-hour run, short enough that
#: an overrun is caught within a couple of dollars at the observed burn rate
#: (~$11/hour on the probe).
DEFAULT_INTERVAL = 120


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _key() -> str:
    """The key, from the environment or the 0600 file outside the repo.

    Never logged, never echoed, and never written into a run artefact -- this
    function is the only place it is read.
    """
    k = os.environ.get("OPENROUTER_API_KEY")
    if k:
        return k.strip()
    if KEY_FILE.exists():
        return KEY_FILE.read_text().strip()
    raise SystemExit(f"no OPENROUTER_API_KEY and no {KEY_FILE}")


def sample(timeout: int = 30) -> dict:
    """One reading. Never raises: a watcher that dies is not a watcher."""
    try:
        req = urllib.request.Request(
            CREDITS_URL, headers={"Authorization": f"Bearer {_key()}"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.load(r)["data"]
        return {
            "ts": _now(),
            "ok": True,
            "total_usage": float(d["total_usage"]),
            "total_credits": float(d["total_credits"]),
        }
    except Exception as exc:  # noqa: BLE001 -- see docstring
        return {"ts": _now(), "ok": False, "error": f"{type(exc).__name__}: {exc}"}


def cmd_baseline(_args) -> int:
    s = sample()
    if not s["ok"]:
        print(json.dumps(s))
        return 1
    print(json.dumps(s, indent=2))
    return 0


def cmd_watch(args) -> int:
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    base = args.baseline
    if base is None:
        s = sample()
        if not s["ok"]:
            raise SystemExit(f"cannot take a baseline: {s['error']}")
        base = s["total_usage"]
        print(f"[spend-watch] baseline {base:.6f}", flush=True)

    with out.open("a") as fh:
        fh.write(json.dumps({"ts": _now(), "event": "start", "baseline": base}) + "\n")
        fh.flush()
        while True:
            s = sample()
            if s["ok"]:
                s["spent"] = round(s["total_usage"] - base, 6)
            fh.write(json.dumps(s) + "\n")
            fh.flush()

            if s["ok"] and args.hard_stop and s["spent"] >= args.hard_stop:
                stop = {
                    "ts": _now(),
                    "event": "hard_stop",
                    "spent": s["spent"],
                    "limit": args.hard_stop,
                }
                fh.write(json.dumps(stop) + "\n")
                fh.flush()
                print(f"[spend-watch] HARD STOP at ${s['spent']:.2f}", flush=True)
                if args.kill_pid:
                    # SIGTERM the runner, not SIGKILL: run_bench still has to
                    # write config.json and let report.py salvage the trials
                    # that did finish. A partial run with a stated denominator
                    # is a result; a run killed mid-write is not.
                    try:
                        os.kill(args.kill_pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                return 2

            time.sleep(args.interval)


def cmd_report(args) -> int:
    rows = [
        json.loads(l)
        for l in Path(args.log).read_text().splitlines()
        if l.strip()
    ]
    ok = [r for r in rows if r.get("ok")]
    if not ok:
        print("no successful samples")
        return 1
    base = next((r["baseline"] for r in rows if r.get("event") == "start"), None)
    first, last = ok[0], ok[-1]
    spent = last["total_usage"] - (base if base is not None else first["total_usage"])
    hours = max(
        (
            datetime.fromisoformat(last["ts"]) - datetime.fromisoformat(first["ts"])
        ).total_seconds()
        / 3600,
        1e-9,
    )
    failed = [r for r in rows if r.get("ok") is False]
    print(f"samples          {len(rows)}  ({len(failed)} failed)")
    print(f"baseline usage   {base}")
    print(f"final usage      {last['total_usage']:.6f}")
    print(f"BILLED SPEND     ${spent:.4f}")
    print(f"elapsed          {hours:.2f} h   (${spent / hours:.2f}/h)")
    print(f"credits left     ${last['total_credits'] - last['total_usage']:.2f}")
    if args.tasks:
        print(f"BILLED $/task    ${spent / args.tasks:.4f}   (n={args.tasks})")
    for r in rows:
        if r.get("event") == "hard_stop":
            print(f"!! HARD STOP fired at ${r['spent']:.2f} (limit ${r['limit']})")

    # ---------------------------------------------------------- contamination
    # `total_usage` is an ACCOUNT counter, so anything else billing the same key
    # lands in it. When that happened it is marked, and the figures above become
    # an UPPER bound for this run rather than a measurement of it. The clean
    # window is the only interval in which the account and this run are the same
    # thing, so its rate is the one to extrapolate from.
    start = next((r for r in rows if r.get("event") == "contamination_start"), None)
    end = next((r for r in rows if r.get("event") == "contamination_end"), None)
    if start:
        print("\n!! ACCOUNT SHARED during this run — the figures above are an "
              "UPPER BOUND for it.")
        print(f"   from {start['ts']}")
        print(f"   {start.get('note', '')}")
        if not end:
            print("   ...and never observed to end. Every figure above is "
                  "contaminated; treat none of them as this run's spend.")
            return 0
        print(f"   until {end['ts']}")
        t_end = datetime.fromisoformat(end["ts"])
        clean = [r for r in ok if datetime.fromisoformat(r["ts"]) >= t_end]
        if len(clean) < 2:
            print("   clean window has too few samples to rate it.")
            return 0
        c_spent = clean[-1]["spent"] - clean[0]["spent"]
        c_h = max(
            (datetime.fromisoformat(clean[-1]["ts"])
             - datetime.fromisoformat(clean[0]["ts"])).total_seconds() / 3600,
            1e-9,
        )
        print(f"\n   CLEAN WINDOW  {c_h:.2f} h, ${c_spent:.4f} "
              f"= ${c_spent / c_h:.2f}/h, {len(clean)} samples")
        print(f"   contaminated window absorbed at most "
              f"${spent - c_spent:.4f} of the total.")
        if args.tasks:
            print(f"   If the clean rate held for the whole run, this run's "
                  f"share is about ${c_spent / c_h * hours:.2f} "
                  f"(${c_spent / c_h * hours / args.tasks:.4f}/task).")
        print("   Both numbers are stated because neither is exact: the first "
              "over-attributes, the second assumes a constant rate across a "
              "task set whose per-task cost spans two orders of magnitude.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("baseline").set_defaults(fn=cmd_baseline)

    w = sub.add_parser("watch")
    w.add_argument("--out", required=True)
    w.add_argument("--baseline", type=float, default=None)
    w.add_argument("--hard-stop", type=float, default=None,
                   help="billed USD since baseline at which to stop the run")
    w.add_argument("--kill-pid", type=int, default=None)
    w.add_argument("--interval", type=int, default=DEFAULT_INTERVAL)
    w.set_defaults(fn=cmd_watch)

    r = sub.add_parser("report")
    r.add_argument("log")
    r.add_argument("--tasks", type=int, default=None,
                   help="denominator for a $/task figure")
    r.set_defaults(fn=cmd_report)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
