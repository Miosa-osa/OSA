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
                    telemetry["cost_usd"] = ev.get("session_cost_usd", telemetry["cost_usd"])
                    telemetry["model"] = ev.get("model") or telemetry["model"]
                    telemetry["turns"] += 1
                elif etype == "done":
                    telemetry["saw_done"] = True
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
            telemetry["spend_sidecar"] = json.loads(spend.read_text())
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
