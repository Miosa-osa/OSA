# Scaffold ablation: which parts of OSA earn their token cost?

The model sweep varies the model with the harness fixed. The head-to-head varies
the harness with the model fixed. Neither says which **components** of our own
scaffold matter. This directory measures OSA against itself: same model, same 12
SWE-bench Pro instances, same seed and limits, one capability removed per arm,
every arm paired instance-for-instance with the `osa-s12-full` baseline.

```
./prefix_audit.py report ../swebenchpro/runs/osa-s12-full   # cost vs use, no provider needed
./arms.py list                                              # the levers, and what has none
./arms.py plan minimal-tools                                # exact commands for one arm
./paired.py <baseline> <arm> [<arm> ...]                    # exact McNemar read-out
```

Nothing here forks `bench/swebenchpro`. `arms.py` imports `bench/swebench/airgap.py`
for the deny rules, `paired.py` imports `bench/report/stats.py` for the exact
binomial machinery, and the runs are produced by `swebenchpro/run_bench.py`
unmodified.

---

## Status: Phase 1 complete, Phase 2 blocked on provider quota

The provider is capped. `glm-5.2:cloud` — and every other model on this host,
all of which are `:cloud`-hosted with no local weights — returns:

```
you (focused_varahamihira_355) have reached your session usage limit
```

This is the same cap that killed `runs/osa-s12-nospec` at 04:22 (see its
`ABORTED.md`). It is account-wide, so no arm can be run on any model, and
switching models would break pairing with the baseline anyway. `quota_watch.sh`
polls for it to lift. **No arm has been executed. No ablation result is claimed
below** — everything reported is either a static measurement of this checkout or
a mining of the baseline run already on disk.

---

## Phase 1 — the levers

| Capability | Runtime-disableable? | How |
|---|---|---|
| Block a specific tool's **execution** | **Yes** | `permissions.deny: ["<exact_name>"]` in the `OSA_SETTINGS` file |
| Subagent dispatch (`delegate`, `fleet`) | Execution yes, schema no | deny rules; schema stays on the wire |
| Skills (user scope) | **Yes**, partially | `HOME` + `OSA_HOME` redirect — cuts 4,436 B → 1,668 B, **measured** |
| Skills (bundled, `priv/skills`) | No | `resolve_priv_skills_path/0` has no switch |
| Plan mode | **Yes** | `permissions.defaultMode: "plan"` (unusable here: read-only tier) |
| Whole system prompt | **Yes** | write `$OSA_HOME/prompts/SYSTEM.md`; no per-section switch |
| **Tool set (remove schemas)** | **No — needs code** | `Registry.list_active/0` reads `@model_hidden` + each module's compile-time `should_defer?/0`. No setting, no env var. |
| **Verification gate** | **No — needs code** | `VerificationGate` `@max_reprompts 2` is a module attribute; the `react_loop.ex` call site is unconditional; the module reads no Settings/Application/System env. |
| SYSTEM.md sections | **No — needs code** | `includeGitInstructions` is in the settings schema with no reader wired |

Deny-rule semantics, verified in source: rules parse at `permissions.ex:442-467`;
a bare name matches by **exact string equality** (`tool_rule_matches?/2`,
`permissions.ex:927-929`) — no prefix, substring or glob on the tool-name half;
and `ToolExecutor` consults denies at step 1b *before* the permission-mode
short-circuit (`tool_executor.ex:381-384`), so a deny beats `overdrive`.

**Verified live, without a provider.** Booting with each arm's settings file and
calling `Permissions.check/2` directly:

```
ARM repeat          106 rules   delegate->:ask   task_write->:ask   file_read->:ask
ARM minimal-tools   129 rules   delegate->:deny  task_write->:deny  file_read->:ask
```

The lever works and is one-variable. That is Phase 1's deliverable.

### The limit that shapes everything below

`permissions.deny` removes a **capability**, not a **cost**. `Registry.list_active/0`
still emits the denied tool's schema, so a denied tool is paid for on every
request exactly as an allowed one is. A deny arm therefore answers *"does the
agent need this?"* and is silent on tokens. Cutting the schema is a code change.

So the question splits in two, and only one half needs quota:

* **Does removing it change the score?** — needs the arms (blocked).
* **What does it cost, and was it used at all?** — static + baseline mining
  (done, below).

For a component that was **never invoked in an entire run**, the second half
settles the first: a deny rule on a tool that is never called cannot alter the
execution path, so its measured effect is exactly zero.

---

## What is already measured

### The per-request static prefix

Measured on this checkout — static-base figures from `Soul.static_token_count/1`
(OSA's own counter), schemas as `byte_size(Jason.encode!(tool))/4`:

| component | tokens/request | share |
|---|---:|---:|
| tool schemas (34 active, of 81 registered) | 14,398 | 58% |
| static base, `:native_tools` variant | 9,338 | 38% |
| `## Custom Skills` listing (26 skills) | 1,109 | 4% |
| **accounted** | **24,845** | |
| observed floor (`min context_pressure.estimated_tokens`, 12/12 instances) | 28,556 | |
| unaccounted (task prompt + world state) | 3,711 (+13%) | |

Two corrections to the brief's framing, both measured:

* **SYSTEM.md is not 11.1k.** `lean_prompt?/0` already defaults to true, so the
  template is `SYSTEM_LEAN.md`, and the run took the `:native_tools` variant
  (`max_tokens: 1000000` in every `context_pressure` frame, so `lite?` was
  false). That is **9,338 tokens, not 11.1k** — the lean cut has shipped. The
  `:full` variant is 23,505 and `:lite` is 17,733; `:lite` is the *middle* one,
  not the cheap one.
* **14.4k of tool schemas is exactly right**, and it is now the largest single
  line item — bigger than the system prompt.

### Cost versus use, per tool, on the 963 baseline tool calls

**19 of the 34 active tools were never called once**, costing **7,798 tokens on
every request** — 54.2% of the schema budget — which over the baseline's 863
turns is **6.7M input tokens, 11.9% of the entire run's 56.7M**.

Never called, ranked by what they cost per request:

| tokens | tool | | tokens | tool |
|---:|---|---|---:|---|
| 1,824 | `delegate` | | 275 | `memory_recall` |
| 681 | `fleet` | | 266 | `browser` |
| 640 | `send_message` | | 263 | `task_resume` |
| 555 | `ask_user` | | 210 | `skill_manager` |
| 510 | `scratchpad` | | 183 | `codebase_explore` |
| 458 | `memory_save` | | 182 | `task_stop` |
| 395 | `tool_search` | | 177 | `task_output` |
| 381 | `exit_plan_mode` | | 166 | `code_symbols` |
| 352 | `enter_plan_mode` | | 154 | `semantic_search` |
| | | | 117 | `use_skill` |

`delegate` alone is **12.7% of the whole schema budget** and the single most
expensive tool in the prompt — more than `shell_execute` (1,240) which was
called 253 times, and more than `file_read` (227) which was called 254 times.
The eight tools that did 96% of the work cost 4,190 tokens between them.

Meanwhile OSA's own steering injects, into these coding sessions:

> *"For very large outputs, consider delegating to a sub-agent via delegate to
> process this file instead of reading it all into your own context."*

The model never took it. Not once in 12 instances.

### Skills

Zero skills were invoked. The listing is 1,109 tokens on every request and
advertises, to an agent fixing a Go bug in `flipt`, the skills **`content-writer`**,
**`customer-support`**, **`daily-briefing`**, **`email-assistant`**,
**`meeting-prep`** and **`sales-pipeline`**. Six of the ten skills OSA *bundles*
are business/CRM tools with no bearing on any coding workload.

The `HOME`+`OSA_HOME` lever removes the 16 user-scope skills (~692 tok) and
leaves the 10 bundled ones (~417 tok), which need a code change.

### Verification gate

Not observable in the baseline: zero `VerificationGate` events in 11,771
`system_event` frames. Consistent with `bench/FINDINGS.md`'s note that the event
was emitted and forwarded nowhere. It also cannot be ablated at run time. Both
facts need a code change before this component can be measured at all.

---

## Phase 2 — the arms, when quota returns

Three arms, not five, and the reasoning matters:

| arm | what it removes | why |
|---|---|---|
| `repeat` | nothing | the noise floor. `FINDINGS.md` #8: 9 of 40 instances flipped between two identical runs. Without it no delta here is readable. |
| `no-skills` | user-scope skills + `use_skill`/`skill_manager` | the only arm that actually removes prompt tokens at run time |
| `minimal-tools` | 26 of 34 tools, keeping read/write/edit/grep/glob/list/shell | tests whether the specialised tools buy anything the shell cannot |

**`no-subagents` is deliberately not run.** `delegate`, `fleet`, `send_message`
and the `task_*` lifecycle tools were called **zero** times in all 963 baseline
tool calls, so a deny rule on them can never fire and the arm is identical to
`repeat` on the execution path. Running it would spend ~$34 and ~57M tokens to
re-measure run-to-run noise under a misleading label. The `repeat` arm reports
that number honestly instead. What remains untested is only whether the *presence*
of the schemas changes behaviour — and `permissions.deny` cannot test that
either, because it leaves them on the wire.

**`no-verification-gate` cannot be run.** See the lever table.

Budget per arm, from the baseline: ~57M input tokens, ~$34, ~55 min inference
plus grading. All 12 instance images are already local, so no pulls and no new
disk pressure beyond workspaces.

## Reading the results

`n=12` cannot rank close arms — an arm must move ~5 instances before exact
McNemar clears p<0.05, and the baseline's own 9/12 has a Wilson interval of
**46.8%–91.1%**. `paired.py` conditions on discordant pairs only and prints the
exact interval; it refuses the independent-samples path in `report/cli.py compare`.

What n=12 *can* establish is the thing this experiment is for: an arm with **zero
discordant pairs** solved exactly the instances the baseline solved. Report that
as "no measured effect on these 12", never as "proven equivalent" — and treat it
as the win it is, because that component's tokens are then cost with no measured
benefit.

`paired.py` also refuses any arm carrying `fault=bench` or `fault=harness`
instances, so a repeat of the 429 outage that killed `osa-s12-nospec` is caught
rather than read as an ablation effect.
