#!/usr/bin/env python3
"""D8 — build an ATIF trajectory from OSA's event stream, and refuse to lie about it.

## The deviation

`osa_agent.SUPPORTS_ATIF = False`. Harbor's uploader reads
`<trial>/agent/trajectory.json` and, on success, records it as the trial's
`trajectory_path` (`harbor/upload/uploader.py:531-556` — the path is
`trial_dir / "agent" / "trajectory.json"`, and `logs_dir` IS that directory, so
"write it to `<logs_dir>/trajectory.json`" and "write it where the uploader
looks" are the same instruction). Without it: no `harbor view`, no Hub
trajectory, no `harbor analyze`, no handoff, and no `--upload --public`.

## The blocker, and what is actually true about it

`ToolCall.arguments` is `dict[str, Any]`, required, documented "can be empty
dict" (`models/trajectories/tool_call.py`). So a trajectory with
`arguments: {}` on every call **validates**. It is also worse than useless:
`harbor/utils/traces_utils.py:664-671` and `:972` serialise `arguments`
VERBATIM into SFT training conversations —

    <tool_call>
    {"name": "shell_execute", "arguments": {}}
    </tool_call>

— so an empty dict does not degrade to "unknown", it becomes training data that
teaches zero-argument tool calls. `ToolCall.extra` would legally carry
`args_hash`, and `traces_utils` never reads `extra`. **A digest satisfies the
schema and does not satisfy the purpose.** That is the answer to "is a hash
enough": for validity yes, for every consumer that exists, no.

## What this module does about it, which is more than was expected

The arguments are **partly recoverable from the stream we already emit**, and —
this is the part that makes it usable rather than a guess — **provably so**.

`Agent.Loop.ToolArgMetrics.arg_hash/1` is the first 16 bytes of SHA-256 over a
canonicalised JSON encoding of the FULL argument map (maps become
`[key, value]` pairs sorted by key, recursively; keys stringified). `arg_hash`
is ported to `arg_hash()` below and verified against the real stream, so a
reconstructed argument map can be checked against the digit the agent recorded:
if it matches, the reconstruction is the arguments, not a guess at them.

Recovery sources, all already in `osa-events.jsonl`:

  * `command_output_delta.command` carries the **complete, unclipped** shell
    command, keyed by `tool_call_id`.
  * `tool_call.args` is faithful JSON for `file_edit` (`args_bytes == len(args)`
    on 181 of 188 calls) and is the bare path for the file tools.

Measured over `runs/osa-tb20-full89-f6981b61` (89 trials, 3,796 tool calls),
hash-VERIFIED recovery:

    shell_execute   1,639 / 1,954   83.9%
    file_edit         188 /   188  100.0%
    dir_list           67 /    67  100.0%
    file_glob           7 /     7  100.0%
    file_read         235 /   446   52.7%   (misses carry offset/limit)
    file_write          0 /   214    0.0%   <- content is emitted nowhere
    task_write          0 /   542    0.0%
    ------------------------------------
    TOTAL           2,136 / 3,796   56.3%

## Why `SUPPORTS_ATIF` is still False

56.3% is not a submission. The flag stays off and this module writes
`trajectory.json` only when `--force`, always stamping `extra.osa_arg_fidelity`
with the measured fraction and the per-tool breakdown, so no consumer can read
one of these as complete. `check` is the gate: it exits non-zero below
`--min-fidelity`.

## What `lib/` must emit to close this (NOT in scope here — bench/ only)

One change, stated precisely: the `:tool_call` telemetry event needs a field
carrying the **whole argument map**, alongside the existing display hint.

  * WHERE: `OptimalSystemAgent.Agent.Loop.ToolExecutor`, the same four emission
    sites that already compute `args_bytes`/`args_hash`
    (`tool_executor.ex:297-298, 318-319, 1445-1446, 1473-1474`), forwarded by
    `Mix.Tasks.Osa.Run` (`osa.run.ex:330-331`).
  * WHAT: a NEW key — `arguments` (JSON object) — never a redefinition of
    `args`, which is `Loop.ToolHint.summarize/1`'s display string and is what
    the TUI is built around. `ToolArgMetrics`'s own moduledoc records what
    happens when the two are confused: two published competitor comparisons
    were artefacts of the 60-character clip.
  * SCOPE: every tool, not the four that happen to be reconstructible.
    `file_write` and `task_write` are 756 of 3,796 calls (19.9%) and contribute
    exactly zero today, because file CONTENT appears in no event at all.
  * KEEP `args_bytes`/`args_hash`. They stop being redundant the moment
    `arguments` can be redacted: a redacted export that still carries the digest
    can prove it corresponds to the real call.

**And the reason it was a digest in the first place is a real constraint, not an
oversight.** Tool arguments carry credentials and file contents; `file_write`
alone would put every byte the agent ever wrote into an artefact that
`--upload --public` publishes. So "emit the arguments" is not the whole
requirement. The requirement is: emit them, and put the redaction decision at a
boundary that can make it — a policy that can drop or hash named fields per tool
— rather than at a 60-character clip that redacts by accident, non-deterministically
with respect to content, and destroys the analysis at the same time. A clip is
not a security control: it leaks the first 60 characters of every secret and
loses the rest of every command.

USE
---
    ./trajectory.py check  runs/<run>/harbor/<job>          # fidelity, no writes
    ./trajectory.py build  <trial_dir> --force              # write trajectory.json
    ./trajectory.py validate <trial_dir>                    # Trajectory(**json)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

SCHEMA_VERSION = "ATIF-v1.7"

#: Argument-map shapes to try when reconstructing, per tool. Ordered; the first
#: whose hash matches wins. Each entry is (source, key-name): `hint` means
#: `tool_call.args`, `command` means the unclipped string from
#: `command_output_delta`.
_SHAPES: dict[str, tuple[tuple[str, str], ...]] = {
    "shell_execute": (("command", "command"), ("hint", "command")),
    "bash_execute": (("command", "command"), ("hint", "command")),
    "file_read": (("hint", "path"),),
    "file_write": (("hint", "path"),),
    "file_transform": (("hint", "path"),),
    "dir_list": (("hint", "path"),),
    "file_glob": (("hint", "pattern"), ("hint", "path")),
    "file_grep": (("hint", "pattern"), ("hint", "query")),
    "web_fetch": (("hint", "url"),),
    "web_search": (("hint", "query"),),
}


def _canonicalize(obj):
    """The Elixir side's `ToolArgMetrics.canonicalize/1`, exactly.

    Maps become `[key, value]` pairs sorted by the stringified key, recursively.
    Anything else passes through. Without this two identical calls could hash
    differently and a duplicate would read as novel work.
    """
    if isinstance(obj, dict):
        return sorted([[str(k), _canonicalize(v)] for k, v in obj.items()],
                      key=lambda kv: kv[0])
    if isinstance(obj, list):
        return [_canonicalize(x) for x in obj]
    return obj


def arg_hash(args) -> str:
    """Port of `OptimalSystemAgent.Agent.Loop.ToolArgMetrics.arg_hash/1`.

    First 16 bytes of SHA-256 over the canonicalised JSON, lowercase hex. This
    is what makes a reconstruction checkable rather than plausible; the port is
    pinned against real stream data in `test_trajectory.py`.
    """
    payload = json.dumps(_canonicalize(args), separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(payload.encode()).hexdigest()[:32]


def read_events(trial_dir: Path) -> list[dict]:
    p = trial_dir / "agent" / "osa-events.jsonl"
    if not p.exists():
        raise SystemExit(f"no event stream at {p}")
    out = []
    with p.open() as fh:
        for line in fh:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def recover_arguments(events: list[dict]) -> dict[str, tuple[dict, bool]]:
    """tool_call_id -> (arguments, verified).

    `verified` means the reconstruction's `arg_hash` equals the one the agent
    recorded, i.e. this IS the argument map the model emitted. An unverified
    entry is `({}, False)` — never a partial guess, because a plausible-looking
    wrong argument in a training export is worse than an absent one.
    """
    commands: dict[str, str] = {}
    for e in events:
        if e.get("type") == "command_output_delta":
            cid = e.get("tool_call_id")
            if cid and cid not in commands and isinstance(e.get("command"), str):
                commands[cid] = e["command"]

    out: dict[str, tuple[dict, bool]] = {}
    for e in events:
        if e.get("type") != "tool_call" or e.get("phase") != "start":
            continue
        cid = e.get("tool_call_id")
        if not cid:
            continue
        want = e.get("args_hash")
        hint = e.get("args") if isinstance(e.get("args"), str) else None
        cands: list[dict] = []
        # A tool whose hint is already the full JSON argument map (file_edit).
        if hint and hint.startswith("{"):
            try:
                obj = json.loads(hint)
                if isinstance(obj, dict):
                    cands.append(obj)
            except json.JSONDecodeError:
                pass
        for source, key in _SHAPES.get(e.get("name") or "", ()):
            val = commands.get(cid) if source == "command" else hint
            if isinstance(val, str) and val:
                cands.append({key: val})
        found = next((c for c in cands if want and arg_hash(c) == want), None)
        out[cid] = (found or {}, found is not None)
    return out


def _flush(step: dict) -> dict | None:
    if not (step["message"] or step["reasoning"] or step["tool_calls"]):
        return None
    return step


def _blank() -> dict:
    return {"message": "", "reasoning": "", "tool_calls": [], "results": [],
            "metrics": None, "model": None}


def build_steps(events: list[dict], recovered: dict) -> list[dict]:
    """Segment the stream into ATIF steps.

    OSA emits no explicit step marker, so the boundary is inferred and this is
    the only inferred part of the export. The observed per-turn shape is

        thinking_delta* streaming_token* llm_response cost_update llm_response
        (tool_call start/end, tool_result)*

    so a step CLOSES when new reasoning or message text arrives after a
    `cost_update` has already been seen. `llm_response` is ignored outright
    rather than deduped: it is emitted twice per turn and carries no content,
    only a usage copy that `cost_update` carries more completely.
    """
    steps: list[dict] = []
    cur = _blank()
    seen_cost = False
    for e in events:
        t = e.get("type")
        if t in ("thinking_delta", "streaming_token"):
            if seen_cost:
                if (s := _flush(cur)) is not None:
                    steps.append(s)
                cur, seen_cost = _blank(), False
            key = "reasoning" if t == "thinking_delta" else "message"
            cur[key] += e.get("text") or ""
        elif t == "cost_update":
            u = e.get("usage") or {}
            cur["model"] = e.get("model")
            cur["metrics"] = {
                "prompt_tokens": (u.get("input_tokens") or 0)
                + (u.get("cache_read_input_tokens") or 0)
                + (u.get("cache_creation_input_tokens") or 0),
                "completion_tokens": u.get("output_tokens"),
                "cached_tokens": (u.get("cache_read_input_tokens") or 0)
                + (u.get("cache_creation_input_tokens") or 0)
                or None,
                "cost_usd": e.get("turn_cost_usd"),
            }
            seen_cost = True
        elif t == "tool_call" and e.get("phase") == "start":
            cid = e.get("tool_call_id") or ""
            args, verified = recovered.get(cid, ({}, False))
            cur["tool_calls"].append({
                "tool_call_id": cid,
                "function_name": e.get("name") or "unknown",
                "arguments": args,
                # The digest rides here because `arguments` may be empty and a
                # consumer must be able to tell "no arguments" from "arguments
                # this producer could not recover". `traces_utils` does not read
                # `extra`, which is exactly why this is not a substitute.
                "extra": {
                    "osa_args_hash": e.get("args_hash"),
                    "osa_args_bytes": e.get("args_bytes"),
                    "osa_arguments_verified": verified,
                },
            })
        elif t == "tool_result":
            cur["results"].append({
                "source_call_id": e.get("tool_call_id"),
                "content": e.get("result") if isinstance(e.get("result"), str) else None,
                "extra": {"success": e.get("success"), "fault_owner": e.get("fault_owner")},
            })
    if (s := _flush(cur)) is not None:
        steps.append(s)
    return steps


def fidelity(events: list[dict], recovered: dict) -> dict:
    """What fraction of this trial's tool calls carry PROVEN arguments."""
    per: dict[str, list[int]] = {}
    for e in events:
        if e.get("type") != "tool_call" or e.get("phase") != "start":
            continue
        name = e.get("name") or "?"
        ok = recovered.get(e.get("tool_call_id") or "", ({}, False))[1]
        row = per.setdefault(name, [0, 0])
        row[0] += 1
        row[1] += int(ok)
    total = sum(v[0] for v in per.values())
    verified = sum(v[1] for v in per.values())
    return {
        "tool_calls": total,
        "arguments_verified": verified,
        "fraction": round(verified / total, 4) if total else None,
        "by_tool": {k: {"calls": v[0], "verified": v[1]} for k, v in sorted(per.items())},
    }


def build(trial_dir: Path, *, instruction: str | None = None,
          agent_version: str = "unknown") -> tuple[dict, dict]:
    events = read_events(trial_dir)
    recovered = recover_arguments(events)
    fid = fidelity(events, recovered)
    raw = build_steps(events, recovered)

    session = next((e.get("session_id") for e in events if e.get("session_id")), None)
    model = next((s["model"] for s in raw if s["model"]), None)

    steps: list[dict] = []
    # Step 1 is the instruction. `source: "user"` steps may not carry any of the
    # agent-only fields (`Step.validate_agent_only_fields`).
    steps.append({"step_id": 1, "source": "user", "message": instruction or ""})
    for s in raw:
        step = {
            "step_id": len(steps) + 1,
            "source": "agent",
            "message": s["message"],
            "model_name": s["model"] or model,
        }
        if s["reasoning"]:
            step["reasoning_content"] = s["reasoning"]
        if s["tool_calls"]:
            step["tool_calls"] = s["tool_calls"]
        if s["results"]:
            # A result whose source_call_id is not among THIS step's tool_calls
            # is rejected by `Trajectory.validate_tool_call_references`, so an
            # orphan is demoted to an unattributed result rather than dropped.
            ids = {tc["tool_call_id"] for tc in s["tool_calls"]}
            step["observation"] = {"results": [
                r if r["source_call_id"] in ids else {**r, "source_call_id": None}
                for r in s["results"]
            ]}
        if s["metrics"]:
            step["metrics"] = s["metrics"]
        steps.append(step)

    doc = {
        "schema_version": SCHEMA_VERSION,
        "session_id": session,
        "agent": {"name": "osa", "version": agent_version, "model_name": model},
        "steps": steps,
        "extra": {
            # STAMPED ON EVERY DOCUMENT. A consumer must not have to know the
            # provenance of this file to know that its arguments are partial.
            "osa_arg_fidelity": fid,
            "osa_arguments_note": (
                "`arguments` is reconstructed from the event stream and verified "
                "against the agent's own args_hash. Calls that could not be "
                "verified carry `{}` with extra.osa_arguments_verified=false — "
                "NOT a guess. See bench/terminalbench/trajectory.py."
            ),
        },
    }
    return doc, fid


# ---------------------------------------------------------------- commands


def cmd_check(args) -> int:
    job = Path(args.job_dir)
    trials = sorted(p for p in job.glob("*__*") if (p / "agent").is_dir())
    if not trials:
        raise SystemExit(f"no trial directories under {job}")
    tot = ver = 0
    per: dict[str, list[int]] = {}
    for t in trials:
        try:
            events = read_events(t)
        except SystemExit:
            continue
        f = fidelity(events, recover_arguments(events))
        tot += f["tool_calls"]
        ver += f["arguments_verified"]
        for k, v in f["by_tool"].items():
            row = per.setdefault(k, [0, 0])
            row[0] += v["calls"]
            row[1] += v["verified"]
    frac = ver / tot if tot else 0.0
    print(f"{len(trials)} trial(s), {tot} tool call(s)")
    print(f"{'tool':22s} {'calls':>7s} {'verified':>9s} {'':>8s}")
    for k, (c, v) in sorted(per.items(), key=lambda kv: -kv[1][0]):
        print(f"{k:22s} {c:7d} {v:9d} {v / c:8.1%}")
    print(f"{'TOTAL':22s} {tot:7d} {ver:9d} {frac:8.1%}")
    print()
    if frac < args.min_fidelity:
        print(
            f"BLOCK  {frac:.1%} of tool calls carry provable arguments, below the "
            f"{args.min_fidelity:.0%} floor.\n"
            "       A trajectory built from this is schema-valid and worthless: "
            "`harbor/utils/traces_utils.py` serialises `arguments` verbatim into "
            "training conversations, so `{}` becomes data that teaches "
            "zero-argument tool calls.\n"
            "       Closing this needs lib/ to emit the full argument map on the "
            "`:tool_call` event — see this module's docstring.",
            file=sys.stderr,
        )
        return 1
    print("Fidelity floor met.")
    return 0


def cmd_build(args) -> int:
    trial = Path(args.trial_dir)
    doc, fid = build(trial, instruction=args.instruction,
                     agent_version=args.agent_version)
    if (fid["fraction"] or 0) < args.min_fidelity and not args.force:
        raise SystemExit(
            f"refusing to write: arguments verified on "
            f"{fid['arguments_verified']}/{fid['tool_calls']} calls "
            f"({(fid['fraction'] or 0):.1%}), below {args.min_fidelity:.0%}. "
            "Pass --force to write it anyway; the document will still carry "
            "`extra.osa_arg_fidelity` saying so."
        )
    out = trial / "agent" / "trajectory.json"
    out.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"wrote {out}  ({len(doc['steps'])} steps, "
          f"arguments verified {(fid['fraction'] or 0):.1%})")
    return 0


def cmd_validate(args) -> int:
    """`Trajectory(**json)`. Cheap, because every ATIF model is extra=forbid."""
    p = Path(args.trial_dir)
    if p.is_dir():
        p = p / "agent" / "trajectory.json"
    try:
        from harbor.models.trajectories import Trajectory
    except ImportError as exc:
        raise SystemExit(f"harbor not importable ({exc}); use ./.venv/bin/python")
    Trajectory(**json.loads(p.read_text()))
    print(f"{p}: valid {SCHEMA_VERSION}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("check", help="argument fidelity over a job dir")
    p.add_argument("job_dir")
    p.add_argument("--min-fidelity", type=float, default=0.95)
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("build", help="write <trial>/agent/trajectory.json")
    p.add_argument("trial_dir")
    p.add_argument("--instruction", default=None)
    p.add_argument("--agent-version", default="unknown")
    p.add_argument("--min-fidelity", type=float, default=0.95)
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_build)
    p = sub.add_parser("validate", help="Trajectory(**json) over a built file")
    p.add_argument("trial_dir")
    p.set_defaults(fn=cmd_validate)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
