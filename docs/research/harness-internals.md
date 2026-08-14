# Harness internals — what competing agent loops actually do

A mechanism study, not a feature survey. Every claim below is either a file:line
citation into readable source, or a number this document measured itself.

**Question being answered.** `bench/FINDINGS.md` ("The live hypothesis") states the
failure mode we actually measured: *a patch is written, tests are run, the target
test still fails, and the agent submits anyway rather than iterating.* 16 of 17
failed instances ran tests, as did 22 of 23 resolved ones. Verification is not
missing. **What happens after verification fails is missing.**

So the ranking at the bottom is by expected effect on *that*, not by novelty.

**Companion document.** `docs/research/swebench-scaffolds.md` was written the same
day from the other direction — the SWE-bench literature plus a transcript-level
audit of OSA's own gate machinery. It arrives at the same place by a different
route (its R3: "make completion conditional on a *passing target check*"), and it
carries two measurements this document does not: every failed instance stopped
voluntarily with budget left, and in 12 of 15 failures the submitted patch was
never executed in the state it was submitted in. Its D1-D4 defect list overlaps
items 1-2 below; where they overlap, they agree. **Read them together — that one
has our numbers, this one has the competitors' source.**

---

## 0. Measured baselines

All measured on this machine, today.

### OSA (v1.0.96, this checkout)

| Thing | Value | How measured |
|---|---|---|
| Active tools in the default prompt | **22** | `Registry.list_active()` via `mix run` |
| Serialized tool schema JSON | **43,396 bytes ≈ 10,849 tok** | `Jason.encode!` of the same list |
| Registered-but-deferred total | 53 tools / 87,003 bytes | same |
| `priv/prompts/SYSTEM.md` | **41,243 bytes / 6,447 words ≈ 10,300 tok** | `wc -c -w` |
| **Static prefix total** | **≈ 84.6 KB ≈ 21,150 tok** | sum of the two |
| Tool-result cap | 51,200 bytes → 40 head + 20 tail lines, spill to disk | `tool_result_storage.ex:36-40` |
| Turn ends when | model emits no tool calls (`react_loop.ex:690`) | — |
| Bench turn cap | 120 (Pro), 60 (Verified) | `bench/swebenchpro/run_bench.py:138` |

Per-tool schema cost, largest first (bytes of serialized JSON):

```
7299  delegate        4962  shell_execute   4640  task_write
2550  git             2221  ask_user        1834  memory_save
1742  web_fetch       1737  bash_output     1682  file_edit
1583  tool_search     1525  exit_plan_mode  1411  enter_plan_mode
1303  web_search      1288  file_grep       1248  file_write
1137  multi_file_edit 1101  memory_recall   1078  file_glob
1001  dir_list         909  file_read        664  code_sandbox
 458  diff
```

`SYSTEM.md` section costs (bytes):

```
9747  §6  Doing Work            8069  §3  Multi-Agent Delegation
5821  §2  Order of Operations   3912  §9  Communication
2736  §4  How You Think         2518  §7  Context & Resource Awareness
2356  §1  Execution Rules       2240  §5  Tool Usage
1138  §8  Git Safety             397  §11 Safety     389  §10 Proactiveness
```

### mini-swe-agent 2.4.6 (the control)

| Thing | Value | Citation |
|---|---|---|
| Tools | **1** (`bash`) | `models/utils/actions_toolcall.py:11-27` |
| Serialized tool schema JSON | **243 bytes ≈ 60 tok** | measured with `json.dumps(BASH_TOOL)` |
| System prompt | **96 bytes ≈ 24 tok** | `config/benchmarks/swebench.yaml:2-3` |
| Instance/task template | **4,500 bytes ≈ 1,125 tok** | `swebench.yaml:4-111` |
| **Static prefix total** | **≈ 4.8 KB ≈ 1,210 tok** | sum |
| Agent implementation | **190 lines** | `agents/default.py` |
| Tool-result cap | 10,000 chars → 5,000 head + 5,000 tail | `swebench.yaml:136-158` |
| Compaction | **none.** Full history verbatim, always | `agents/default.py:88-124` |
| Step limit / cost limit | 250 steps / $3.00 | `swebench.yaml:112-113` |
| Subagents | **none** | — |

**OSA's static prefix is 17.5x mini-swe-agent's.** mini-swe-agent nonetheless
scores respectably on SWE-bench Verified. This is the single sharpest control we
have on "how much scaffold is actually needed", and the honest reading is: not
much. It is *not* evidence that scaffolding is useless — it is evidence that
scaffolding is not what closes the gap the FINDINGS hypothesis names.

---

## 1. mini-swe-agent — the minimal control

Source: `pip download mini-swe-agent==2.4.6`, extracted. 190-line agent.

### Loop shape

`DefaultAgent.run` (`agents/default.py:88-124`) is the whole loop:

```python
while True:
    try:
        self.step()                       # query() then execute_actions()
        self.n_consecutive_format_errors = 0
    except FormatError as e: ...          # re-prompt, don't stop
    except InterruptAgentFlow as e: self.add_messages(*e.messages)
    finally: self.save(...)
    if self.messages[-1].get("role") == "exit":
        break
```

The **only** ways to reach `role == "exit"`:

1. `Submitted` — raised by the *environment*, not the model, when a command's
   output's first line is exactly `COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT` **and
   returncode == 0** (`environments/local.py:45-55`, `docker.py:143`).
2. `LimitsExceeded` / `TimeExceeded` — step, cost, or wall-clock cap
   (`default.py:130-147`).
3. `RepeatedFormatError` — 3 consecutive unparseable responses
   (`default.py:100-112`, `max_consecutive_format_errors: int = 3` at `:32`).

**This is the important mechanism.** A text-only assistant message does not end
the turn — it raises `FormatError` (`actions_toolcall.py:40-52`: *"No tool calls
found in the response. Every response MUST include at least one tool call."*)
and the agent is re-prompted. **Finishing is an ACT the model must perform, and
the environment must confirm with exit 0.** There is no way to "just stop".

No plan/act split. Round-trips per request: 1 per step, uncapped up to 250.

### Tool set and prompt

One tool, 243 bytes. No lazy discovery — there is nothing to discover. Editing
is done with `sed`/heredoc, taught inline in the prompt
(`config/mini.yaml:55-100`). Everything OSA spends 43 KB of schema on
(`file_edit`, `file_grep`, `file_glob`, `dir_list`, `git`, `multi_file_edit`)
mini-swe-agent gets from `bash` for free.

### Verification and retry

There is **no harness-enforced verification at all.** What exists instead is a
workflow written into the task template (`swebench.yaml:30-36`):

> 1. Analyze the codebase by finding and reading relevant files
> 2. **Create a script to reproduce the issue**
> 3. Edit the source code to resolve the issue
> 4. **Verify your fix works by running your script again**
> 5. Test edge cases to ensure your fix is robust

and a three-step submission ritual (`swebench.yaml:77-110`) that requires the
model to (1) `git diff > patch.txt`, (2) **inspect patch.txt** to confirm it
contains only intended changes, (3) `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT
&& cat patch.txt` as a *separate* command — with `<CRITICAL>` noting *"If the
command fails (nonzero exit status), it will not submit."*

Compare OSA's bench prompt (`bench/swebenchpro/runners.py:48-68`): no reproduce
script, no re-run-your-script step, no submission act. It ends with *"When you
are done, briefly state which files you changed and why."* The patch is then
harvested by `git_diff` after the agent falls silent
(`bench/swebenchpro/runners.py:200`).

**So OSA's completion is silence; mini-swe-agent's completion is a deliberate,
environment-confirmed act.** That difference is the closest structural analogue
to "submits anyway" that any of these harnesses provides.

### Context management

None. `self.messages` grows unbounded (`default.py:69-72`). The only bound is
the per-observation truncation at 10,000 chars → 5,000 head + 5,000 tail with an
explicit `elided_chars` count (`swebench.yaml:136-158`). Anthropic prompt
caching is handled by marking exactly the last message
(`models/utils/cache_control.py:49-67`) — a single moving breakpoint, nothing
clever.

### Subagents

None. Scores respectably anyway.

---

## 2. Codex (`research/codex-src`, current openai/codex)

### Loop shape

`RegularTask::run` (`core/src/tasks/regular.rs:38-89`) calls `run_turn`
(`core/src/session/turn.rs:153`); the real step loop is the inner
`loop { ... }` at `turn.rs:278-558`. Continuation is decided by
`needs_follow_up = model_needs_follow_up || has_pending_input` (`turn.rs:395`),
and `model_needs_follow_up` is set in `handle_output_item_done`
(`stream_events_utils.rs:288-390`): if `ToolRouter::build_tool_call(item)`
returns a call, `output.needs_follow_up = true` (`:325`); a plain assistant
message does **not** set it.

**A text-only assistant message ends the Codex turn.** Same as OSA. Exceptions:
a server-side `Completed { end_turn: Some(false) }` hint (`turn.rs:2542-2544`),
queued user input, and user-configured `Stop` hooks
(`hook_runtime.rs:303-371`; `turn.rs:474-507`) which are **off by default**.

Plan/act split is real: `ModeKind::{Plan, Default}`
(`protocol/src/config_types.rs:643-653`), default `Default`.

### Tool set

Per-tool spec builders under `core/src/tools/handlers/*_spec.rs`, assembled at
runtime by `build_tool_router` / `add_core_tool_sources`
(`core/src/tools/spec_plan.rs:119`, `:891-929`). 27 `registry.add(...)` sites,
heavily feature-flagged (`spec_plan.rs:1017-1140`). A default local session with
no MCP realistically exposes ~6-10 tools: the `exec_command`/`write_stdin`
unified-exec pair, `apply_patch`, `update_plan`, `view_image`, maybe
`web_search`.

Descriptions are **terse one-liners**. `exec_command` is
*"Runs a command in a PTY, returning output or a session ID for ongoing
interaction."* (`shell_spec.rs:90-96`). `update_plan` is three short sentences
(`plan_spec.rs:41-44`). Compare OSA's `delegate` at 7,299 bytes.

**Lazy discovery is real and shipped.** `ToolSpec::Function` carries
`defer_loading`; the registry tracks `ToolExposure::{Direct, Deferred,
DeferredModelOnly, CodeModeOnly, Hidden}` as a bitflag
(`spec_plan.rs:205-246`), and a `tool_search` tool
(`tools/handlers/tool_search.rs`) lets the model pull in undisplayed tools.
**OSA already has this** (`Registry` deferred/`tool_search`, 53 registered vs 22
sent) and it is working — 22 of 53 is a real cut.

### System prompt

| file | words | bytes |
|---|---|---|
| `gpt-5.2-codex_prompt.md` | 1,221 | 7,589 |
| `gpt_5_codex_prompt.md` | 1,088 | 6,647 |
| `gpt_5_1_prompt.md` | 3,932 | 24,204 |
| `prompt_with_apply_patch_instructions.md` | 3,916 | 23,988 |

The *newest* model-specific prompt (`gpt-5.2-codex_prompt.md`, 7.6 KB) is the
**leanest**, and it has **no "Validating your work" section and no persistence
section at all**. The older `gpt_5_1_prompt.md` has both:

- *Autonomy and Persistence* (`gpt_5_1_prompt.md:29-32`): *"Persist until the
  task is fully handled end-to-end within the current turn... do not stop at
  analysis or partial fixes."* Prompt-level only — **nothing in code checks
  compliance.**
- *Validating your work* (`:162-176`): explicitly advisory — *"consider using
  them to verify changes"* — and it tells the model to **hold off** on tests in
  interactive approval modes.

The trajectory (5.1 → 5.2: 24 KB → 7.6 KB, verification section deleted) is
evidence that OpenAI's own bet is on **less** prompt prose, not more. OSA at
41 KB is going the other way.

### Verification and retry

- `apply_patch` "verification" (`tools/handlers/apply_patch.rs:404`,
  `verify_apply_patch_args_with_mode`) validates hunk context lines against
  on-disk content and returns `RespondToModel("apply_patch verification failed:
  ...")` on mismatch. **This is diff-application correctness, not semantic
  verification.** OSA's `file_edit` does the same thing and additionally has
  word-level diffing and `Verify.PostEdit` syntax diagnostics — **OSA is ahead
  here.**
- No forced re-read, no forced test run, no forced diff-back.
- **No code detects "tests still failing" and forces continuation.** Turn
  completion is gated solely on tool-call presence.
- `update_plan` (`plan_spec.rs:7-56`) has statuses `pending|in_progress|completed`
  and **nothing checks that steps reach `completed` before the turn ends.** This
  is the clearest cargo-cult item in the study: a plan tool that is pure UI.
- PreToolUse/PostToolUse hooks exist (`hook_runtime.rs:168-300`) but are
  user-configured and off by default. **OSA's hooks system already exceeds this.**

### Context management

- Trigger: `ModelInfo::auto_compact_token_limit()` =
  `(context_window * 9) / 10` (`protocol/src/openai_models.rs:468-479`); forced
  at that limit plus `fallback_buffer_tokens` (`session/context_window.rs:74-79`).
- Kept verbatim: the most recent user messages, walking backward, up to
  `COMPACT_USER_MESSAGE_MAX_TOKENS = 20_000` (`compact.rs:55`); the rest is
  replaced by an LLM summary (`compact.rs:629-685`). Initial context
  (env/AGENTS.md) is always re-injected (`compact.rs:66-104`).
- Summarization prompt: `prompts/templates/compact/prompt.md`, **426 bytes**.
  Framed to the resuming model by `summary_prefix.md` (399 bytes) as *"Another
  language model started to solve this problem..."*
- Tool output: **middle-truncation** (head+tail) via
  `truncate_middle_with_token_budget` (`utils/string/src/truncate.rs:7-36`),
  budget `DEFAULT_MAX_OUTPUT_TOKENS = 10_000` (`core/src/unified_exec/mod.rs:71`),
  **per-call overridable by the model** via a `max_output_tokens` parameter
  (`shell_spec.rs:57`). Prefixed with `"Warning: truncated output (original token
  count: N)"` (`utils/output-truncation/src/lib.rs:12-23`).

OSA's 51,200-byte / 40-head-20-tail cap with disk spill is comparable or better,
except for the model-controllable budget, which OSA lacks.

### Subagents

Extensive and genuinely wired, not scaffolding: multi-agent v1/v2 namespaces
(`tools/handlers/multi_agents_spec.rs`, gated by `MultiAgentVersion` at
`protocol/src/protocol.rs:3050-3054`), built-in agent roles
(`core/src/agent/builtins/awaiter.toml`), `/review` as a real one-shot child
conversation (`core/src/tasks/review.rs:53` via
`codex_delegate::run_codex_thread_one_shot`), `SessionSource::SubAgent` threaded
through hooks/telemetry, depth limits and wait timeouts, and restricted guardian
reviewer sessions (`core/src/guardian/`, tool set narrowed at
`spec_plan.rs:892-923`).

Note the namespace description the model actually sees: *"Tools for spawning and
managing sub-agents."* — 44 characters (`multi_agents_spec.rs:14-15`). OSA's
`delegate` description is **7,299 bytes**, 165x larger, for a tool called once in
863 turns.

---

## 3. opencode (`research/opencode-src`)

### Loop shape

`runLoop` (`packages/opencode/src/session/prompt.ts:1081-1339`), a plain
`while (true)`. `SessionProcessor.process` (`processor.ts:627-683`) returns
`"compact" | "stop" | "continue"` (`processor.ts:30`), and `"stop"` is returned
**only** on `ctx.blocked || ctx.assistantMessage.error` (`processor.ts:679-681`).
A clean text-only reply returns `"continue"`; the loop then exits on the next
iteration's early check (`prompt.ts:1106-1130`) because the last assistant
message has a non-`tool-calls` finish reason and no tool parts.

**A text-only reply ends the turn. There is no auto-continue nudge.** The only
injected mid-loop prompt is `MAX_STEPS_PROMPT`
(`packages/core/src/session/runner/max-steps.ts:1-16`), which pushes the model
toward *stopping*, and it is off by default (`agent.steps` defaults to
`Infinity`, `agent.ts:54`).

Doom-loop guard: 3 identical consecutive tool calls (`DOOM_LOOP_THRESHOLD = 3`,
`processor.ts:29,356-369`) triggers a permission prompt. This halts, it does not
extend.

Plan/act split is a real tool: `PlanExitTool` (`tool/plan.ts:15-79`) asks the
user and synthesizes an agent switch to `build` (`plan.ts:53-69`), gated by
`flags.experimentalPlanMode` (`registry.ts:243`).

### Tool set

13 tools in a normal CLI session (`registry.ts:224-247`): `shell`, `read`,
`glob`, `grep`, `edit`, `write`, `task`, `fetch`, `todo`, `search`, `skill`,
`question`, `invalid`. Descriptions are flat `.txt` files imported as strings
(`edit.ts:5`).

`wc -c packages/opencode/src/tool/*.txt` = **15,073 bytes total**; the realistic
13-tool default set is **≈12,759 chars** of description text (parameter schemas
extra). That is **a third of OSA's 43 KB.**

Lazy discovery: the `skill` tool (`tool/skill.txt`, 399 chars) lists only skill
*names* in the system prompt and loads full instructions on call. A genuine
context-budget mechanism.

### System prompt

`session/prompt/*.txt`, per-provider. `default.txt` = 1,397 words / **8,528
bytes** — one fifth of OSA's SYSTEM.md. Others range 1,484 (`plan.txt`) to
15,372 (`gemini.txt`).

`default.txt:74-75` does instruct verification: *"Verify the solution if
possible with tests... you MUST run the lint and typecheck commands... if they
were provided to you."* But `default.txt:58` says *"just stop, rather than
providing an explanation"* — **no "don't stop early" instruction anywhere.**
opencode's prompt does not fight early stopping, consistent with its loop.

### Verification and retry

The one genuinely mechanical verification loop in this study:
**automatic LSP diagnostics fed back into the tool result after every edit and
write.**

- `write.ts:75-90` — after writing: `lsp.touchFile`, `lsp.diagnostics()`, then
  append `"\n\nLSP errors detected in this file, please fix:\n${block}"` to the
  tool's own text output.
- `edit.ts:196-201` — identical.
- `lsp/diagnostic.ts:20-27` — errors only (`severity === 1`), `MAX_PER_FILE = 20`,
  formatted as `<diagnostics file="...">SEVERITY [line:col] message</diagnostics>`.

Beyond that: **nothing checks exit codes and nothing forces a retry.** A failed
shell command is an ordinary tool result. No structural retry-on-test-failure.

**OSA already has the equivalent**: `Verify.PostEdit`
(`lib/optimal_system_agent/verify/post_edit.ex`) runs single-file syntax/parse
diagnostics plus auto-format after `file_edit`/`multi_file_edit`/`file_write`,
injected into the same turn via `Agent.Reminders.collect_diagnostics/2`. OSA is
*behind* only on cross-file semantic diagnostics (undefined symbols, type
errors), which its own moduledoc names as the deliberate follow-up.

### Context management

- Trigger: `isOverflow()` (`session/overflow.ts:22-34`) — cumulative tokens
  `>= model.limit.input - reserved`, `reserved = min(COMPACTION_BUFFER=20_000,
  maxOutputTokens)` (`overflow.ts:8,14-16`).
- Verbatim tail: `DEFAULT_TAIL_TURNS = 2` (`compaction.ts:32`), budget
  `min(8_000, max(2_000, usable*0.25))` (`compaction.ts:33-34,116-121`).
  `PRUNE_MINIMUM = 20_000`, `PRUNE_PROTECT = 40_000` (`:28-29`).
- Tool outputs shrunk to `TOOL_OUTPUT_MAX_CHARS = 2_000` when serialized *for the
  summary prompt* (`compaction.ts:52-53`).
- Summary is a fixed Markdown skeleton — Objective / Important Details / Work
  State (Completed-Active-Blocked) / Next Move / Relevant Files
  (`packages/core/src/session/compaction.ts:16-46`), `SUMMARY_OUTPUT_TOKENS = 4_096`.

OSA's `compaction_thresholds.ex:20-23` (`@max_output_reserve 20_000`,
`@autocompact_buffer 13_000`, `@warning_buffer 20_000`) is the same family of
numbers. No port needed.

### Subagents

`TaskTool` (`tool/task.ts`, `task.txt` = 2,305 chars). `registry.ts:260-273`
(`describeTask`) appends the **live agent roster** to the description at request
time rather than hardcoding it. Background subagents are behind
`OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true` (`task.ts:100`).

---

## 4. grok-build (`research/grok-build-src`)

### Loop shape — the one harness that fights early stopping

`process_conversation_turn`
(`crates/codegen/xai-grok-shell/src/session/acp_session_impl/turn.rs:1904-2731`),
inner `loop` at `:2013`. The stop branch is `if tool_calls.is_empty()` at
`turn.rs:2508`, and it is **not** a bare stop:

- **TodoGate** (`turn.rs:2511-2561`): if the model still has pending or
  in-progress todos, `evaluate_todo_gate()` (`reminders.rs:88-96`) returns
  `TodoGateDecision::Nudge`, a system reminder is pushed, and the loop
  `continue`s (`turn.rs:2542-2543`). Capped at
  `DEFAULT_TODO_GATE_MAX_FIRES = 2` (`xai-grok-agent/src/system_reminder.rs:7`),
  after which a different reminder tells the model to ask the user to continue
  (`turn.rs:2555-2560`).
- Pending interjections also `continue` (`turn.rs:2563-2565`).
- Otherwise `TurnOutcome::Completed` (`turn.rs:2567-2595`).

**Skeptical note, and it matters:** `TodoGateConfig::default()` has
`enabled: false` (`system_reminder.rs:78-84`). It is additionally gated on
`definition.carries_task_completion_discipline(audience)` and disabled under a
"laziness injection" override (`reminders.rs:474-488`). So this is real, wired
code — but **conditional, not universally on.** It is the strongest structural
"don't stop with unfinished work" mechanism found anywhere in this study, and its
own authors ship it off by default. Treat it as a design to evaluate, not a
proven win.

Action-stationarity guard (`turn.rs:2638-2648, 2733-2737`):
`NUDGE_AFTER_IDENTICAL_TOOL_CALLS = 8`,
`MAX_CONSECUTIVE_IDENTICAL_TOOL_CALLS = 16`,
`MAX_CONSECUTIVE_TRUE_NOOPS = 4`; hard stop yields
`TurnOutcome::StationarityEnded`. OSA's `DoomLoop` covers this ground.

Plan/act via `enter_plan_mode`/`exit_plan_mode` tools — **which OSA already ships
verbatim** (`enter_plan_mode` 1,411 B, `exit_plan_mode` 1,525 B in the active set).

### Tool set and prompt

Descriptions are inline Jinja-ish templates in Rust (`description_template()`),
e.g. `BashTool` at
`xai-grok-tools/src/implementations/grok_build/bash/mod.rs:1473-1490` (~1.6 KB).
The `task` tool builds its description from the live subagent roster at
registration (`task/mod.rs:203-256`), the same trick as opencode. Multiple
pluggable toolsets coexist (grok_build / concise / hashline / opencode-compat /
codex-compat), so a single total is not meaningful.

Lazy discovery: `search_tool` / `use_tool` implementations plus
`reminders/skill_discovery.rs` — a more explicit deferred-tool design than
opencode's skill-only deferral. **OSA already matches this** (22 sent of 53
registered, `tool_search` force-included).

Base prompt: `xai-grok-agent/templates/prompt.md` = **6,992 bytes**,
XOR-obfuscated into `prompt_encrypted.rs` at build time — and the authors' own
comment says *"not security — seeds live in-repo"* (`template.rs:4`), with the
plaintext shipping beside it. That is a cargo-cult artifact; ignore it.

`prompt.md` line 10 is the relevant instruction: *"Claim that something is done,
fixed, tested, or addressed only when tool output supports the claim. Otherwise
state what you did not verify and why."* And a conditional `<browser_verification>`
block (`:61-73`): *"you MUST verify your work in the browser before finishing...
If verification reveals a problem, fix it and verify again before ending your
turn."* Forceful, but scoped to UI work and conditionally included.

### Verification

`LspDiagnosticsReminder` (`xai-grok-tools/src/reminders/lsp_diagnostics.rs:10-48`)
fires on **every** tool call, not just edits: on `SearchReplaceOutput::EditsApplied`
it calls `lsp.notify_file_changed` (`:34`) then drains diagnostics
(`DIAGNOSTICS_DRAIN_TIMEOUT = 500ms`, `implementations/lsp/mod.rs:41`) and
returns them as `<system-reminder>` text. Architecturally cleaner than opencode's
inline version; same signal.

**No structural block on a failing command.** Same as everyone else.

### Context management

`intra_compaction/trigger.rs:105-138,159-160`: `trigger_threshold_percent: 85`,
`target_threshold_percent: 50`. Summary prompt from
`templates/full_replace_summary_prompt.txt` (`code_compaction/prompt.rs:15-26`),
with a self-summary variant that instructs *"DO NOT call any tools in your
response"* (`:34-45`).

### Subagents

The most elaborate of the group: `task/{mod,backend,coordinator,coordinator_state,
admission}.rs` with real admission control, a dedicated
`xai-grok-subagent-resolution` crate, three hardcoded built-ins
(`general-purpose`, `explore`, `plan` — `xai-tool-types/src/task.rs:1030-1061`),
per-subagent `isolation` of `none`/`worktree`/`sandbox` (`task/mod.rs:1756-1785`),
`resume_from`, and a soak test (`tests/test_subagent_soak.rs`). **OSA's `delegate`
already covers this surface** (roles, fork, background, `task_resume`,
`enter_worktree`).

---

## 5. Claude Code (`research/claude_code_research/free-code`)

### Loop shape

`query.ts:307` `while (true)`. `needsFollowUp = true` is set at `query.ts:834`
only when the assistant content contains a `tool_use` block. At `query.ts:1062`,
if `!needsFollowUp`, stop hooks run (`query/stopHooks.ts:63`) and the loop
returns `{reason:'completed'}` (`query.ts:1357`).

**A text-only reply ends the turn by default.** Two overrides:

1. Stop hooks returning `blockingErrors` re-enter the loop (`query.ts:1282-1306`)
   — user-configured, off by default.
2. The `TOKEN_BUDGET` feature flag nudges continuation past
   `COMPLETION_THRESHOLD = 0.9` of turn tokens (`query/tokenBudget.ts:4`, wired
   at `query.ts:1308-1355`) — feature-flagged.

No plan/act loop split: `EnterPlanModeTool`/`ExitPlanModeV2Tool` are ordinary
tools flipping a flag; the same `while(true)` runs.

### Tool set — the honest comparison

Default array (`tools.ts:76-130`): **~20-21 tools**. Summed description text
across those 20 `prompt.ts` files: **88,689 chars** — largest BashTool 21,109,
AgentTool 16,639, TodoWriteTool 9,527, SkillTool 8,218, EnterPlanModeTool 7,746.

**That is roughly double OSA's 43,396 bytes for a comparable tool count.** OSA is
not an outlier on tool-prompt size. It sits between opencode/Codex (lean) and
Claude Code/Hermes (heavy). Anyone claiming OSA's schema budget is what costs it
SWE-bench instances has to explain Claude Code.

Deferred discovery: `utils/toolSearch.ts` marks MCP/`shouldDefer` tools with
`defer_loading: true` and auto-activates `ToolSearchTool` once deferred-tool cost
exceeds `DEFAULT_AUTO_TOOL_SEARCH_PERCENTAGE = 10`% of context
(`utils/toolSearch.ts:44`). **OSA's deferral is static; that auto-activation
threshold is a small, real idea OSA lacks.**

### System prompt

`constants/prompts.ts`, 914 lines / 54,320 bytes of file; summed literal prompt
text ≈ **33,484 chars / 4,739 words** (max case). Sections: intro (`:175`),
`# System` (`:186`), `# Doing tasks` (`:199`), `# Executing actions with care`
(`:255`), `# Using your tools` (`:269`), agent-tool guidance (`:316`),
`# Session-specific guidance` (`:352`), `# Output efficiency` (`:403`),
`# Tone and style` (`:430`).

The verification clause — *"Before reporting a task complete, verify it actually
works: run the test, execute the script, check the output... If you can't
verify... say so explicitly"* (`prompts.ts:211`) — and *"Report outcomes
faithfully: if tests fail, say so"* (`prompts.ts:240`) are both **`ant`-only**.
External builds get no universal verify-before-done clause in this file.

OSA's SYSTEM.md at 41 KB is larger than CC's ~33 KB of prompt text, but the same
order of magnitude.

### Verification and retry

No unconditional post-edit re-read, diff, or test run. What exists:

- Stop hooks (`query/stopHooks.ts`) — pluggable, off by default. **OSA's hooks
  system already exceeds this.**
- An `ant`-only, `feature('VERIFICATION_AGENT')`-gated contract in the prompt
  (`constants/prompts.ts:390-395`) requiring an `AgentTool
  subagent_type="verification-agent"` before reporting completion on non-trivial
  changes, including *"spot-check it — re-run 2-3 commands from its report"*.
- `VerifyPlanExecutionTool`, behind `CLAUDE_CODE_VERIFY_PLAN=true`
  (`tools.ts:88-93`).

**None are default-on externally.** Anthropic's own answer to this problem is a
separate verification subagent — and they ship it behind two flags.

### Context management

`AUTOCOMPACT_BUFFER_TOKENS = 13_000`, `MAX_OUTPUT_TOKENS_FOR_SUMMARY = 20_000`,
`WARNING_/ERROR_THRESHOLD_BUFFER_TOKENS = 20_000`
(`services/compact/autoCompact.ts:28-90`);
`MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3` (`:69`).
`BASE_COMPACT_PROMPT` (`services/compact/prompt.ts:61-143`) is a 9-section
template with a worked example, plus partial-recompaction variants (`:145`, `:208`).

OSA's `compaction_thresholds.ex:20-23` uses **the identical constants**
(20_000 / 13_000 / 20_000). This is already a direct port; nothing left to take.

Output caps: `BASH_MAX_OUTPUT_DEFAULT = 30_000` chars (ceiling 150,000)
(`utils/shell/outputLimits.ts:3-4`, applied `tools/BashTool/utils.ts:147-158`);
`MAX_LINES_TO_READ = 2000` (`tools/FileReadTool/prompt.ts:10`); a per-message
tool-result budget runs before compaction (`applyToolResultBudget`,
`query.ts:379-394`). OSA's 51,200 bytes / 40+20 lines / disk spill is comparable.

### Subagents

`AgentTool` (`tools/AgentTool/prompt.ts:202-274`), fork or `subagent_type`. Its
"When NOT to use" (`:232-240`) discourages single-file reads and simple searches
— **the same wording family as OSA's `delegate` prompt**, and a plausible reason
neither model reaches for it on a single-repo bug fix. CC also says *"the agent's
outputs should generally be trusted"* (`:268`), which is weaker than OSA's
SYSTEM.md §3 line 152: *"Subagent summaries are SELF-REPORTS, not verified
facts."* OSA is ahead here.

---

## 6. Hermes (`research/hermes-agent`)

**This is the closest analogue to what OSA already built**, and the comparison is
the most useful one in the document.

### Loop shape

`agent/conversation_loop.py:1634`:
`while (api_call_count < agent.max_iterations and agent.iteration_budget.remaining > 0) or agent._budget_grace_call:`

A text-only reply is *not* immediately final. Three sequential gates run at
finalization (`:7422+`) before the loop exits:

1. **verify-on-stop** — `agent/verification_stop.py:229`
   `build_verify_on_stop_nudge`, wired at `conversation_loop.py:7444-7501`.
   Fires when the turn edited code without fresh passing verification evidence.
   **`max_attempts=2`** (`verification_stop.py:234,241`).
2. a `pre_verify` plugin hook gate (`:7503-7563`).
3. a kanban terminal-tool stop guard (`agent/kanban_stop.py`, `:7565-7613`).

Plus narrow degenerate-output nudges: empty response after tool calls
(`_EMPTY_TOOL_RESPONSE_NUDGE`, `:852`), dropped tool call (`:843`),
reasoning-only Codex turns (`:821`, `:833`). No plan/act split.

`verify_on_stop_enabled()` (`verification_stop.py:95`) defaults to `"auto"` — on
for CLI/TUI/programmatic, off for chat surfaces.

**This is structurally the same design as OSA's `VerificationGate`, down to the
cap of 2.** OSA is at parity with the best-in-class version of this mechanism.
That is the single most important negative result in this study: *adding a
verify-on-stop gate is not the missing piece, because OSA already has one.*

### Tool set

`_HERMES_CORE_TOOLS` (`toolsets.py:30-90`) = **59 tools**; 85 unique schema names
across `tools/*.py`. Description text across the 41 files with descriptions:
**≈131,890 chars** — 3x OSA. Deferred discovery is a 3-tier disclosure
(`tools/tool_search.py:76` `ToolSearchConfig`, `:772` `assemble_tool_defs()`),
explicitly modelled on opencode.

### System prompt

Assembled per-session in three tiers — `stable` / `context` / `volatile`
(`agent/system_prompt.py:9-21`) — which is a **prompt-cache-shaped layout**: only
the volatile tier changes, so the stable prefix stays cacheable. Given OSA's
measured 100% Anthropic cache miss caused by a timestamp inside the system block,
this layering is the relevant structural idea here, independent of verification.

The anti-stop instructions are direct and unconditional:

- `TOOL_USE_ENFORCEMENT_GUIDANCE` (`prompt_builder.py:314-324`): *"You MUST use
  your tools to take action... Never end your turn with a promise of future
  action... Every response should either (a) contain tool calls that make
  progress, or (b) deliver a final result."*
- `TASK_COMPLETION_GUIDANCE` (`:349-359`): *"Do not stop after writing a stub, a
  plan, or a single command... NEVER substitute plausible-looking fabricated
  output... for results you couldn't actually produce."*

OSA's SYSTEM.md already says all of this, at greater length (§6, lines 291-313).

### Context management

`context_compressor.py:2516`: `threshold_percent=0.50` of effective input budget
— far more aggressive than everyone else's 85-90%. `protect_first_n=3` /
`protect_last_n=20` messages kept verbatim (`:2517-2518`),
`summary_target_ratio=0.20` (`:2519`). Structured checkpoint template
(`:4086-4135`) with an explicit `[REDACTED]` instruction for secrets (`:4125`)
and an iterative-update variant preserving the previous summary (`:4137-4160`).

Output caps: `tool_output_limits.py:39-41` — `DEFAULT_MAX_BYTES = 50_000`,
`DEFAULT_MAX_LINES = 2000`, `DEFAULT_MAX_LINE_LENGTH = 2000`, all
user-configurable. OSA's 51,200 is the same number.

### Subagents

`delegate_task` (`tools/delegate_tool.py:4073` `_build_top_level_description()`),
with a caution stronger than CC's: child self-reports are unverified and must be
independently checked for external side effects (`:4110-4116`). Leaf children
cannot re-delegate. **OSA's SYSTEM.md §3 lines 152-155 already says the same
thing.**

---

## 7. What OSA already does as well or better

Stated plainly so the port list stays honest.

| Mechanism | Best reference | OSA |
|---|---|---|
| Hooks (pre/post tool, stop) | Codex `hook_runtime.rs`, CC `stopHooks.ts` | **Ahead** — richer surface, and not off-by-default |
| Post-edit diagnostics | opencode `edit.ts:196-201`, grok `lsp_diagnostics.rs` | **Parity at syntax level** (`verify/post_edit.ex`); behind on cross-file semantics |
| Word-level diffing | none of them | **Ahead** |
| Deferred tools + `tool_search` | Codex `spec_plan.rs:205-246`, CC `toolSearch.ts` | **Parity** (22 of 53 sent). CC's *auto-activation threshold* is the one missing detail |
| Head+tail output preview + disk spill | Codex `truncate.rs`, opencode, hermes | **Ahead** (spill to disk; others just elide) |
| Compaction thresholds | CC `autoCompact.ts:28-90` | **Identical constants already** |
| Verify-on-stop gate | hermes `verification_stop.py` | **Parity, including the cap of 2** |
| Subagent self-report skepticism | hermes `delegate_tool.py:4110` | **Parity**; ahead of CC |
| Doom-loop / stationarity guard | grok `turn.rs:2733-2737`, opencode `processor.ts:29` | **Parity** (`DoomLoop`) |
| Plan mode | opencode `plan.ts`, grok enter/exit_plan_mode | **Parity** (ships both tools) |

**Nothing in the reference set is a missing capability.** The gap is in the
*predicates*, not the machinery.

---

## 8. Cargo cult — do not port

- **Plan tools with no completion enforcement.** Codex `update_plan`
  (`plan_spec.rs:7-56`) has `pending|in_progress|completed` statuses and
  **nothing checks that steps reach `completed` before the turn ends.** Pure UI.
  OSA already ships the same shape; do not invest further in it without wiring it
  to a gate.
- **grok-build's prompt XOR obfuscation** (`prompt_encrypted.rs`,
  `scripts/encrypt_templates.py`) — the authors label it "not security" and ship
  the plaintext next to it.
- **More verification prose in the system prompt.** OSA's SYSTEM.md §6
  (lines 291-313) is already more explicit and more forceful than Codex's
  gpt_5_1 "Validating your work", opencode's `default.txt:74-75`, hermes'
  `TASK_COMPLETION_GUIDANCE`, and CC's `ant`-gated clause — and the failure still
  happens. A sixth restatement will not fix it. (Item 6 below covers the one
  prompt change that is *subtractive*, and therefore worth doing.)

---

## 9. RANKED PORT LIST

Ranked by expected effect on the measured failure mode — *patch written, tests
run, target still failing, submits anyway* — not by novelty.

---

### 1. Make a FAILING check a first-class continuation trigger

**Mechanism.** Every harness in this study, OSA included, gates continuation on
the *absence* of verification. None gates on the *presence of a failed*
verification. OSA's `VerificationEvidence.pending_files/1`
(`verification_evidence.ex:88-105`) answers "which writes have no passing check
after them"; `covered_after?` (`:132-142`) requires `entry.success`. A failing
`pytest` — `shell_execute` returns `{:error, "Exit N: ..."}`
(`shell_execute/handler.ex:599-600`) — is recorded with `success: false`
(`tool_executor.ex:1284-1288`) and then **ignored**. It is neither evidence for
nor against; the file just stays "pending", the gate fires its 2 reprompts and
steps aside.

**Evidence it matters.** `bench/FINDINGS.md`, "The live hypothesis": 16 of 17
failed instances ran tests. The signal OSA needs is already in the ledger and is
being discarded.

**Concrete change.** Add `failing_checks/1` to
`lib/optimal_system_agent/agent/loop/verification_evidence.ex`, returning entries
where `kind: :check, success: false` occurred after a file's last write with no
subsequent passing check. Add a branch in `react_loop.ex`'s no-tool-call clause
(alongside `VerificationGate.needs_verification?` at `:785`) that fires on a
non-empty result, with a directive quoting the failing command and its exit code,
forbidding a completion claim until it passes — or until the model states, in the
final message, exactly which check is still red.

**Risk.** Low. A new predicate over an existing ledger; no change to the turn
contract; bounded by its own counter. Failure mode is extra turns against
legitimately-red-but-unrelated suites — mitigate by scoping to checks whose
command names a file this turn wrote.

---

### 2. Stop letting `file_read` discharge a pending write

**Mechanism.** `verification_evidence.ex:46-49` classifies `file_read`,
`file_grep`, `file_glob`, `dir_list`, `code_symbols` as `:check` tools, and
`covered_after?` (`:132-142`) marks a written file verified as soon as any of
them succeeds naming that path. **Re-reading a file you just wrote proves the
bytes landed and nothing else.** `verification_gate.ex:128` then *advertises that
route to the model* as one of four acceptable ways to satisfy the gate.

OSA's own `file_edit` description contradicts it:
`tools/builtins/file_edit/prompt.ex:38` — *"Do NOT re-read the file to verify an
edit that succeeded."*

**Evidence.** A direct contradiction between two files in this repo, plus the one
principle every reference harness agrees on: verification means an external tool
that could have said no. `file_read` cannot say no.

**Concrete change.** Split `@check_tools` into `@grounded_check_tools`
(`shell_execute`, `repl`, and build/test-shaped commands) and `@inspection_tools`
(the read family). Only the former discharges a pending write. Delete the
"Re-read the edited file" bullet at `verification_gate.ex:128`.

**Risk.** Low. Will increase gate firings — that is the point. Pair with item 4
so the increase does not immediately hit the cap.

---

### 3. Give completion an ACT, not silence

**Mechanism.** mini-swe-agent's run ends only when the **environment** sees
`COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT` as the first line of a command's output
**with returncode 0** (`environments/local.py:45-55`, `docker.py:143`). A
text-only response raises `FormatError` and is re-prompted
(`actions_toolcall.py:40-52`). Submission is a three-command ritual the model
must perform, including inspecting its own patch (`swebench.yaml:77-110`).

OSA's completion is the model falling silent (`react_loop.ex:690`), after which
`bench/swebenchpro/runners.py:200` harvests `git diff`. **"Submits anyway" is not
a behaviour OSA has to prevent — it is the only behaviour OSA's contract
permits.**

**Evidence it matters.** mini-swe-agent scores respectably on SWE-bench with a
190-line agent, 1 tool, 4.8 KB of prompt, and no compaction. The submit ritual is
one of very few mechanisms it has that OSA does not, which makes it a high-prior
candidate by elimination — though note this is an argument from elimination, not
an ablation.

**Concrete change.** In autonomous postures only (`:overdrive`/`:bypass` — the
same predicate `GoalVerifier.autonomous_posture?/1` already uses), require an
explicit `finish` tool call before a turn carrying unverified writes may end. The
tool runs the project's check itself and **refuses on non-zero exit**, returning
the failure to the model. Interactive modes keep today's contract exactly.

**Risk.** Medium — the only turn-contract change in this list, and the one thing
here that can break interactive UX or strand a turn. Must be posture-gated, must
have an escape (N refusals, then finish is allowed with an explicit "unproven"
statement in the final message), and must respect `react_loop`'s single-ending
invariant (see the comment at `react_loop.ex:1336-1349`).

---

### 4. Budget the reprompt caps instead of hardcoding 2

**Mechanism.** `verification_gate.ex:51` `@max_reprompts 2`; `GoalVerifier`'s
`@max_runs` mirrors it; hermes uses `max_attempts=2`
(`verification_stop.py:234`); grok's TodoGate uses
`DEFAULT_TODO_GATE_MAX_FIRES = 2` (`system_reminder.rs:7`). Everyone picked 2 and
nobody in the reference set justifies it.

mini-swe-agent instead budgets the whole run — `step_limit: 250`,
`cost_limit: 3.0` (`swebench.yaml:112-113`) — and re-prompts format errors
indefinitely up to 3 *consecutive* failures (`agents/default.py:32,100-112`).
OSA's bench caps at 120 turns (Pro) / 60 (Verified)
(`bench/swebenchpro/run_bench.py:138`, `bench/swebench/run_bench.py:323`).

**Evidence.** Weaker than items 1-3 — an argument from the shape of the budget,
not from a measured cap-hit. **Measure first**: instrument how often the gate
reaches `@max_reprompts` and how often runs hit the turn cap. If the gate rarely
reaches 2, raising it is free and pointless; if it usually does, items 1-2 will
make it bind hard and this becomes urgent.

**Concrete change.** Replace the fixed cap with a per-turn budget (remaining
iterations and remaining cost), so the gate steps aside because the run is out of
room, not because it counted to two.

**Risk.** Low-medium. Cost. Gate on the same autonomous posture.

---

### 5. Auto-activate deferred-tool search on a context-share threshold

**Mechanism.** CC computes deferred-tool token cost and switches on
`ToolSearchTool` once it exceeds `DEFAULT_AUTO_TOOL_SEARCH_PERCENTAGE = 10`% of
context (`utils/toolSearch.ts:44`). OSA's deferral is a static per-tool
`should_defer?/0`.

**Evidence.** Structural, not outcome-measured. Ranked here because it is cheap
and OSA already has both halves.

**Concrete change.** In `tools/registry.ex`, compute active-schema bytes against
the session's context window and demote marginal tools past a threshold.

**Risk.** Low. Does not touch the failure mode at all — this is hygiene.

---

### 6. Subtract the anti-verification pressure from SYSTEM.md

**Mechanism.** The only prompt change worth making is a *deletion*.
`priv/prompts/SYSTEM.md:43`: *"**When you are DONE, STOP.** ... Redundant
verification wastes tokens and time."* And `:77`: *"Stop when it's done. No
unrequested polish, no drive-by refactors, no verification theatre."* Both carry
correct caveats, but they are the only lines in a 41 KB prompt that push toward
stopping, and they sit ~250 lines away from §6's push toward verifying.

Contrast mini-swe-agent, whose entire 4.5 KB task template contains **zero**
efficiency pressure and instead mandates *"Create a script to reproduce the
issue"* → *"Verify your fix works by running your script again"* → *"Test edge
cases"* (`swebench.yaml:30-36`). OSA's bench prompt
(`bench/swebenchpro/runners.py:48-68`) has none of those three steps.

**Evidence.** Circumstantial. OSA's prompt already says the right things about
verification and the failure still happens — which is exactly why *adding* prose
is item-8 material and *removing* a countervailing instruction is item 6.

**Concrete change.** Rewrite `:43` and `:77` so "don't repeat a passed check"
cannot be read as "don't re-check after a failure", and add the reproduce-script
step to §6's *Doing Work* ordering. Adding it to
`bench/swebenchpro/runners.py:48` is tempting, but that file's own note at
`:45-47` warns a tuned prompt measures the prompt — the right home is SYSTEM.md.

**Risk.** Low; effect uncertain. Do not count this as a fix.

---

### 7. Cross-file semantic diagnostics after edit

**Mechanism.** opencode (`edit.ts:196-201` + `lsp/diagnostic.ts:20-27`) and
grok-build (`reminders/lsp_diagnostics.rs:10-48`) both run a real language server
and feed errors back in the same turn. OSA's `Verify.PostEdit` covers
syntax/parse only and names cross-file semantics as the deliberate follow-up.

**Evidence.** A real mechanism in two harnesses — but it catches *type errors*,
not *wrong behaviour*, and SWE-bench Pro failures are behavioural. Ranked low for
this failure mode; ranked high for everyday use.

**Risk.** Medium — a language server per project is heavy, and OSA's current
design is deliberately dependency-light.

---

### 8. Reclaim the `delegate` budget — with an honest caveat

**Mechanism.** `delegate` is **7,299 bytes of schema (17% of the entire tool
budget)** plus **8,069 bytes of SYSTEM.md §3** — together ~15.4 KB ≈ 3.8k tokens,
**18% of OSA's static prefix**, for a tool called **once in 863 turns**. Codex
ships the same capability with a 44-character namespace description
(`multi_agents_spec.rs:14-15`); opencode's `task.txt` is 2,305 chars.

**Evidence.** The cost side is airtight and measured. The *benefit* side is not:
the 1-in-863 number comes from single-repo SWE-bench instances, where the whole
task reads as "simple single-file work — just do it yourself", which is precisely
what `delegate`'s own "When NOT to Use" section (and CC's `AgentTool` prompt
`:232-240`) tells the model. That is arguably the tool working correctly.

**Ranked last deliberately.** Reclaimed tokens are not resolved instances. This is
a real ~18% prefix saving with **no expected effect on the measured failure
mode**; it belongs in the cost budget, not in the fix.

**Concrete change.** Cut `delegate` to opencode's shape (~2 KB): a short purpose
line, the roster appended dynamically, the fork/background/parallel detail moved
behind `tool_search`/`use_tool`. Compress §3 similarly.

**Risk.** Low on cost, unknown on multi-agent task quality — and unmeasurable
until there is a benchmark with multi-repo or genuinely parallel work.

---

## 10. Single highest-confidence recommendation

**Items 1 and 2, together, as one change.**

OSA is already at parity with the best verify-on-stop gate in the reference set
(hermes, `verification_stop.py`). The gate is not missing — it is *satisfiable
without evidence* and *blind to the one signal that matters*:

- a successful `file_read` on the file you just wrote discharges the gate
  (`verification_evidence.ex:46-49`, `:132-142`), and `verification_gate.ex:128`
  advertises that route to the model, in direct contradiction of
  `file_edit/prompt.ex:38`;
- a `shell_execute` that exits non-zero is recorded
  (`tool_executor.ex:1284-1288`) and then dropped on the floor — **OSA already
  knows the test failed and does nothing with it.**

Fix both and the ledger goes from "did anything happen after the write?" to "is
the change proven, and if not, what exactly is red?". That is roughly fifty lines
across two existing modules: no new tool, no turn-contract change, no prompt
rewrite — aimed exactly at the mechanism `bench/FINDINGS.md` named.

Do it before item 3 (the submit act), because item 3 is only worth its risk if
the gate it defends is load-bearing. Do it before item 4 (the caps), because the
caps only bind once the predicates are correct. And read the
`verification_gate_triggered` event on the next run — now that it is forwarded —
so the next revision of this document opens with a number instead of an argument.

---

## Appendix — sources read

| Harness | Path | Form |
|---|---|---|
| mini-swe-agent 2.4.6 | `pip download mini-swe-agent`, extracted | Python, full source |
| Codex | `research/codex-src/codex-rs` | Rust, full source |
| opencode | `research/opencode-src/packages` | TypeScript, full source |
| grok-build | `research/grok-build-src/crates` | Rust, full source |
| Claude Code | `research/claude_code_research/free-code/src` | TypeScript |
| Hermes | `research/hermes-agent/{agent,tools}` | Python, full source |
| Headless invocation shapes | `bench/terminalbench/.venv/.../harbor/agents/installed/*.py` | adapters |

Headless invocations, for the record — every one is a single-shot, non-interactive
`run <instruction>`:

```
claude  --verbose --output-format=stream-json --print          (claude_code.py:1777-1781)
codex   exec --dangerously-bypass-approvals-and-sandbox --json --enable unified_exec
                                                                (codex.py:1439-1446)
opencode --model=… run --format=json --thinking --dangerously-skip-permissions
                                                                (opencode.py:516-518)
aider   --yes --message=<instruction>                           (aider.py:149-152)
cursor-agent --yolo --print --output-format=stream-json         (cursor_cli.py:882)
gemini  --yolo --model=…                                        (gemini_cli.py:852)
goose   run --recipe ~/harbor-recipe.yaml                       (goose.py:724)
mini-swe-agent --yolo --model=… --task=… --exit-immediately     (mini_swe_agent.py:735-738)
```

Note `--exit-immediately` on mini-swe-agent: even in benchmark mode it keeps the
explicit-submission contract, and the flag only suppresses the interactive
confirm. Also note goose's harbor recipe (`goose.py:183-189`) is the only adapter
that injects its own persistence instruction: *"Act autonomously. You will not
receive any feedback on your progress, so you must use your own tools to complete
the task without any intervention."*
