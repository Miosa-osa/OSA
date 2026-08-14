#!/usr/bin/env python3
"""Phase 1: does this model actually CALL TOOLS through OSA's OpenRouter path?

A chat completion proves nothing a benchmark needs. Tool-call encodings differ
per provider -- OpenRouter normalises most of them, but not all models on it
emit tool calls in a shape OSA's parser accepts, and a model that silently
answers in prose instead of editing files scores 0 while looking "fine".

So the probe is deliberately end-to-end and adversarial to prose: it plants a
real bug in a real git repo and requires a real edit. It passes only if

  1. tool-call frames appear on the SSE stream (the model emitted tool calls
     AND OSA parsed them), and
  2. `git diff` in the workspace is non-empty (the calls actually landed), and
  3. the planted bug is gone (the edit was the right one).

(3) is reported but NOT required to pass -- a weak model may call tools
competently and still fix the wrong line. Only (1) and (2) speak to wiring,
which is what Phase 1 is for. Conflating "can't call tools" with "isn't smart
enough" is exactly the confusion this whole experiment exists to remove.
"""

from __future__ import annotations

import argparse
import json
import queue
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import requests

BUGGY = '''\
def add(a, b):
    """Return the sum of a and b."""
    return a - b


def mul(a, b):
    """Return the product of a and b."""
    return a * b
'''

PROMPT = """\
You are working in a small Python repository. The working directory is already \
set to the repository root.

The function `add` in `calc.py` is supposed to return the SUM of its two \
arguments, but it returns the difference instead. `python3 -c "import calc; \
print(calc.add(2,3))"` prints -1 where it should print 5.

Fix the bug by editing `calc.py`. Do not create git commits. When you are done, \
say which file you changed.
"""


def make_workspace(root: Path) -> Path:
    ws = root / "repo"
    ws.mkdir(parents=True)
    (ws / "calc.py").write_text(BUGGY)
    for cmd in (
        ["git", "init", "-q"],
        ["git", "config", "user.email", "bench@example.invalid"],
        ["git", "config", "user.name", "bench"],
        ["git", "add", "-A"],
        ["git", "commit", "-qm", "base"],
    ):
        subprocess.run(cmd, cwd=ws, check=True, capture_output=True)
    return ws


def sse_reader(base, sid, out, stop, headers):
    try:
        with requests.get(
            f"{base}/api/v1/stream/{sid}", headers=headers, stream=True,
            timeout=(10, None),
        ) as r:
            r.raise_for_status()
            name = None
            for line in r.iter_lines(decode_unicode=True):
                if stop.is_set():
                    return
                if line is None:
                    continue
                if line.startswith("event:"):
                    name = line.split(":", 1)[1].strip()
                elif line.startswith("data:"):
                    payload = line.split(":", 1)[1].strip()
                    try:
                        out.put((name, json.loads(payload)))
                    except json.JSONDecodeError:
                        out.put((name, {"raw": payload}))
    except Exception as e:  # noqa: BLE001
        out.put(("__error__", {"error": f"{type(e).__name__}: {e}"}))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:19981")
    ap.add_argument("--timeout", type=int, default=420)
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    base = args.url.rstrip("/")
    headers = {"Content-Type": "application/json"}

    health = requests.get(f"{base}/health", timeout=10).json()
    model = health.get("model")
    provider = health.get("provider")
    print(f"backend: provider={provider} model={model} version={health.get('version')}")

    tmp = Path(tempfile.mkdtemp(prefix="osa-toolprobe-"))
    ws = make_workspace(tmp)
    sid = f"toolprobe-{int(time.time())}"

    evq: queue.Queue = queue.Queue()
    stop = threading.Event()
    threading.Thread(
        target=sse_reader, args=(base, sid, evq, stop, headers), daemon=True
    ).start()
    time.sleep(1.0)

    requests.post(
        f"{base}/api/v1/commands/execute", headers=headers,
        json={"command": "permission_mode overdrive", "session_id": sid}, timeout=30,
    )
    r = requests.post(
        f"{base}/api/v1/orchestrate", headers=headers,
        json={"input": PROMPT, "session_id": sid, "working_dir": str(ws.resolve())},
        timeout=60,
    )
    if r.status_code not in (200, 202):
        print(f"FAIL orchestrate HTTP {r.status_code}: {r.text[:300]}")
        return 1

    tool_calls: list[str] = []
    errors: list[str] = []
    done = False
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline and not done:
        try:
            name, ev = evq.get(timeout=2.0)
        except queue.Empty:
            continue
        if name == "__error__":
            errors.append(str(ev.get("error")))
            continue
        etype = ev.get("type") or name
        if etype == "tool_call" and ev.get("phase") == "end":
            tool_calls.append(ev.get("name") or "?")
        if etype in ("done", "complete") or name in ("done", "complete"):
            done = True
        if etype == "error" or name == "error":
            errors.append(json.dumps(ev)[:300])
    stop.set()

    diff = subprocess.run(
        ["git", "diff"], cwd=ws, capture_output=True, text=True
    ).stdout
    fixed = subprocess.run(
        [sys.executable, "-c", "import calc; print(calc.add(2,3))"],
        cwd=ws, capture_output=True, text=True,
    ).stdout.strip()

    result = {
        "model": model,
        "provider": provider,
        "completed": done,
        "tool_calls_total": len(tool_calls),
        "tool_names": sorted(set(tool_calls)),
        "diff_bytes": len(diff),
        "bug_fixed": fixed == "5",
        "add_2_3": fixed,
        "errors": errors[:5],
        # Wiring verdict: tools were emitted, parsed AND landed on disk.
        "tool_calling_works": len(tool_calls) > 0 and len(diff.strip()) > 0,
    }
    print(json.dumps(result, indent=2))
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(result, indent=2))
    return 0 if result["tool_calling_works"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
