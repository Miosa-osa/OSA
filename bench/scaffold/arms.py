#!/usr/bin/env python3
"""Scaffold ablation: OSA against itself, one capability removed at a time.

Model, tasks, seed, limits and prompt are held fixed at the values of the
`osa-s12-full` baseline (9/12). The ONLY thing that varies between arms is the
backend process's `OSA_SETTINGS` file — so every arm is paired with the
baseline instance-for-instance, and `paired.py` conditions on the discordant
pairs.

    ./arms.py list                 # what each arm removes, and how
    ./arms.py write <arm> <path>   # emit that arm's OSA_SETTINGS file
    ./arms.py plan <arm>           # the exact backend + run_bench commands

## What a `permissions.deny` arm does and does not measure

`Permissions` deny rules are consulted by `Agent.Loop.ToolExecutor` at step 1b,
*before* any permission-mode short-circuit, so a deny beats `overdrive`. That
makes them a reliable way to remove a **capability** at run time with no code
change.

They do **not** remove the tool's schema from the request. `Registry.list_active/0`
still emits it, so a denied tool costs exactly the same prompt tokens as an
allowed one. A deny arm therefore answers "does the agent need this to solve the
task?" and says nothing directly about tokens. The token question is answered
separately and statically by `prefix_audit.py`.

Consequence, stated plainly: if a deny arm scores the same as the baseline, that
component's schema tokens are cost with no measured benefit — which is the
finding, not a failure of the method.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PRO = HERE.parent / "swebenchpro"
sys.path.insert(0, str(PRO))
sys.path.insert(0, str(HERE.parent / "swebench"))

import airgap  # type: ignore  # bench/swebench/airgap.py, read-only

#: The 34 tools `Registry.list_active/0` puts in the model's default toolbox,
#: measured on this checkout (see prefix_audit.py). Deny rules match the tool
#: name by EXACT string equality (`Permissions.tool_rule_matches?/2`), so these
#: spellings are load-bearing.
ACTIVE_TOOLS = (
    "delegate", "shell_execute", "task_write", "fleet", "send_message", "git",
    "ask_user", "scratchpad", "memory_save", "web_fetch", "bash_output",
    "file_edit", "tool_search", "exit_plan_mode", "enter_plan_mode",
    "web_search", "file_grep", "file_write", "multi_file_edit", "memory_recall",
    "file_glob", "browser", "task_resume", "dir_list", "file_read",
    "skill_manager", "codebase_explore", "task_stop", "task_output",
    "code_sandbox", "code_symbols", "semantic_search", "use_skill", "diff",
)

#: Tools observed to be called at least once across the 12 baseline instances
#: (963 calls, mined from runs/osa-s12-full/logs/*.events.jsonl).
BASELINE_USED = (
    "file_read", "shell_execute", "file_grep", "file_edit", "task_write",
    "file_glob", "file_write", "dir_list", "multi_file_edit", "bash_output",
    "code_sandbox", "git", "diff", "web_search", "web_fetch",
)

#: The subagent-dispatch surface that survives into the default toolbox.
#: `create_agent`, `message_agent`, `list_agents`, `orchestrate` and
#: `mixture_of_agents` are already in `Registry.@model_hidden`, so the model
#: never sees them and denying them would be theatre.
SUBAGENT_TOOLS = ("delegate", "fleet", "send_message",
                  "task_resume", "task_stop", "task_output")

#: Skill invocation surface. Note this does NOT stop the `## Custom Skills`
#: listing from being assembled into the prompt — only `$HOME` redirection
#: does that. See ARMS["no-skills"].
SKILL_TOOLS = ("use_skill", "skill_manager")

#: The arm that keeps only what an editor-plus-shell agent needs. Chosen as
#: the union of "used at least 20 times in the baseline" and "a bash-only
#: harness would have it", which is deliberately a little generous: the point
#: is to test whether the OTHER 25 tools earn their place, not to cripple.
MINIMAL_KEEP = ("file_read", "file_write", "file_edit", "file_grep",
                "file_glob", "dir_list", "shell_execute", "bash_output")


def _deny(*groups) -> list[str]:
    """Airgap rules first, then the arm's own tool denials, deduped in order."""
    rules = list(airgap.deny_rules())
    seen = set(rules)
    for g in groups:
        for r in g:
            if r not in seen:
                rules.append(r)
                seen.add(r)
    return rules


ARMS: dict[str, dict] = {
    "repeat": {
        "why": (
            "Variance control, and the ONLY honest way to read a 12-instance "
            "delta. bench/FINDINGS.md #8: 9 of 40 instances flipped between two "
            "runs of the same set. Without this arm every other number here is "
            "a difference of unknown scale against unknown noise."
        ),
        "also_answers": (
            "no-subagents. delegate/fleet/send_message/task_* were called ZERO "
            "times in all 963 baseline tool calls, so a deny rule on them can "
            "never fire, and the no-subagents arm is byte-identical to this one "
            "on the execution path. Running it separately would spend ~$34 to "
            "re-measure run-to-run noise under a different label."
        ),
        "deny_extra": (),
        "env": {},
    },
    "no-skills": {
        "why": (
            "The `## Custom Skills` block is assembled into EVERY request by "
            "Registry.active_skills_context/0 — measured 4,436 B / ~1,109 tok on "
            "this host — and zero skills were invoked in the baseline. This is "
            "the one arm that actually removes prompt tokens at run time."
        ),
        "also_answers": "",
        "deny_extra": SKILL_TOOLS,
        # SkillLoader scans Path.expand(\"~/.claude|.agents|.grok/skills\"),
        # which follows $HOME, not $OSA_HOME. Redirecting HOME for the backend
        # process is the only run-time way to empty the skill set.
        "env": {"HOME": "<scratch_home>", "OSA_HOME": "<scratch_home>/.osa"},
        "caveat": (
            "MEASURED, not assumed: HOME+OSA_HOME redirection cuts the block "
            "from 4,436 B to 1,668 B, NOT to zero. The residue is the 10 skills "
            "bundled in priv/skills, which SkillLoader finds via "
            "resolve_priv_skills_path/0 with no run-time switch. So this arm "
            "removes ~692 tok/request of the ~1,109 and the rest needs a code "
            "change. Also: HOME redirection moves ~/.osa and the toolchain, so "
            "the scratch HOME must symlink .asdf/.mix/.hex/.cache and every "
            "~/.osa entry EXCEPT skills/ -- otherwise the arm confounds 'no "
            "skills' with 'no credentials' or 'no Elixir'. See setup_scratch_home.sh."
        ),
    },
    "minimal-tools": {
        "why": (
            "26 of the 34 active tools are denied, leaving read/write/edit/"
            "grep/glob/list plus the shell. Tests whether the specialised tools "
            "(multi_file_edit, code_sandbox, git, diff, semantic_search, "
            "codebase_explore, code_symbols, memory_*, scratchpad, tool_search) "
            "buy anything the shell cannot, given that the shell is retained."
        ),
        "also_answers": "",
        "deny_extra": tuple(t for t in ACTIVE_TOOLS if t not in MINIMAL_KEEP),
        "env": {},
        "caveat": (
            "task_write is DENIED here and it was the 5th most-used tool (102 "
            "calls). That makes this arm a test of 'tools beyond an editor+shell' "
            "as a bundle, not of any single tool. It is the least clean arm in "
            "the matrix and its result must be read as such."
        ),
    },
}

#: Capabilities that CANNOT be isolated at run time on this checkout. Listed so
#: the report says so rather than quietly omitting them.
NOT_RUNTIME_ABLATABLE = {
    "verification-gate": (
        "Agent.Loop.VerificationGate has `@max_reprompts 2` as a module "
        "attribute and reads no Settings, Application env or System env. Its "
        "call site in react_loop.ex is unconditional. Disabling it is a code "
        "change to lib/."
    ),
    "tool-schema-removal": (
        "Registry.list_active/0 computes the active set from @model_hidden and "
        "each module's compile-time should_defer?/0. No settings key or env var "
        "moves a tool between active and deferred. Cutting the 14,398 tokens of "
        "schema is a code change; permissions.deny removes the capability while "
        "still paying for it."
    ),
    "system-prompt-sections": (
        "Soul assembles the static base from priv/prompts/SYSTEM_LEAN.md. A "
        "whole-file override at $OSA_HOME/prompts/SYSTEM.md works at run time, "
        "but there is no per-section switch; `includeGitInstructions` is in the "
        "settings schema with no reader wired."
    ),
}


def settings_document(arm: str) -> dict:
    spec = ARMS[arm]
    return {
        "_comment": (
            f"bench/scaffold arm {arm!r}. Airgap deny rules (bench/swebench/"
            f"airgap.py) plus this arm's capability removal. Point a BENCHMARK "
            f"backend at this with OSA_SETTINGS=<path>; never the daemon on 9089."
        ),
        "_arm": arm,
        "_removes": list(spec["deny_extra"]),
        "permissions": {"deny": _deny(spec["deny_extra"])},
    }


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]

    if cmd == "list":
        for name, spec in ARMS.items():
            print(f"\n=== {name} ===")
            print(f"  why        : {spec['why']}")
            if spec.get("also_answers"):
                print(f"  also answers: {spec['also_answers']}")
            print(f"  denies     : {list(spec['deny_extra']) or '(nothing beyond the airgap)'}")
            print(f"  env        : {spec['env'] or '(none)'}")
            if spec.get("caveat"):
                print(f"  CAVEAT     : {spec['caveat']}")
        print("\n=== CANNOT be ablated at run time ===")
        for k, v in NOT_RUNTIME_ABLATABLE.items():
            print(f"  {k}: {v}")
        return 0

    if cmd == "write":
        arm, path = sys.argv[2], Path(sys.argv[3])
        path.parent.mkdir(parents=True, exist_ok=True)
        doc = settings_document(arm)
        path.write_text(json.dumps(doc, indent=2) + "\n")
        print(f"wrote {path}  ({len(doc['permissions']['deny'])} deny rules, "
              f"{len(doc['_removes'])} of them this arm's)")
        return 0

    if cmd == "plan":
        arm = sys.argv[2]
        port = sys.argv[3] if len(sys.argv) > 3 else "19991"
        s = HERE / "settings" / f"{arm}.json"
        print(f"# arm: {arm}")
        print(f"./arms.py write {arm} {s}")
        print(f"# 1. backend (its own port, its own settings, never 9089):")
        env = " ".join(f"{k}={v}" for k, v in ARMS[arm]["env"].items())
        print(f"cd {PRO.parent.parent} && {env} OSA_SETTINGS={s} "
              f"OSA_HTTP_PORT={port} mix osa.serve")
        print(f"# 2. inference + grading, paired with runs/osa-s12-full:")
        print(f"cd {PRO} && ./run_bench.py --runner osa --airgap \\")
        print(f"  --osa-url http://127.0.0.1:{port} \\")
        print(f"  --instances instances/sample12.txt --run-id osa-s12-{arm} \\")
        print(f"  --dataset data/swebench_pro_public.jsonl --context-mode full \\")
        print(f"  --agent-timeout 2400 --max-turns 120 \\")
        print(f"  --infer-workers 2 --eval-workers 2")
        print(f"# 3. paired read-out:")
        print(f"{HERE}/paired.py {PRO}/runs/osa-s12-full {PRO}/runs/osa-s12-{arm}")
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
