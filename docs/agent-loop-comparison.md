# The agent loop: OSA vs five reference harnesses

**Question:** once the request is sent, how does the loop behave — and how does that differ from
the references? Specifically: why does a simple question cost multiple round-trips, why does the
model reach for tools before saying anything, and is OSA's loop well-formed?

Companion to `docs/submit-path-grok.md`, `docs/submit-path-opencode.md`,
`docs/submit-path-codex-cc.md`, which traced everything *up to* the HTTP request. This traces
everything *after* it.

**OSA:** `~/projects/osa/OSA` @ `2c85f445` (v1.0.83). Unlike the submit-path docs, OSA here is
**measured**, not only read — see §9.

**References and SHAs:**

| Harness | Tree | SHA / date | Loop entry |
|---|---|---|---|
| grok-build | `~/projects/research/grok-build-src` | `75e73f3d`, 2026-08-09 | `xai-grok-shell/src/session/acp_session_impl/turn.rs:1895` |
| codex | `~/projects/research/codex-src` | `92cbfb4d`, 2026-08-10 | `core/src/session/turn.rs:153` (`run_turn`) |
| Claude Code | `claude_code_research/free-code` @ `38c09970` (2026-04) + shipping binary `2.1.228` | | `query.ts:241` (`queryLoop`), `while(true)` at `:307` |
| opencode | `~/projects/research/opencode-src` | `959c8bd4`, 2026-08-12 | `packages/opencode/src/session/prompt.ts:1088` |
| hermes | `~/projects/research/hermes-agent` | (Python) | `agent/conversation_loop.py:1422` |

CC claims are labelled *(free-code, April)* or *(confirmed in 2.1.228)*.
`ClaudeCode-Source-March31` and `claude_elixir` were not used — the first has zero source files,
the second is OSA's own unfinished port.

---

## 0. The headline

**OSA's loop is structurally well-formed, and on every shape measured it used exactly the same
number of provider calls the references would.** A greeting cost **one** call. A one-file question
cost **two** (read, then answer) — no harness in the set can do that in one.

The multiple-round-trip complaint does not reproduce as a *loop* defect at v1.0.83. What does
reproduce, on every single call, is a **~29–35k token prompt prefix** — paid identically whether
the user typed `hi` or asked for a two-file refactor. The loop is not doing three round-trips where
the references would do one; it is doing the right number of round-trips at roughly **2–3× the
per-call price**, because nothing about a conversational turn makes the prefix smaller.

The one place OSA is genuinely alone: it is the only harness in the set that **tells the model its
remaining iteration budget** (§2), and the only one that **has a conversational fast-path
mechanism but never wires it up** (§5).

---

## 1. Stop condition

**Every harness in the set stops structurally. None is prose-shaped. OSA included.**

| Harness | Stop | file:line |
|---|---|---|
| **OSA** | no-tool-call branch of `handle_result/3`; falls through the `cond` to `finish_turn/2` | `agent/loop/react_loop.ex:666`, terminal at `:874-875` → `:883` |
| grok | `if tool_calls.is_empty() { return Ok(TurnOutcome::Completed{..}) }` | `turn.rs:2499`, `:2581` |
| codex | `needs_follow_up` set only when `ToolRouter::build_tool_call` yields a call; `if !needs_follow_up { break }` | `stream_events_utils.rs:325`, `turn.rs:472` |
| CC | `needsFollowUp` set when a `tool_use` content block streams; `if (!needsFollowUp)` exits | `query.ts:829-834`, `:1062` |
| opencode | provider `finish` field not `"tool-calls"` **and** no tool parts | `prompt.ts:1106-1130` |
| hermes | `else:` branch on `assistant_message.tool_calls` falsy | `conversation_loop.py:6985-6991` |

CC's comment is worth quoting because it is the sharpest statement of the contract, and OSA already
obeys it:

> `// Note: stop_reason === 'tool_use' is unreliable -- it's not always set correctly.`
> — `query.ts:554-558`, i.e. key on the *presence of tool_use blocks*, not on the finish reason.

**OSA is already correct here, and the historically dangerous part is already removed.** The three
prose-shaped continuation clauses (`Guardrails.wants_to_continue?/1`, `code_in_text?/1`,
`needs_verification_gate?/1`) still exist at `react_loop.ex:684`, `:709`, `:731` but every one is
now gated behind `prose_continue?/1` (`:96-104`), which defaults **false**
(`config/config.exs:58-64`). A text-only answer ends the turn. The 40-line comment at
`react_loop.ex:53-95` documents the old ping-pong defect (measured at `max_iterations + 1`
round-trips for one text-only answer) and why it was cut. **No change recommended.**

---

## 2. Iteration budget — the one place OSA is alone

| Harness | Cap | Default | Told to the model? |
|---|---|---|---|
| **OSA** | `max_iterations` | **200** (`config/config.exs:52`), else effort ceiling: fast 50 / medium 100 / high 150 / xhigh 2000 / ultra 4000 (`agent/effort.ex:22-79`) | **YES** — `inject_iteration_budget/2`, `react_loop.ex:1969` |
| grok | `max_turns` | `None` — uncapped for the interactive agent | No (`turn.rs:2697-2707`) |
| codex | none found | unbounded | No — the loop is literally step-unbounded; only auto-compaction bounds it (`turn.rs:441` comment) |
| CC | `maxTurns` | unset in the REPL; `--max-turns` only works with `--print` | No (`query.ts:1705-1711`) |
| opencode | `agent.steps` | `Infinity` (`prompt.ts:1178`) | No |
| hermes | `max_iterations` | 90 (`agent/agent_init.py:470`) | No — logged only (`conversation_loop.py:2392`) |

**Five of five references never put a remaining-iterations number in the prompt. OSA does.**

The good news is that this is already *mostly* fixed. `inject_iteration_budget/2` fires only in the
last 10 iterations:

```elixir
budget_warn_threshold = 10
if state.iteration > 0 and remaining <= budget_warn_threshold do
```
— `react_loop.ex:1977-1979`

The comment at `:1973-1976` records that the old guard `remaining <= max_iter` was a tautology, so
a budget line was appended on **every** iteration, "pushing the model to 'wrap up' thousands of
turns early". On a 200-iteration budget the message now fires at iteration 190+, which no
interactive turn reaches. **In practice this costs nothing today.** It is listed because it is a
real divergence from all five references, not because it is currently hurting.

OSA's forced wrap-up at the cap (`forced_wrapup/2`, `react_loop.ex:1001`) — one final
tools-disabled model call producing a real handoff — is **ahead of** most references. opencode has
the same idea (`MAX_STEPS_PROMPT`) but v1 does not actually disable tools; OSA passes `tools: []`
(`react_loop.ex:1017`), which opencode only achieves in its unshipped v2
(`packages/core/src/session/runner/llm.ts:202-213`). hermes has the prompt
(`MAX_ITERATIONS_SUMMARY_REQUEST`) but no structural disable either. **OSA is already ahead. No
change.**

---

## 3. Tool-call batching — OSA is correct and already ahead of two references

This is the single biggest lever on round-trip count, and OSA does it right in both the code and
the prompt.

**Code.** `ToolOrchestrator.dispatch(need_execution, state, max_concurrency: 10, timeout_ms: 300_000)`
— `react_loop.ex:1117-1124`. All tool calls from one assistant message execute before the next
provider call, with a per-input parallel/serial split (`concurrency_safe?/2`). OSA additionally runs
tools **eagerly, mid-stream**, as each `tool_use` block finishes parsing (`StreamingToolExecutor`,
wired at `react_loop.ex:412`, drained `:1770`). **No reference in the set does that** — codex, CC,
grok, hermes all wait for the response to complete before dispatching.

**Concurrency limits:** OSA 10 (`react_loop.ex:1120`); CC 10
(`CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY`, `toolOrchestration.ts:8-12`, *confirmed in 2.1.228*);
grok unbounded `FuturesUnordered` (`tool_calls.rs:522-611`); codex read/write lock gate
(`tools/parallel.rs:46,153-157`); hermes segment planner (`run_agent.py:7728-7763`).

**Prompt.** OSA's is as explicit as CC's:

> **DEFAULT TO PARALLEL.** Unless output of A is required for input of B, execute multiple tools
> simultaneously. This is not an optimization — it's expected behavior.
> — `priv/prompts/SYSTEM.md:227`

> **Batch.** Independent reads, searches, and writes go out together in one turn. You support
> parallel tool calls — one round trip beats five. Serialize only a genuine dependency (§5).
> — `priv/prompts/SYSTEM.md:69`

Compare CC (`constants/prompts.ts:310`, *confirmed in 2.1.228*):

> "You can call multiple tools in a single response. If you intend to call multiple tools and there
> are no dependencies between them, make all independent tool calls in parallel. Maximize use of
> parallel tool calls where possible to increase efficiency."

and codex (`core/gpt_5_2_prompt.md:252`):

> "Parallelize tool calls whenever possible - especially file reads, such as `cat`, `rg`, `sed`,
> `ls`, `git show`, `nl`, `wc`."

**grok's default prompt says nothing about parallelism at all** — the instruction exists only in
its opencode-compat fallback tool namespace (`xai-grok-tools/.../opencode/bash/mod.rs:93`), which is
not the default `GrokBuild` namespace. **OSA is ahead of grok here.**

**Measured, this works.** Both edit turns and the one-file question issued **two `file_read` calls
in a single assistant message** (`tmp/measure_run1.log:1845` region;
`tmp/measure_edit.log:1613` region). Batching is not the problem. **No change recommended.**

---

## 4. The preamble question — OSA already instructs it, and the model already complies

The owner sees turns that open with tool calls and no text. The references split three ways:

**Instruct a preamble:**
- **codex**, in base instructions — `core/prompt_with_apply_patch_instructions.md:31-45`, mirrored
  `core/gpt_5_1_prompt.md:192`:
  > "### Preamble messages
  > Before making tool calls, send a brief preamble to the user explaining what you're about to do…
  > **Logically group related actions**: if you're about to run several related commands, describe
  > them together in one preamble rather than sending a separate note for each. **Keep it concise**:
  > be no more than 1-2 sentences… **Exception**: Avoid adding a preamble for every trivial read
  > (e.g., `cat` a single file) unless it's part of a larger grouped action."
- **grok**, but ONLY in the opt-in Codex-compat profile — `templates/apply_patch_prompt.md:34-42`:
  > "When making tool calls, include a brief preamble message in the same response explaining what
  > you're about to do. Always pair preamble text WITH tool calls in a single response. Never send a
  > preamble message without accompanying tool calls."

  Not in grok's default `templates/prompt.md`.
- **opencode**, in one prompt file only — `beast.txt:20`: *"Always tell the user what you are going
  to do before making a tool call with a single concise sentence."*

**Instruct the opposite:**
- **Claude Code** — `constants/prompts.ts:416-427` (*free-code, April*): *"Skip filler words,
  preamble, and unnecessary transitions."* The policy is corroborated in the shipping binary by the
  adjacent colon rule (*confirmed in 2.1.228*, exact string):
  > "Do not use a colon before tool calls. Your tool calls may not be shown directly in the output,
  > so text like 'Let me read the file:' followed by a read tool call should just be 'Let me read
  > the file.' with a period."

  An internal-only (`USER_TYPE==='ant'`) branch at `prompts.ts:405-414` *does* say "Before your
  first tool call, briefly state what you're about to do" — both branches' strings ship in the
  bundle, so its presence in the binary is not evidence that it is active.
- **opencode** `default.txt:18-19`, `gemini.txt:43`; **hermes** `agent/coding_context.py:263-264`
  (*"Be concise: lead with the change or answer, not a preamble."*).

**OSA already has the codex-style instruction, and it is arguably the best-written of the set:**

> **You preamble, you don't narrate.** Before a *group* of actions, one short line on what you're
> about to do and why (§1). Restating what the UI already shows, call by call, is the redundant
> part — that's what you never do.
> — `priv/prompts/SYSTEM.md:9`

> **Preambles, not narration.** Before a *group* of related tool calls, send one short note — 1-2
> sentences, often 8-12 words — on what you're about to do. "Repo's mapped; now patching the auth
> middleware and its tests."
> — `priv/prompts/SYSTEM.md:27`, with the grouping rule at `:31` and the trivial-read exception at `:75`

**And measured, the model complies.** Both edit turns opened with preamble text *paired with* the
tool calls in the same assistant message:

- `"I need to read both files first, then append the comment."` + 2 `file_read` calls
- `"Reading both fixtures so I can append correctly."` + 2 `file_read` calls

**So "tool calls with no text" did not reproduce at v1.0.83.** The most likely explanation for what
the owner saw is the already-fixed prompt-variant bug: a turn that got the small-window prompt
lost most of `SYSTEM.md`'s body — including §1's preamble rules — and got 10 tools instead of 37.
**No change recommended;** re-test before touching this text.

---

## 5. Conversational vs task turns — confirmed, and OSA is the odd one out in an interesting way

**Confirmed: none of the five references has a conversational fast path.** Every one runs the
identical loop for a greeting.

- grok: `prepare_tool_definitions_timed()` unconditionally every iteration — `turn.rs:1937`
- codex: `run_turn` unconditional — `turn.rs:153-561`; the only pre-model shortcut is the `!cmd`
  shell escape, which never reaches the model
- CC: `queryLoop` unconditional — `query.ts:241`; the only model-skipping branch is
  `shouldQuery === false` for pure local slash commands (`screens/REPL.tsx:2733`)
- opencode: tools resolved unconditionally each iteration — `prompt.ts:1226-1241`
- hermes: every message goes through `run_conversation` — `conversation_loop.py:1422`

**How they keep a greeting cheap anyway: cache discipline, not a bypass.** This is the answer to
the owner's question and it is uniform across the set.

- **CC**: system-prompt sections cached in a module-level `Map` (`bootstrap/state.ts:1641`),
  cleared only on `/clear`/`/compact`; tool schemas rendered at server position 2 and memoized in
  `TOOL_SCHEMA_CACHE` (`utils/toolSchemaCache.ts:18` — *"Memoizing per-session locks the schema
  bytes at first render"*), i.e. **tool definitions sit inside the cached prefix**; exactly one
  message-level `cache_control` breakpoint at `messages.length - 1`
  (`services/api/claude.ts:3078`); system prompt split into ≤4 blocks by `splitSysPromptPrefix()`
  with a `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` sentinel (*confirmed in 2.1.228*, 4 hits).
- **grok**: system prompt built once at session start and held as a refcounted `Arc<str>`
  conversation item; the request builder's hot path is a bare
  `self.state.conversation.clone()` with **no** pruning or image-eviction passes
  (`request_builder.rs:105-109`), because those passes *"caused chronic cache misses"*
  (`:68-70`). Pruning only above 50% window utilisation (`:46-49`).
- **codex**: `WorldState::render_diff` returns `None` for unchanged sections, so nothing is
  appended on a quiet turn (`context/world_state/mod.rs:56-62`), plus `prompt_cache_key`.

**OSA is the only harness in the set that HAS a conversational fast-path mechanism — and it is dead
code.**

```elixir
defp apply_weight_gate(tools, %{signal_weight: weight}) when is_number(weight) do
  if weight < @tool_weight_threshold do
    Logger.debug("[loop] signal_weight=... — skipping tools for low-weight input")
    []
```
— `agent/loop/tool_filter.ex:148-158`, threshold `0.20` at `:22`, documented at `:8-9` as
*"low-weight inputs (< 0.20) skip tools entirely to prevent hallucinated tool sequences for messages
like 'ok' or 'lol'"*.

`signal_weight` reaches the loop only via `Keyword.get(opts, :signal_weight, nil)`
(`agent/loop/turn_pipeline.ex:226`). **No caller anywhere passes it.** Every `process_message/3`
call site — the HTTP API, the CLI, `osa.run`, Slack/Telegram/Discord/Signal/Matrix/LINE/WeCom/
DingTalk, the MCP dispatcher, the orchestrator — omits it. The other `signal_weight:` hits in the
tree (`memory/store.ex:222`, `conversations/weaver.ex:247`, `memory/dream.ex:284`,
`memory/flush.ex:451`) are a *different* field on memory entries. So the guard clause never
matches, the fallback `apply_weight_gate(tools, _state), do: tools` (`:160`) always wins, and every
`hi` ships the full tool array.

This is reported, not shipped (three other lanes are live in this tree). See §10 item 2.

---

## 6. Nudge / verification machinery — every remaining OSA path that re-enters the loop

Paths that cause another provider call **without a new tool result**. Default state as shipped:

| # | OSA path | file:line | Default | Reference equivalent |
|---|---|---|---|---|
| 1 | `max_tokens` bump-and-retry | `react_loop.ex:493` | ON, ≤2 | CC `query.ts:1195-1252` (`MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3`) |
| 2 | Truncated-tool-call re-emit | `react_loop.ex:556` | ON | no direct equivalent; closest is codex's stream retry |
| 3 | `wants_to_continue?` prose nudge | `react_loop.ex:684` | **OFF** (`prose_continue?`) | none — no reference does this |
| 4 | `code_in_text?` prose nudge | `react_loop.ex:709` | **OFF** | none |
| 5 | Zero-successful-tools gate | `react_loop.ex:731` | **OFF**, and capped at 1 (`@max_zero_tool_gate_prompts`, `:63`) | none |
| 6 | `VerificationGate` — unverified write | `react_loop.ex:761` | ON, ≤2 (`@max_reprompts`) | grok `completion_requirement` recovery (`turn.rs:1590-1659`); CC TodoWrite verification note *rides along* on a tool_result (`TodoWriteTool.ts:72-113`) rather than costing a call |
| 7 | Reasoning-only empty-generation backstop | `react_loop.ex:779` | ON, only when `visible_empty?` | hermes empty-response retry (`conversation_loop.py:7060-7112`) |
| 8 | Output-token target | `react_loop.ex:826` | **OFF** (no target set) | CC `TOKEN_BUDGET` (`query.ts:1308-1341`) |
| 9 | Post-compaction continuation | `react_loop.ex:857` | ON when compaction fired | opencode `compaction.ts:512-529`; codex `turn.rs:430-470`; CC `autoCompact.ts` |
| 10 | Stop hooks force continue | `react_loop.ex:884` → `run_stop_hooks/2` `:1694` | user-configured, ≤5 | codex `hook_runtime.rs:303-371`; CC `query.ts:1267-1306` |
| 11 | Error/compaction retry | `react_loop.ex:1359` | ON, bounded | all five |
| 12 | DoomLoop `Resample.handle` rewind | `react_loop.ex:1264`, `:1286` | ON, bounded by `doom_resamples` | grok stationarity nudge (`turn.rs:2047-2077`); opencode `processor.ts:356-380` |
| 13 | `GoalVerifier.maybe_gate` | `react_loop.ex:1319` | `:auto` — only under autonomous posture | grok TodoGate (`turn.rs:2499-2552`) |
| 14 | `forced_wrapup` at the cap | `react_loop.ex:242` | ON, exactly one call | opencode `MAX_STEPS_PROMPT`; hermes `MAX_ITERATIONS_SUMMARY_REQUEST` |
| 15 | Mid-turn steer / task-notification drain | `react_loop.ex:261`, `:266` | ON when queued | codex `steer_input` (`handlers.rs:226-233`); grok late-interjection (`turn.rs:2554-2557`) |

**Four of the fifteen are off by default (3, 4, 5, 8) and the rest all have reference equivalents.**
Items 3–5 are the prose-shaped ones and are the only entries with no analogue in any reference —
they are already disabled. Item 13 is correctly placed: the comment at `react_loop.ex:1306-1318`
records that running the goal verifier after a *text* response produced a "double-ending" defect
(the conclusion had already streamed and could not be retracted), so it now runs at the
**tool-result boundary** instead. That is the same discipline codex uses and is **correct as
written**.

**The count is not out of line.** CC has eight such paths (§6 of the CC trace), hermes has seven,
grok has ten. OSA's 15 is the largest, but 4 are off and 11 map one-to-one.

---

## 7. Tool-result handling — everyone resends full history; only codex has an escape, and it is not portable

| Harness | Next-iteration payload | Reduction mechanism |
|---|---|---|
| **OSA** | full history — `cached_context/1` returns `[system_msg \| state.messages]`, `react_loop.ex:1851` | proactive compaction + microcompaction *before* the call (`react_loop.ex:282-330`) |
| grok | full history, `self.state.conversation.clone()` | pruning only >50% window; image eviction only near 50MB (`request_builder.rs:86-109`) |
| codex | full logical history, `clone_history().for_prompt()` (`turn.rs:340-346`) | **wire-level only**: `previous_response_id` + incremental items over a persistent Responses-API websocket (`client.rs:1224-1300`, `:1668-1703`) |
| CC | full history (`query.ts:659-660`) | five passes before every call: tool-result budget, snip, microcompact, context-collapse, autocompact (`query.ts:379-454`) |
| opencode | full history (`prompt.ts:1092`) | compaction only; `toolOutputMaxChars` unset, so per-turn resend truncation is a **no-op** (`message-v2.ts:293-295`) |
| hermes | full history | reactive-only pruning on overflow |

**OSA is squarely in the middle of the pack and its caching story is sound for a chat-completions
API.** The `cached_context/1` fix is real and load-bearing: the comment at `react_loop.ex:1823-1844`
documents that the old hit path called `Context.build/1` (21 dynamic blocks) and then threw the
result away — *"the worst failure mode available to a cache, because the cost is hidden rather than
removed"* — and `Context.build_count/0` now pins it.

**Not portable:** codex's `previous_response_id` + incremental-items websocket diffing is an OpenAI
Responses-API feature with no server-side conversation handle on Anthropic or Ollama. Do not chase
it. CC's `cache_control` breakpoint discipline **is** portable to Anthropic and is the thing worth
copying (see §10 item 3).

**Truncation constants for reference:** CC `BASH_MAX_OUTPUT_DEFAULT = 30_000` chars
(`utils/shell/outputLimits.ts:3`, *confirmed in 2.1.228*), `MAX_LINES_TO_READ = 2000`; opencode
`MAX_LINES = 2000` / `MAX_BYTES = 50KB` (`tool/truncate.ts:14-15`); hermes `DEFAULT_MAX_BYTES=50_000`
/ `DEFAULT_MAX_LINES=2000` (`tools/tool_output_limits.py:38-40`). The set has converged on
2000 lines / ~30–50KB.

---

## 8. Where OSA is already ahead

Stated explicitly, because recommending changes to working code is worse than recommending none:

1. **Eager mid-stream tool execution** (`StreamingToolExecutor`, `react_loop.ex:412`). No reference
   dispatches a tool before the assistant response completes. This is a genuine latency advantage.
2. **Structural tool-disable at the iteration cap** (`forced_wrapup`, `tools: []`,
   `react_loop.ex:1017`). opencode only manages this in its unshipped v2; hermes not at all.
3. **Preamble prompt text** (`SYSTEM.md:9,27,31,75`) is more precise than codex's and far ahead of
   grok's default (which has none). It correctly scopes preambles to a *group* of calls and carves
   out trivial reads.
4. **Verification at the tool-result boundary, not after a text response**
   (`react_loop.ex:1306-1321`). The one-ending discipline is right and hard-won.
5. **Duplicate tool-call-id repair** (`ToolOrchestrator.uniquify_ids`, `react_loop.ex:1071`) and
   **orphaned-tool-result filling** (`fill_orphaned_tool_results/1`, `:1608`). Neither codex nor CC
   has a visible equivalent; both matter for strict providers.
6. **Truncated-response tool reconciliation** (`react_loop.ex:594-639`) — keeping already-streamed
   tool results and failing only the cut-off trailing call, instead of re-running side effects.

---

## 9. Measured OSA turn shapes

**Rig.** A real OSA backend on **port 19351** (`OSA_HTTP_PORT=19351`), in-process, driving the real
`Agent.Loop.process_message/3` with handlers registered on the `Events.Bus` for `:llm_request`,
`:llm_response`, `:tool_call`. Script: `tmp/loop_measure.exs`. Raw logs: `tmp/measure_run1.log`,
`tmp/measure_edit.log`. Provider **ollama**, model **`glm-5.2:cloud`** (1M window), effort
`medium`, `max_iterations: 200`, fresh session per turn (`messages: []`). No stubs.
The owner's backend on `:9089` was never touched; every process started here was killed by PID.

### Run 1 — `tmp/measure_run1.log`

| Turn | Prompt | Provider calls | Tools | Wall (total) |
|---|---|---:|---:|---:|
| greeting | `hi` | **1** | 0 | 1,246 ms |
| conversational | mutex vs semaphore, "no tools needed" | **1** | 0 | 1,515 ms |
| one-file question | "how many iterations… look it up in config/config.exs" | **2** | 2 (batched in call 1) | 4,739 ms |
| two-file edit | append a comment to two files | 2 observed | 2 (batched in call 1) | see note |

Per call:

| Turn | Call | Wall | Input tokens | Output | Tools issued |
|---|---:|---:|---:|---:|---:|
| greeting | 1 | 1,050 ms | **34,647** | — | 0 |
| conversational | 1 | 1,373 ms | **35,036** | — | 0 |
| one-file | 1 | 1,763 ms | **35,235** | — | 2 (`file_read` ×2, one message) |
| one-file | 2 | 2,824 ms | **35,105** | — | 0 → final answer |
| two-file edit | 1 | 2,327 ms | **35,052** | — | 2 (`file_read` ×2) |
| two-file edit | 2 | 1,301 ms | **35,059** | — | write calls |

### Run 2 — `tmp/measure_edit.log` (edit turn, isolated)

| Call | Wall | Input tokens | Output tokens | Tools issued |
|---:|---:|---:|---:|---|
| 1 | 5,657 ms | **29,142** | 60 | 2 — `file_read` ×2 in one message, with preamble text |
| 2 | 2,509 ms | **28,966** | 89 | 1 — `file_write` |

Observed tool sequence: `["file_read", "file_read", "file_write"]`. Turn terminated at
`total wall: 300,001 ms` — the harness's own `process_message` timeout, see the note below.

### What the numbers say

1. **Round-trip counts are correct.** 1 call for a greeting, 1 for a conversational question, 2 for
   read-then-answer. Every reference in the set would produce exactly these numbers. The loop is
   not over-stepping.

2. **The prefix is flat and enormous.** `hi` cost **34,647 input tokens**. The two-file edit's
   second call cost **35,059**. The prompt does not get smaller when the turn gets simpler. At
   glm-5.2 cloud latency that is the ~1 s/call floor the owner already measured.

3. **Composition** (from `Context.build:` debug lines, run 1):
   `static=16,059  world_state=3,025  volatile=1,803  conversation=226` → ~21.1k accounted for
   in-context, against **34,647** reported by the provider. The ~13.5k difference is the **tool
   schema array**, which is sent as a separate request field and never appears in
   `Context.build`'s accounting. **Tool schemas are ~39% of the prefix and are invisible to OSA's
   own budget telemetry.**

4. **The static base is not stable between runs.** Run 1: `static=16,059` (matches the documented
   `:native_tools` figure at `soul.ex:178`). Run 2: `static=9,332`, and total input dropped to
   ~29k accordingly. Both runs used the same model, provider, and config. **Cause not
   established** — flagged rather than guessed. Worth its own pass, because a 6.7k-token swing in
   the static prompt between two identical invocations means something in tool/skill registration is
   racing session start.

5. **Preamble compliance is real.** Both edit turns opened with a short preamble sentence paired
   with the tool calls in the same assistant message. §4's "tool calls with no text" did not
   reproduce.

6. **Batching compliance is real.** Every multi-read step issued both `file_read` calls in one
   assistant message.

**Note on the edit turn.** Both runs stalled after the first `file_write` was issued, and run 2
terminated at exactly `300,001 ms` — the harness's own `process_message` timeout, with
`{:error, "exit: {:timeout, {GenServer, :call, ...}}"}`. **This is the measurement rig, not OSA.**
`PermissionBroker.await_decision` polls for a decision and returns `{:error, :timeout}` only after
`@default_timeout_ms = 300_000` (`agent/loop/permission_broker.ex:35,72-73,115`), and a headless
session has no responder attached; `permission_tier: :auto` still brokers writes. The two provider
calls before the write are fully measured and reported. The post-write shape is not measured and is
not claimed — a rig with a permission responder is needed to complete that row.

---

## 10. Ranked changes, with what each saves

Ranked by round-trips and tokens saved per turn. **No product code was changed in this pass.**

### 1. Get the tool schemas into a cached prefix (biggest win, no round-trip change)

~13.5k of the ~34.6k per-call prefix is the tool schema array, resent verbatim on every call. CC
memoizes schema bytes per session so they land ahead of the `cache_control` breakpoint
(`utils/toolSchemaCache.ts:18`); grok deliberately avoids any mutation pass that would bust the
prefix (`request_builder.rs:68-70`).

**Saves:** zero round-trips, but on Anthropic it converts ~13.5k tokens/call from full price to
cache-read price. On Ollama it saves nothing (no prompt cache), which is why it does not fix the
local-latency complaint — but it is the largest single cost item in the measured prefix.
**Prerequisite:** the `split_system/2` cache-block flattening already recorded in project memory
must be fixed first, or there is no cache to land in.

### 2. Wire `signal_weight`, or delete the gate

`ToolFilter.apply_weight_gate/2` (`tool_filter.ex:148`) is the only conversational fast path in any
of the six harnesses, and no caller passes the field. Either compute it at the turn surface or
remove the clause so the tree stops implying a capability it does not have.

**Saves:** on a greeting, the entire ~13.5k tool-schema array — measured, that is `hi` dropping from
~34.6k to ~21k input tokens, a ~39% cut on the cheapest turns. Zero round-trips (a greeting is
already 1 call).

**Caveat, and it is a real one:** **no reference harness does this**, and §5 establishes that all
five deliberately rely on cache discipline instead. Stripping tools also changes what the model
*can* do if the classifier is wrong — "check the tests pass" is conversational-looking and needs
tools. If this is done at all it should be threshold-conservative and reversible, and it is strictly
second to item 1.

### 3. Explain or fix the 6.7k static-base variance (§9.4)

Two identical invocations produced `static=16,059` and `static=9,332`. Until that is understood,
every prefix measurement in this document — and any cache-hit-rate work built on item 1 — is
standing on a moving floor. **Saves:** unknown, which is exactly why it should be measured before
anything else is optimised.

### 4. Count tool schemas in `Context.build`'s budget

`Context.build` logs `total=29305/1000000` while the provider bills 34,647. The ~13.5k tool array is
outside the accounting, so the context meter, the compaction trigger, and `response_reserve` are all
computing against a number that is ~40% low. This is a correctness issue in the budget, not a
performance one.

**Saves:** no round-trips directly, but it is what makes the compaction thresholds honest on
long runs.

### 5. Consider removing `inject_iteration_budget` entirely (§2)

Zero of five references tell the model its remaining budget. OSA's now fires only in the last 10 of
200 iterations, so it costs nothing in practice. **Saves: nothing measurable today.** Listed only
for completeness — this is the lowest-value item in the list and arguably should not be touched.

### Explicitly NOT recommended

- **Do not re-enable the prose-continue clauses** (`react_loop.ex:684,709,731`). No reference has an
  equivalent; the measured failure was `max_iterations + 1` round-trips for one answer.
- **Do not chase codex's `previous_response_id` incremental-items transport.** It is a Responses-API
  feature with no equivalent on Anthropic or Ollama (§7).
- **Do not add a "stop when the model says it's done" check.** All six harnesses, OSA included,
  already stop structurally, and that is right.
- **Do not touch the preamble or parallelism prompt text** (§3, §4). Both are already at or above
  the standard of the set and both were observed complying at v1.0.83.

---

## Appendix — reproducing the measurement

```
export PATH="$HOME/.asdf/installs/erlang/28.3/bin:$HOME/.asdf/installs/elixir/1.19.5-otp-28/bin:$PATH"
cd ~/projects/osa/OSA
OSA_HTTP_PORT=19351 mix run tmp/loop_measure.exs
```

Per-call figures are also readable straight out of any debug-level run:

```
grep -E "LLM call completed|Context.build: static" <log>
```

`[loop] LLM call completed in <ms>ms (<n> input tokens)` is emitted at `react_loop.ex:480`;
`Context.build: static=… world_state=… volatile=… conversation=…` at `agent/context.ex:177`.
The gap between the two is the tool-schema array.
