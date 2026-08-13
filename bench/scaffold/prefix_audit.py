#!/usr/bin/env python3
"""What the scaffold costs per request, and what it was used for.

    ./prefix_audit.py measure                 # boot OSA, dump schemas + prompt sizes
    ./prefix_audit.py utilization <run_dir>   # which tools that run actually called
    ./prefix_audit.py report <run_dir>        # both, joined: cost vs use per tool

This needs no provider. It boots OSA on its own port with `mix run --no-start`,
reads `Registry.list_active/0` and `Soul.static_token_count/1`, and joins the
result against the tool calls recorded in a run's `logs/*.events.jsonl`.

## Why a static audit is a real answer and not a consolation prize

The ablation matrix asks "does removing X change the score?". This asks the
other half: "what does X cost, and was it used at all?". For a component that
was **never invoked across an entire run**, the second question settles the
first: a deny rule on a tool that was never called cannot change the execution
path, so its measured effect is exactly zero and its token cost is exactly its
schema size. No provider budget is required to establish that.

The claim this CANNOT make is about a tool's *indirect* effect — whether the
mere presence of a schema in the prompt changes what the model does with the
other tools. Nothing in `permissions.deny` can test that either, because deny
leaves the schema on the wire. Only removing the schema tests it, and that is a
code change (see arms.py NOT_RUNTIME_ABLATABLE).

## Token accounting

Tool schemas are counted as `byte_size(Jason.encode!(tool)) / 4`, the same
rough divisor the surrounding bench code uses. The static-base figures are NOT
estimated: they come from `Soul.static_token_count/1`, OSA's own counter. The
sum is cross-checked against the floor of `estimated_tokens` in the run's
`context_pressure` events, which is what the agent actually paid before doing
any work — if the two disagree by more than a few percent, the accounting is
wrong and the report says so.
"""

from __future__ import annotations

import collections
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SCRATCH = HERE / ".measured"

DUMP_EXS = r"""
alias OptimalSystemAgent.{Soul, Tools.Registry}
tools = Registry.list_active()
rows =
  Enum.map(tools, fn t ->
    %{name: t.name, bytes: byte_size(Jason.encode!(t))}
  end)
skills = Registry.active_skills_context() || ""
out = %{
  active_tools: rows,
  registered_count: length(Registry.list_tools_direct()),
  skills_ctx_bytes: byte_size(skills),
  skills_listed: length(String.split(skills, "\n- ")) - 1,
  static_base_tokens: %{
    full: Soul.static_token_count(:full),
    lite: Soul.static_token_count(:lite),
    native_tools: Soul.static_token_count(:native_tools)
  },
  lean_prompt: Soul.lean_prompt?(),
  dedupe_native: Soul.dedupe_native_tool_prompt?()
}
File.write!(System.get_env("SCAFFOLD_OUT"), Jason.encode!(out))
IO.puts("SCAFFOLD_MEASURE_OK")
"""


def measure(port: str = "19991") -> dict:
    """Boot OSA read-only and dump what every request carries."""
    SCRATCH.mkdir(exist_ok=True)
    exs = SCRATCH / "dump.exs"
    exs.write_text(DUMP_EXS)
    out = SCRATCH / "measured.json"
    env = dict(os.environ)
    env.update({"OSA_HTTP_PORT": port, "SCAFFOLD_OUT": str(out),
                "PATH": f"{Path.home()}/.asdf/shims:{Path.home()}/.asdf/bin:"
                        + env.get("PATH", "")})
    proc = subprocess.run(
        ["mix", "run", "--no-start", "-e",
         "Application.ensure_all_started(:optimal_system_agent); "
         f'Code.eval_file("{exs}")'],
        cwd=REPO, env=env, capture_output=True, text=True, timeout=600,
    )
    if "SCAFFOLD_MEASURE_OK" not in proc.stdout:
        raise SystemExit(f"measure failed:\n{proc.stdout[-2000:]}\n{proc.stderr[-2000:]}")
    return json.loads(out.read_text())


def utilization(run_dir: Path) -> tuple[collections.Counter, collections.Counter, list[int]]:
    """Tool calls and context-pressure floor from a run's recorded SSE frames."""
    calls, failed, floors = collections.Counter(), collections.Counter(), []
    for f in sorted((run_dir / "logs").glob("*.events.jsonl")):
        est = []
        for line in f.open(errors="replace"):
            line = line.strip()
            if line.startswith("data:"):
                line = line[5:].strip()
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("type") == "tool_call" and d.get("phase") == "end":
                calls[d.get("name")] += 1
                if d.get("success") is False:
                    failed[d.get("name")] += 1
            elif d.get("type") == "context_pressure" and d.get("estimated_tokens"):
                est.append(d["estimated_tokens"])
        if est:
            floors.append(min(est))
    return calls, failed, floors


def report(run_dir: Path) -> int:
    m = measure()
    calls, failed, floors = utilization(run_dir)

    rows = sorted(m["active_tools"], key=lambda r: -r["bytes"])
    tot_bytes = sum(r["bytes"] for r in rows)
    tot_tok = tot_bytes // 4
    sb = m["static_base_tokens"]
    # Which static-base variant this run actually took, decided by the context
    # window the run recorded rather than assumed.
    variant = "native_tools" if m["dedupe_native"] else "full"
    skills_tok = m["skills_ctx_bytes"] // 4

    print(f"=== per-request static prefix (measured, this checkout) ===")
    print(f"  static base [{variant}]  {sb[variant]:>7,} tok   "
          f"(full={sb['full']:,}  lite={sb['lite']:,}  native_tools={sb['native_tools']:,})")
    print(f"  tool schemas x{len(rows)}    {tot_tok:>7,} tok   "
          f"({tot_bytes:,} B of JSON, of {m['registered_count']} registered)")
    print(f"  skills listing         {skills_tok:>7,} tok   "
          f"({m['skills_listed']} skills, {m['skills_ctx_bytes']:,} B)")
    acct = sb[variant] + tot_tok + skills_tok
    print(f"  {'-' * 46}")
    print(f"  accounted              {acct:>7,} tok")
    if floors:
        obs = min(floors)
        drift = 100.0 * (obs - acct) / obs
        print(f"  OBSERVED floor         {obs:>7,} tok   "
              f"(min context_pressure.estimated_tokens across {len(floors)} instances)")
        print(f"  unaccounted            {obs - acct:>7,} tok  ({drift:+.1f}%) "
              f"-- task prompt + world state")
        if abs(drift) > 40:
            print("  !! accounting and observation disagree by >40%: do not quote "
                  "the component split until this is explained.")

    print(f"\n=== cost vs use, per tool ===")
    print(f"{'~tok':>6} {'%prefix':>8} {'calls':>6} {'fail':>5}  tool")
    never = []
    for r in rows:
        n = calls.get(r["name"], 0)
        if n == 0:
            never.append(r)
        print(f"{r['bytes'] // 4:>6} {100 * r['bytes'] / tot_bytes:>7.1f}% "
              f"{n:>6} {failed.get(r['name'], 0):>5}  {r['name']}")

    nb = sum(r["bytes"] for r in never)
    print(f"\n  total tool calls recorded : {sum(calls.values()):,}")
    print(f"  tools called >=1 time     : {len(rows) - len(never)} of {len(rows)}")
    print(f"  NEVER CALLED              : {len(never)} tools, {nb // 4:,} tok/request "
          f"({100 * nb / tot_bytes:.1f}% of the schema budget)")
    print(f"    {', '.join(r['name'] for r in never)}")

    # What the whole run paid for the never-called schemas.
    res = json.loads((run_dir / "results.json").read_text())
    turns = int(res["aggregate"]["turns_mean"] * res["aggregate"]["instances_attempted"])
    print(f"\n  this run: {turns:,} turns x {nb // 4:,} tok = "
          f"{turns * nb // 4:,} input tokens spent on tool schemas that were "
          f"never called")
    print(f"  ({100 * (turns * nb // 4) / res['aggregate']['tokens_in_total']:.1f}% of "
          f"the run's {res['aggregate']['tokens_in_total']:,} input tokens)")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == "measure":
        print(json.dumps(measure(), indent=2))
        return 0
    if cmd == "utilization":
        calls, failed, floors = utilization(Path(sys.argv[2]))
        for k, v in calls.most_common():
            print(f"{v:>6} {failed.get(k, 0):>5}  {k}")
        print(f"floor tokens: min={min(floors)} mean={sum(floors) / len(floors):.0f}")
        return 0
    if cmd == "report":
        return report(Path(sys.argv[2]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
