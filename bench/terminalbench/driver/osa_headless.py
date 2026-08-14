#!/usr/bin/env python3
"""Drive one OSA episode from *inside* a Terminal-Bench task container.

Terminal-Bench grades the final state of the container, so the agent has to be
in the container. OSA is an Elixir/OTP application: the artefact that goes in is
a self-contained OTP release with ERTS bundled (see ../Dockerfile.release), and
the only headless entry point that release exposes is `osagent serve` -- the
HTTP/SSE backend. There is no one-shot `osagent run` in the release; `mix
osa.run` is a Mix task and Mix tasks are not shipped in a release.

So this driver does, in order:

  1. boot `osagent serve` on a loopback port inside the container,
  2. wait for /health,
  3. open the SSE stream FIRST (the terminal `done` frame is not replayed),
  4. put the session into overdrive so nothing parks on an approval prompt,
  5. POST /api/v1/orchestrate with the task instruction,
  6. consume frames until `done`, a timeout, or the stream dying,
  7. write telemetry + a raw event log for post-mortem.

Everything here is stdlib: the task images are arbitrary and may have no pip,
no network egress to PyPI, and no `requests`.

Exit code is 0 whenever the episode was *driven* -- a model that fails the task
is a score of 0, not a driver error. Non-zero is reserved for "OSA never came
up", which is a harness failure and must not be scored as a model failure.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from queue import Empty, Queue

AGENT_DIR = Path(os.environ.get("OSA_BENCH_AGENT_DIR", "/logs/agent"))
RELEASE = Path(os.environ.get("OSA_BENCH_RELEASE", "/installed-agent/osa"))
PORT = int(os.environ.get("OSA_BENCH_PORT", "19899"))
BASE = f"http://127.0.0.1:{PORT}"
BOOT_TIMEOUT = int(os.environ.get("OSA_BENCH_BOOT_TIMEOUT", "180"))
RUN_TIMEOUT = int(os.environ.get("OSA_BENCH_RUN_TIMEOUT", "1800"))
SESSION = os.environ.get("OSA_BENCH_SESSION", "tbench")

# Lines in the serve log that mean OSA got in its own way rather than the model
# getting the task wrong. These are the whole point of running this benchmark,
# so they are counted rather than left in a log nobody reads.
#
# These must match *events*, not banners. An earlier, looser set counted the
# boot line "Compactor started (context window is resolved per-model)" as both
# a compaction and a context-window overflow on every single task, which would
# have made the most important column in the report pure noise. Anything added
# here has to be checked against a known-good run before it is trusted.
BENIGN = re.compile(r"Compactor started|is resolved per-model", re.I)

SELF_INFLICTED = [
    # OSA's own words: "the model will NOT see all of this block". This is the
    # most damaging marker in the table -- it means the prompt was silently
    # degraded, so anything the model then got wrong is not the model's fault.
    ("essential_context_dropped", re.compile(r"ESSENTIAL context block trunc|the model will NOT see", re.I)),
    ("tool_result_truncated", re.compile(r"truncat(ed|ing)\b.{0,60}(output|result|bytes|chars)|output truncated", re.I)),
    ("compaction_ran", re.compile(r"\b(compact(ing|ed|ion)\b.{0,40}(context|history|messages)|context compacted)", re.I)),
    ("context_window_exceeded", re.compile(r"context (window|length) (exceeded|overflow|full)|prompt is too long|too many tokens", re.I)),
    ("stall_detector", re.compile(r"stall(ed)? detect|no progress detected|halting.{0,30}stall", re.I)),
    ("timeout_internal", re.compile(r"\b(timed out|timeout)\b.{0,60}(tool|turn|orchestrat|dispatch|deadline)|deadline exceeded", re.I)),
    ("dispatch_died", re.compile(r"(dispatch|delegate|subagent|fleet).{0,40}(died|crashed|exited|failed)", re.I)),
    ("approval_block", re.compile(r"requires approval|approval denied|permission denied by policy|blocked by permission", re.I)),
    ("provider_error", re.compile(r"(provider|upstream|api).{0,40}(error|refused|401|429|5\d\d)", re.I)),
    # A safety refusal is not a crash. Overdrive is supposed to be full-auto, so
    # a circuit breaker firing inside it is its own finding and gets its own
    # bucket -- it was landing in `crash` and reading as a VM fault.
    ("circuit_breaker_blocked", re.compile(r"CIRCUIT-BREAKER blocked|blocked by circuit breaker", re.I)),
    ("crash", re.compile(r"^\s*\*\* \(|GenServer .* terminating|Erlang error|\[error\].*(exception|badmatch|badarg|terminating)", re.I)),
]


# `owner` on a turn_error -> the status this driver records for the episode.
#
# The unknown case is deliberately NOT `provider_error`. An unlabeled fault is
# a fault we cannot attribute, and quietly attributing it to the model (which
# is what `provider_error` does downstream, since it is not a HARNESS_FAULT) is
# precisely the bias being removed. It gets its own bucket so it is visible and
# lands in `ambiguous` rather than inflating either side. Older runs and any
# OSA build predating the `owner` field will land here, correctly.
_OWNER_STATUS = {
    "osa": "osa_internal_error",
    "provider": "provider_error",
    "unknown": "turn_error_unattributed",
}

def _newer(a, b):
    """Reconcile two cumulative readings of one monotonic counter.

    Both the spend sidecar and the summed `cost_update` frames count the same
    session from zero, so neither can legitimately exceed the truth and the
    larger of the two is the fresher. Non-numbers are treated as absent.
    """
    vals = [v for v in (a, b) if isinstance(v, (int, float)) and not isinstance(v, bool)]
    return max(vals) if vals else None


#: `status` values that mean "no terminal branch has claimed this run yet", and
#: may therefore be replaced by `ok` when the stream ends on a clean `done`.
#: See the comment beside the `telemetry` literal in `main()`.
_STATUS_UNSET = (None, "", "running", "runner_error")


def _turn_error_owner(turn_error) -> str:
    """`osa` | `provider` | `unknown` from an additive, possibly absent field."""
    if isinstance(turn_error, dict):
        owner = turn_error.get("owner")
        if isinstance(owner, str) and owner.lstrip(":") in ("osa", "provider"):
            return owner.lstrip(":")
    return "unknown"


def log(msg: str) -> None:
    print(f"[osa-driver {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _req(path: str, payload: dict | None = None, timeout: int = 60) -> tuple[int, str]:
    url = BASE + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data, method="POST" if data is not None else "GET"
    )
    req.add_header("Content-Type", "application/json")
    token = os.environ.get("OSA_SHARED_SECRET")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def boot() -> subprocess.Popen:
    AGENT_DIR.mkdir(parents=True, exist_ok=True)
    serve_log = (AGENT_DIR / "osa-serve.log").open("wb")
    env = os.environ.copy()
    env["OSA_HTTP_PORT"] = str(PORT)
    env.setdefault("HOME", "/root")
    # erlexec's Erlang side reads os:getenv("USER") to decide whether it is
    # running as root, and its port program exits 4 outright when SHELL is
    # unset. Task images frequently ship neither.
    env.setdefault("USER", "root")
    env.setdefault("SHELL", "/bin/bash")
    # A release boots from its own directory; RELEASE_COOKIE etc. are generated
    # into the release, nothing to set.
    proc = subprocess.Popen(
        [str(RELEASE / "bin" / "osagent"), "serve"],
        stdout=serve_log,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=str(RELEASE),
        start_new_session=True,
    )
    deadline = time.monotonic() + BOOT_TIMEOUT
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(
                f"osagent serve exited during boot with code {proc.returncode}; "
                f"see {AGENT_DIR / 'osa-serve.log'}"
            )
        try:
            status, body = _req("/health", timeout=5)
            if status == 200:
                log(f"health ok after {BOOT_TIMEOUT - int(deadline - time.monotonic())}s: {body[:200]}")
                return proc
        except Exception:
            pass
        time.sleep(2)
    proc.kill()
    raise RuntimeError(f"osagent serve never became healthy within {BOOT_TIMEOUT}s")


def sse_reader(session: str, out: Queue, stop: threading.Event) -> None:
    """Parse `event: <name>\\ndata: <json>\\n\\n` frames onto the queue."""
    try:
        req = urllib.request.Request(f"{BASE}/api/v1/stream/{session}")
        token = os.environ.get("OSA_SHARED_SECRET")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(req, timeout=None) as resp:
            name = None
            for raw in resp:
                if stop.is_set():
                    return
                line = raw.decode("utf-8", "replace").strip()
                if not line or line.startswith(":"):
                    continue
                if line.startswith("event:"):
                    name = line[6:].strip()
                elif line.startswith("data:"):
                    try:
                        ev = json.loads(line[5:].strip())
                    except json.JSONDecodeError:
                        ev = {"raw": line[5:].strip()}
                    if not isinstance(ev, dict):
                        ev = {"raw": ev}
                    ev.setdefault("_event", name)
                    ev.setdefault("type", name)
                    out.put(ev)
                    if (ev.get("type") or name) == "done":
                        return
                    name = None
    except Exception as e:  # noqa: BLE001
        out.put({"type": "_reader_error", "error": f"{type(e).__name__}: {e}"})
    finally:
        out.put(None)


def scan_serve_log() -> dict:
    """Count self-inflicted-wound markers in OSA's own log.

    This is a *signal*, not a verdict: a line matching `truncat` may be benign.
    It exists so a pathology that shows up on many tasks becomes visible instead
    of being invisible inside a 0 reward.
    """
    p = AGENT_DIR / "osa-serve.log"
    counts: dict[str, int] = {}
    samples: dict[str, str] = {}
    if not p.exists():
        return {"counts": counts, "samples": samples}
    try:
        text = p.read_text("utf-8", "replace")
    except OSError:
        return {"counts": counts, "samples": samples}
    for line in text.splitlines():
        if BENIGN.search(line):
            continue
        for key, rx in SELF_INFLICTED:
            if rx.search(line):
                counts[key] = counts.get(key, 0) + 1
                samples.setdefault(key, line.strip()[:400])
    return {"counts": counts, "samples": samples}


def main() -> int:
    instruction_path = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    if not instruction_path or not instruction_path.exists():
        log("usage: osa_headless.py <instruction-file>")
        return 2
    instruction = instruction_path.read_text()
    workdir = os.getcwd()

    # The values `status` can hold that mean "nothing has decided this yet".
    #
    # `runner_error` is the INITIAL value, deliberately: a driver that dies
    # before any terminal branch runs must not leave behind a status that reads
    # like success. But that makes it a sentinel, and the clean-exit branch on
    # `done` only overwrote (None, "", "running") -- none of which this driver
    # ever sets. So every clean exit kept the sentinel, and `report.py` bucketed
    # each unsolved task as `unclassified:runner_error` instead of
    # `completed_but_wrong`. Token counts and reward were unaffected; the
    # failure TAXONOMY was, and the taxonomy is how the next round of bugs gets
    # found. Any real fault sets a specific status and breaks out before `done`,
    # so widening the sentinel set cannot mask one.
    telemetry = {
        "status": "runner_error",
        "error": None,
        "session_id": SESSION,
        "working_dir": workdir,
        "tool_calls": 0,
        "turns": 0,
        "usage_sum": {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        },
        "cost_usd": None,
        # True | False (lower bound) | None (no tree figure seen: parent-only,
        # subagent spend missing entirely). None must never render as True.
        "cost_complete": None,
        "model": None,
        "boot_s": None,
        "run_s": None,
        "saw_done": False,
        "assistant_text_frames": 0,
        "last_event_type": None,
        "event_type_counts": {},
    }
    t_boot = time.monotonic()
    proc = None
    try:
        proc = boot()
        telemetry["boot_s"] = round(time.monotonic() - t_boot, 2)
    except Exception as e:  # noqa: BLE001
        telemetry["error"] = f"boot_failed: {type(e).__name__}: {e}"
        telemetry["status"] = "install_or_boot_failed"
        telemetry["self_inflicted"] = scan_serve_log()
        (AGENT_DIR / "osa-telemetry.json").write_text(json.dumps(telemetry, indent=2))
        log(telemetry["error"])
        return 3  # harness failure, NOT a model failure

    events: Queue = Queue()
    stop = threading.Event()
    reader = threading.Thread(target=sse_reader, args=(SESSION, events, stop), daemon=True)
    reader.start()
    time.sleep(1.0)

    # Without overdrive a headless run either parks on an approval nobody can
    # answer or fails closed on every mutating tool.
    st, body = _req(
        "/api/v1/commands/execute",
        {"command": "permission_mode overdrive", "session_id": SESSION},
        timeout=30,
    )
    log(f"overdrive -> HTTP {st} {body[:160]}")

    t0 = time.monotonic()
    st, body = _req(
        "/api/v1/orchestrate",
        {"input": instruction, "session_id": SESSION, "working_dir": workdir},
        timeout=120,
    )
    if st not in (200, 202):
        stop.set()
        telemetry["status"] = "orchestrate_rejected"
        telemetry["error"] = f"orchestrate HTTP {st}: {body[:400]}"
    else:
        raw = (AGENT_DIR / "osa-events.jsonl").open("w")
        deadline = t0 + RUN_TIMEOUT
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    telemetry["status"] = "timeout"
                    telemetry["error"] = f"agent exceeded {RUN_TIMEOUT}s"
                    _req(f"/api/v1/sessions/{SESSION}/cancel", {}, timeout=30)
                    break
                try:
                    ev = events.get(timeout=min(remaining, 5.0))
                except Empty:
                    continue
                if ev is None:
                    if not telemetry["saw_done"]:
                        # The stream closed without a terminal frame. This is an
                        # OSA-side defect class (turn ended early / dispatch
                        # died), not a model failure, and is bucketed as such.
                        telemetry["status"] = "stream_closed_without_done"
                        telemetry["error"] = "SSE stream closed before `done`"
                    break
                raw.write(json.dumps(ev) + "\n")
                etype = ev.get("type") or ev.get("_event") or "?"
                telemetry["last_event_type"] = etype

                # Capture `turn_error` from WHATEVER event carries it.
                #
                # This used to be read only inside the `cost_update` branch,
                # while OSA stamps it on `agent_response` -- so a turn where
                # every provider call failed carried a fully-populated
                # `turn_error` that this driver never looked at. Verified live:
                # a run against an unreachable Ollama produced
                # `agent_response.turn_error = {owner: provider, category:
                # connection_error}` and was still recorded as a clean exit.
                # The bug was masked for as long as `status` was stuck on its
                # `runner_error` sentinel; fixing that sentinel without fixing
                # this would have turned a wrongly-alarming record into a
                # wrongly-REASSURING one, which is the worse of the two.
                if ev.get("turn_error"):
                    telemetry["turn_error"] = ev["turn_error"]
                    telemetry["turn_error_owner"] = _turn_error_owner(ev["turn_error"])
                telemetry["event_type_counts"][etype] = (
                    telemetry["event_type_counts"].get(etype, 0) + 1
                )
                if etype == "tool_call" and ev.get("phase") == "start":
                    telemetry["tool_calls"] += 1
                elif etype in ("assistant", "text", "message"):
                    telemetry["assistant_text_frames"] += 1
                elif etype == "cost_update":
                    usage = ev.get("usage") or {}
                    for k in telemetry["usage_sum"]:
                        v = usage.get(k)
                        if isinstance(v, int):
                            telemetry["usage_sum"][k] += v
                    # `session_cost_usd` is the PARENT session only. A turn
                    # that delegates bills its children to their own sidecars,
                    # so quoting it under-reports -- and $/task is the headline
                    # metric. `tree_cost_usd` is parent + descendants; it is
                    # absent on builds predating the field, hence the fallback.
                    # Both are cumulative: neither is ever summed.
                    for _k in ("tree_cost_usd", "session_cost_usd"):
                        if ev.get(_k) is not None:
                            telemetry["cost_usd"] = ev[_k]
                            break
                    # False => the figure is a LOWER BOUND. Sticky: one
                    # incomplete turn makes the session total a lower bound.
                    if ev.get("tree_cost_complete") is False:
                        telemetry["cost_complete"] = False
                    elif ev.get("tree_cost_usd") is not None and telemetry.get(
                        "cost_complete"
                    ) is None:
                        telemetry["cost_complete"] = True
                    telemetry["model"] = ev.get("model") or telemetry["model"]
                    telemetry["turns"] += 1
                    # `turn_error` is captured for EVERY event type above, not
                    # just this one -- see the comment there.
                elif etype == "done":
                    telemetry["saw_done"] = True
                    # A `done` frame means the turn ENDED, not that it
                    # SUCCEEDED. Setting status unconditionally here is how OSA
                    # reported `status: ok` on a turn where every provider call
                    # failed — 11 retries, fallback chain exhausted, zero tokens
                    # — and how a 1800s timeout with 277 turns and 32.5M input
                    # tokens was handed to the grader as a clean exit it could
                    # not see. Both times the model was charged for a harness
                    # failure.
                    #
                    # `turn_error` is now carried on the agent_response event
                    # for exactly this. Read it -- and read WHO it belongs to.
                    #
                    # A turn_error used to become `provider_error`
                    # unconditionally, and `provider_error` is not in the
                    # report's HARNESS_FAULTS set, so every OSA-internal fault
                    # that ended a turn was counted against the model. Four
                    # error kinds were mislabeled `:llm_error` on OSA's side
                    # (encoding faults, `:request_shape` -- whose own message
                    # says "This is a bug in OSA" -- `:tool_use_mismatch` and
                    # `:duplicate_tool_use`). react_loop.ex now stamps an
                    # additive `owner` field, so the split is readable here.
                    if telemetry.get("turn_error"):
                        telemetry["status"] = _OWNER_STATUS[
                            telemetry.get("turn_error_owner", "unknown")
                        ]
                    elif telemetry.get("status") in _STATUS_UNSET:
                        telemetry["status"] = "ok"
                    break
        finally:
            raw.close()
            stop.set()

    telemetry["run_s"] = round(time.monotonic() - t0, 2)
    telemetry["self_inflicted"] = scan_serve_log()

    # OSA's own per-session ledger is authoritative for tokens/cost; the summed
    # SSE frames stay alongside it so a divergence is visible.
    spend = Path(os.environ.get("HOME", "/root")) / ".osa" / "sessions" / f"{SESSION}.spend.json"
    if spend.exists():
        try:
            sidecar = json.loads(spend.read_text())
            telemetry["spend_sidecar"] = sidecar
            # The sidecar and the summed `cost_update` frames are two cumulative
            # measurements of the SAME quantity, so they reconcile by `max`, not
            # by precedence. The sidecar covers subagent spend the parent's own
            # frames never carry, so it is usually the larger; but it is written
            # by the agent process and can LAG the frames by one LLM round-trip
            # if the run is torn down before the final flush. Preferring it
            # unconditionally is how the published figures came out low.
            #
            # `max` cannot over-count here: both counters are monotonic totals
            # of one session, and on every trial where the sidecar was current
            # the two agreed to the token.
            #
            # The sidecar's own `cost_usd` is never rewritten: `tree_spend/1`
            # sums that field across descendants, so a tree total stored there
            # would make every ancestor double-count its grandchildren. Read-side
            # preference only.
            if isinstance(sidecar, dict):
                sidecar_cost = sidecar.get("tree_cost_usd")
                if sidecar_cost is not None:
                    telemetry["cost_complete"] = bool(
                        sidecar.get("tree_cost_complete", True)
                    )
                else:
                    sidecar_cost = sidecar.get("cost_usd")
                telemetry["cost_usd"] = _newer(telemetry.get("cost_usd"), sidecar_cost)
        except (json.JSONDecodeError, OSError):
            telemetry["spend_sidecar"] = None

    (AGENT_DIR / "osa-telemetry.json").write_text(json.dumps(telemetry, indent=2))
    log(
        f"status={telemetry['status']} turns={telemetry['turns']} "
        f"tools={telemetry['tool_calls']} run={telemetry['run_s']}s "
        f"self_inflicted={telemetry['self_inflicted']['counts']}"
    )

    if proc and proc.poll() is None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except Exception:  # noqa: BLE001
            proc.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
