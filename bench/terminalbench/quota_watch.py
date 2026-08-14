#!/usr/bin/env python3
"""Watch the model provider for the duration of a long run.

## Why this exists

A provider that stops serving mid-run does not announce itself. Every trial
after the cutoff still runs, still gets scheduled, still writes a trial
directory, and still scores zero -- and those zeros are indistinguishable, in
`results.json`, from a model that tried and failed. On an 89-task run that takes
many hours, a quota exhaustion at hour three silently converts the back half of
the dataset into fabricated model failures, and the run reads as a bad score
rather than as a broken run.

The remedy is not cleverness, it is a timestamped log kept *outside* the run.
This samples the provider on a fixed interval with a request small enough to be
free-ish and real enough to fail the way the benchmark's requests fail, and
appends one JSON line per sample. Afterwards, `report` prints the outage windows,
and any trial whose wall-clock overlaps one is a trial whose zero is not
attributable to the model.

It deliberately does NOT try to abort the run. Deciding to kill several hours of
work on one failed probe is a judgement call, and a probe can fail for reasons
the run survives (a single 500, a transient DNS blip). What it does is make the
judgement possible after the fact, which a run that merely died cannot.

## Usage

    ./quota_watch.py watch --out runs/<id>/quota-watch.jsonl &
    ./quota_watch.py report runs/<id>/quota-watch.jsonl
    ./quota_watch.py report runs/<id>/quota-watch.jsonl --job runs/<id>/harbor/<job>
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent

DEFAULT_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
DEFAULT_MODEL = os.environ.get("OLLAMA_MODEL", "glm-5.2:cloud")
#: Long enough that a slow-but-alive provider is not recorded as an outage,
#: short enough that a hung endpoint is caught within one interval.
DEFAULT_TIMEOUT = 120
DEFAULT_INTERVAL = 300


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def probe(url: str, model: str, timeout: int) -> dict:
    """One sample. Never raises -- a probe that crashes the watcher is useless.

    `think: false` on purpose. The probe is a liveness check, not a measurement,
    and a thinking probe costs ~40x the output tokens for the same yes/no. The
    run's own requests are pinned separately; nothing here should perturb them.
    """
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": "reply with the single word: ok"}],
            "stream": False,
            "think": False,
        }
    ).encode()
    req = urllib.request.Request(
        f"{url.rstrip('/')}/api/chat",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.monotonic()
    rec: dict = {"at": _now(), "model": model}
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8", "replace"))
        rec["ok"] = True
        rec["status"] = 200
        rec["eval_count"] = payload.get("eval_count")
        # A 200 that serves an empty completion is the shape quota exhaustion
        # takes on some gateways, so "ok" is not "status == 200".
        content = (payload.get("message") or {}).get("content") or ""
        rec["content_len"] = len(content)
        if not content.strip():
            rec["ok"] = False
            rec["error"] = "empty completion on a 200"
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", "replace")[:400]
        except Exception:  # noqa: BLE001
            pass
        rec.update(ok=False, status=exc.code, error=f"HTTP {exc.code}: {detail}")
    except Exception as exc:  # noqa: BLE001
        rec.update(ok=False, status=None, error=f"{type(exc).__name__}: {exc}")
    rec["elapsed_sec"] = round(time.monotonic() - t0, 2)
    return rec


def cmd_watch(args: argparse.Namespace) -> int:
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    print(f"[quota_watch] {args.url} {args.model} every {args.interval}s -> {out}",
          flush=True)
    while True:
        rec = probe(args.url, args.model, args.timeout)
        with out.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
        if not rec["ok"]:
            print(f"[quota_watch] PROVIDER DOWN {rec['at']} {rec.get('error')}",
                  file=sys.stderr, flush=True)
        time.sleep(args.interval)


def _outages(records: list[dict]) -> list[dict]:
    """Maximal runs of consecutive failed samples.

    A window is reported from the last good sample to the first good sample
    after it, because the actual cutoff lies somewhere inside that gap and
    claiming the first *failed* sample as the start would understate the
    affected span by up to one interval.
    """
    windows: list[dict] = []
    cur: dict | None = None
    last_ok: str | None = None
    for rec in records:
        if rec.get("ok"):
            if cur is not None:
                cur["recovered_at"] = rec["at"]
                windows.append(cur)
                cur = None
            last_ok = rec["at"]
        else:
            if cur is None:
                cur = {
                    "last_good_at": last_ok,
                    "first_failure_at": rec["at"],
                    "samples": 0,
                    "errors": [],
                }
            cur["samples"] += 1
            err = rec.get("error")
            if err and err not in cur["errors"]:
                cur["errors"].append(err)
    if cur is not None:
        cur["recovered_at"] = None  # still down at the last sample
        windows.append(cur)
    return windows


def cmd_report(args: argparse.Namespace) -> int:
    path = Path(args.log)
    if not path.exists():
        print(f"no quota-watch log at {path}", file=sys.stderr)
        return 1
    records = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line:
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    if not records:
        print("quota-watch log is empty", file=sys.stderr)
        return 1

    ok = sum(1 for r in records if r.get("ok"))
    print(f"samples          {len(records)}  ({records[0]['at']} .. {records[-1]['at']})")
    print(f"provider healthy {ok}/{len(records)} ({ok / len(records) * 100:.1f}%)")

    windows = _outages(records)
    if not windows:
        print("outages          none -- no trial's zero is attributable to the provider")
        return 0

    print(f"outages          {len(windows)}")
    for w in windows:
        end = w["recovered_at"] or "(still down at last sample)"
        print(f"  {w['last_good_at']} .. {end}  ({w['samples']} failed samples)")
        for err in w["errors"][:3]:
            print(f"      {err}")
    print()
    print("Any trial overlapping a window above scored under a provider that was "
          "not serving. Its zero is NOT a model failure and must not be counted "
          "as one; exclude it and state the reduced denominator.")
    return 2


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    w = sub.add_parser("watch", help="sample the provider until killed")
    w.add_argument("--out", required=True)
    w.add_argument("--url", default=DEFAULT_URL)
    w.add_argument("--model", default=DEFAULT_MODEL)
    w.add_argument("--interval", type=int, default=DEFAULT_INTERVAL)
    w.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    w.set_defaults(func=cmd_watch)

    r = sub.add_parser("report", help="summarise a watch log into outage windows")
    r.add_argument("log")
    r.set_defaults(func=cmd_report)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
