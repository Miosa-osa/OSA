# Prime Agent: what is real, what OSA should take

**Date** 2026-08-16 · **Subject** [PrimeIntellect-ai/prime-agent](https://github.com/PrimeIntellect-ai/prime-agent)
@ `06e4a19dc902382dbb90b67fbe4ed53c3f7b99b2` · **Clone** `/home/miosa/projects/research/prime-agent-src`
· **Blog** <https://www.primeintellect.ai/blog/prime-agent> (2026-08-05)

Two companion repos were read at the same commit-pinned state:

| repo | clone | SHA | why |
|---|---|---|---|
| `nano-rlm` | `research/nano-rlm-src` | `878f4980` | the 5k-line distillation of the same thesis; often the better thing to copy |
| `arc-agi-3-prime-agent` | `research/arc-agi-3-prime-agent-src` | `398d4dd6` | the benchmark artifacts behind the blog's headline number |

All three are MIT. Every `file:line` below is into those clones.

---

## 0. Licence — and the provenance that matters more

`LICENSE` is MIT, with two copyright lines:

```
MIT License

Copyright (c) 2025 Mario Zechner
Copyright (c) 2026 Prime Intellect
```

**MIT permits porting code into OSA** with attribution — no copyleft, no patent clause, no
field-of-use restriction. Nothing in this document is blocked on licence.

The second copyright line is the more important fact. **Prime Agent is a hard fork of
[badlogic/pi-mono](https://github.com/badlogic/pi-mono)** — commit `8b5abc6a5 fork pi-mono as
prime agent`, 2026-05-07. Of 4,511 commits, **529 are Prime's**; the rest are upstream `pi`.
The README says so (`README.md:113`: *"Our agent and TUI is built on top of `pi`"*), the docs say
so (`docs/index.md:3`: *"It began as a hard fork of pi-mono"*), and it matters because the parts
the blog markets are not evenly distributed across that boundary. Provenance is labelled
throughout below; where a subsystem is inherited `pi`, the interesting prior art is `pi`, not
Prime.

A second, cheaper caveat: `system-prompt.ts:126` calls `buildRlmPrompt` **"the trained
buildRlmPrompt prefix"**. Prime co-trains models against this exact prompt via `prime-rl`. Their
prompt is a *trained artifact*. Copying its text into OSA buys the wording, not the behaviour.

---

## 1. The benchmark claims: not substantiated by the published artifacts

The blog states:

> "Our best results use Opus 5 in Prime Agent to achieve **95.5% RHAE Best@1**, which surpasses
> the ARC reported human expert baseline of 95.4%."
>
> "Across three runs, we find that Prime Agent consistently performs well [95.0, 95.2, 95.5] and
> **99.97% Best@3** with all 183/183 levels complete."

Checked against `arc-agi-3-prime-agent-src`. Findings, in descending order of severity:

**1. "RHAE" is never defined.** It appears five times in the entire repo — three as a
`rhae_percent` *value* in `results/results.json`, once as a table header, once in
`results/index.html:36`. There is no definition, no formula, no derivation, and **no scoring
code**. The 485 lines of Python are a game broker, a client, and an action validator; none of
them computes a score. `rhae_percent` is a hand-entered number in a JSON file. It cannot be
recomputed from any artifact in the repo.

**2. `Best@1` is the maximum of three runs.** The repo's own numbers
(`results/results.json:16,228,440`) are **95.24 / 94.99 / 95.50**. The blog reports the highest
as "Best@1". Two of the three fall below the 95.4 human baseline, and the margin at the top is
0.1 points with no error bars and no seed count beyond n=3.

**3. The repo and the blog headline different statistics, and the repo's is worse.**
`results.json:11` sets `"median_run": "run-1"` and `README.md:12` says *"`run-1` is the median by
RHAE and is the run reported above"* — i.e. **95.24%, below the 95.4% baseline**. The repository
reports the median and does not beat the human baseline; the blog reports the max and says it
does.

**4. RHAE penalises actions, which makes the framing incoherent.** `run-2` completed
**183/183 levels and won 25/25 games** — a perfect run — and scored the **lowest** RHAE (94.99).
So the run the blog cites for "all 183/183 levels complete" in support of Best@3 is the same run
that scores worst on the headline metric. Whatever RHAE measures, level completion is not it.

**5. "99.97% Best@3" appears nowhere in the repo.** No artifact, no code, no mention.

**6. The shipped runner contradicts the shipped results.** `arc3_local_broker.py:23-24`:

```python
# Paper-matched protocol: 500 actions per game, at most 20 actions per agent call.
MAX_ACTIONS = 500
```

`MAX_ACTIONS` is a hard per-game cap (`:113,121,123`). Yet `results.json` records single games at
**985, 1024, 1084, 2635, 3544 and 5000 actions** (7–9 of 25 games exceed 500 in every run). The
runner as published cannot produce the results as published.

**7. The runner is not the reported configuration.** `game-prompt.txt:1` instructs the agent to
use `/workspace/fixed_broker_client.py` — **a file that does not exist in the repo**; `run.sh:19`
copies `broker_client.py` instead. Pinned to `prime-agent v0.3.3`, long superseded.

**8. The headline benchmark disables the repo's central thesis.** `AGENTS.md:17` and
`game-prompt.txt:1` both instruct: *"Do not call RLM, create agents, use agent_message"*. The RLM
recursion that the blog presents as the core abstraction is **switched off** for the number the
blog leads with. The README is candid that the agent is not what carried the run
(`README.md:22`): *"The agent is unmodified Prime Agent. What makes the run is the prompt plus the
protocol."*

**Verdict.** Do not cite any of these numbers. What is verifiable is that Prime ran Opus 5 through
a harness on 25 ARC-AGI-3 games at ~$1,000/run and published per-game level counts. The headline
metric is undefined and uncomputable from the release, the statistic changes between the blog and
the repo in the direction that flatters, and the runner is inconsistent with the results. This
says nothing about whether the *harness design* is good — which is what the rest of this document
is about, and which has to be judged from the source.

---

## 2. What is real in the source vs framed in the blog

| blog claim | verdict |
|---|---|
| "one built-in tool: `ipython`" | **Real and literal.** `core/tools/index.ts:47`: `allToolNames = new Set(["ipython"])`, with a regression test pinning it. |
| RLM: "subagent delegation as function calls" | **Real, but weaker than it sounds.** `await rlm(...)` returns an *admission handle* and **never returns an answer**. It is fire-and-forget spawn, not a function call. |
| Continual Harness CRUD | **Real, and larger than advertised** — the agent can also rewrite it unmediated from Python, and it runs *automatically* every 25 turns. |
| Agent messaging restricted to parent/sibling/child | **Real and structurally enforced.** `core/agent-messages.ts:310-328`. The best-engineered thing in the repo. |
| Append-only JSONL with branch/fork | **Real,** with caveats (no fsync; nothing written until the first assistant message). |
| "asynchronous compaction via a spawned garbage-collector agent" | **False.** No GC agent exists. `grep -rni garbage` returns zero relevant hits. It is a deferred, **inline, blocking** `completeSimple()` on the session's own model. |
| Autonomous mode with goals, heartbeats, budgets | **Real,** and honestly documented. Budgets are mechanical; goal *completion* is not. |
| "self-improving" | **Framing.** It improves its own *notes*. There is no verification subsystem of any kind (§4). |

A useful size check on the "everything is programmatic" framing: the entire Python RLM runtime is
**1,534 lines** (`prime-agent-runtime/src/rlm/`: `harness.py` 820, `__init__.py` 346,
`mcp_base.py` 331, `skill.py` 37). `packages/coding-agent/src/` is **5.4 MB**, of which
`modes/` (TUI, daemon, RPC, ACP) is 2.7 MB. The RLM is a thin bridge over a conventional
TypeScript agent. That is not a criticism — it is the correct architecture — but it is not the
architecture the blog describes.

---

## 3. The single-tool thesis, measured

This is the part OSA has been circling, so it gets numbers.

**What the model sees.** `core/tools/index.ts:46-47`:

```ts
export type ToolName = "ipython";
export const allToolNames: Set<ToolName> = new Set(["ipython"]);
```

Pinned by `test/suite/regressions/4428-remove-legacy-pi-mono-tools.test.ts:31`. At the fork base,
`pi` had seven (`read | bash | edit | write | grep | find | ls`); Prime deleted five outright in
`4a7a55c9a make ipython default and remove legacy tools (#3)`. `bash.ts` and `edit.ts` survive on
disk but are never registered.

**Measured prefix** (chars/4 approximation, stated as such):

| | Prime Agent | nano-rlm | OSA (current) |
|---|---|---|---|
| declared tools | **1** | **1** | **22** |
| tool schema JSON | 753 ch ≈ **188 tok** | ~700 ch ≈ **175 tok** | ≈ **7.3k tok** |
| base system prompt | 8,941 ch ≈ **2.2k tok** | 4,500 ch ≈ **1.1k tok** | `SYSTEM.md` 44,964 B ≈ **10.4k tok** |
| skills/metadata block | ~6,365 ch ≈ 1.6k tok | — | (deferred tools via `tool_search`) |
| **static prefix** | **≈ 4.0k tok** | **≈ 1.3k tok** | **≈ 17.7k tok** |

OSA's own `docs/research/harness-internals.md:30-44` recorded 21.15k (10.85k schemas) at v1.0.96;
the 17.7k/7.3k figure is the current measurement. Either way **Prime's prefix is ~4-5x smaller
and nano-rlm's is ~13x smaller.**

**But the saving is not where the thesis says it is.** Prime's own `system-prompt.ts:12` claims
*"Tool schemas carry tool descriptions outside the prompt body"* — the code does the opposite.
`IPYTHON_CONTROL_PROMPT` (`core/prompts/rlm.ts:14-33`) is ~2,900 chars of usage doctrine that
*used to be* tool descriptions. Against `pi`'s seven tools (3,242 chars of `description:`
literals ≈ 810 tok), **the net schema saving is only ~600 tokens.** The real win is categorical,
not arithmetic: there is no per-tool JSON-schema surface and no tool-name namespace the model has
to route over. OSA's 7.3k is large because OSA has 22 tools with rich schemas, not because
schemas are inherently expensive.

**What capability costs instead.** 24 host-request types
(`core/agent-session.ts:8761-8863`) reached from Python over a Jupyter comm
(`HOST_COMM_TARGET = "host.request"`, `core/kernel/index.ts:56`). Python→host on IOPub, host→Python
on the **control** channel — necessary because a blocking `await host_request(...)` inside a cell
occupies shell. That detail is correct and well-documented (`docs/rlm-runtime.md:151-160`).

**MCP is the single best idea here** (`docs/mcp-integrations.md:5-8`):

> "Consistent with Prime Agent's single-tool design, MCP integrations are **not** exposed as new
> agent tools. Each integration is a Python-backed skill that the model imports and calls from the
> IPython kernel."

Discovery happens at runtime (`await linear.list_tools()`), so an MCP server with 40 tools costs
**zero prefix tokens**. This is directly relevant to OSA's in-flight MCP auto-discovery.

### What breaks — and this is the honest cost sheet

- **Permissioning: there is none.** Not "a weaker one" — none. There is no approval prompt, no
  allowlist, no path policy, no OS sandbox, and no settings key for any of it. Grepping
  `permission|approval|trust|allowlist|sandbox|confirm` across `settings-manager.ts` and
  `docs/settings.md` returns nothing. The tell is that **there is no `--yolo` flag and no
  `--dangerously-skip-permissions` equivalent — because there is nothing to bypass.** The kernel is
  `spawn(python, ["-m","ipykernel_launcher", ...])` at `core/kernel/index.ts:723` with the host's
  full inherited environment (API keys, SSH agent socket, cloud creds), same uid, full network.
- **`%%bash` is unparsed.** `core/tools/ipython.ts:649-650` rewrites the magic line and executes;
  `ipython-cell-code.ts:21` is `body: code.slice(match[0].length)`. Nothing inspects the script.
- **Path policy does not exist.** `core/tools/path-utils.ts` `resolveToCwd` does `~` expansion then
  `if (isAbsolute(expanded)) return expanded;`. No `relative()`/`startsWith(root)` check anywhere.
- **The fork's security delta is negative.** `pi` shipped narrow, individually-hookable tools;
  its two gating examples (`examples/extensions/permission-gate.ts`,
  `protected-paths.ts:11-14`) key on `toolName === "bash"` / `"edit"` and are **now inert as
  shipped**, because neither tool is registered. A `tool_call` handler can now only see
  `event.input.code` — an opaque Python string. To gate anything it would have to parse arbitrary
  Python. **Prime removed the structure that made gating possible and did not replace it.** The
  `extensions.md:22-23` feature list still advertises "Permission gates" and "Path protection" as
  things *you could write*.
- **Auditability is essentially gone.** The only file-write signal is a display-MIME diff that the
  `edit` skill *voluntarily* emits (`skills/edit/src/edit/__init__.py:48-59`). A plain
  `Path("x").write_text(...)`, `sed -i`, or `shutil.rmtree` produces **no diff, no event, no
  record** — the transcript holds only the cell source. "What did this agent change?" is answerable
  only by reading and simulating every cell.
- **No per-cell timeout.** `ExecuteOptions` (`core/kernel/index.ts:174-183`) has no `timeoutMs`. A
  `while True:` cell runs until a human intervenes. The Python side of a host request awaits
  **unbounded** (`prime-agent-runtime/src/rlm/__init__.py:140`).
- **Cancellation is a lie by 1 second.** Abort sends `interrupt_request`, waits
  `KERNEL_ABORT_GRACE_MS = 1000`, then marks the execution aborted **while the cell keeps running**.
  The next call raises `KernelBusyAfterInterruptError` and the user is asked to wait or kill —
  killing loses the entire namespace. One tool = one kernel = one serialized queue, so a stuck cell
  blocks *everything*.
- **Output truncation is head-first and lossy.** `DEFAULT_MAX_OUTPUT_CHARS = 65536` applied as
  `stdout.slice(0, maxChars)` (`:1079`). The **tail is discarded and unrecoverable** — a test run
  whose failures land after 64 KB of noise leaves the model nothing. `pi`'s
  `output-accumulator.ts` spills to a temp file and reports `fullOutputPath`; the kernel path
  doesn't use it. **OSA's `tool_result_storage.ex` (40 head + 20 tail lines, spill to disk) is
  strictly better.**
- **Streaming and partial failure are fine.** `onStream` → `onUpdate` works; partial stdout is
  returned on abort with the traceback appended.
- **Two channel bugs worth naming.** Outbound kernel messages are HMAC-signed
  (`core/kernel/index.ts:448-462`) but **inbound signatures are never verified** — `decode`
  (`:464-478`) skips frame `i+1`, the signature, and there is no `timingSafeEqual` in the file.
  Separately, `display_data` MIME payloads are a **second unauthenticated kernel→host channel**
  (`:186-192`, `:1096-1108`): any cell can emit `application/vnd.prime-agent.diff+json` and make
  the host record a file edit that never happened.
- **The capability system exists and is unwired.** `core/kernel/index.ts:65-141` defines
  `HostRequestContext` (requestId, generation, `AbortSignal`, `isCurrent()`), a brand symbol, and a
  `WeakSet` provenance registry. `agent-session.ts:8762` returns plain unary lambdas and `:1346`
  calls `handler(payload)` with **one argument**. Its only consumers are tests. Consequence: **no
  request id, no staleness check, no cancellation** — a host request fired by cell N keeps mutating
  session state after cell N aborts, which is exactly what `isCurrent()` was built to prevent.

The docs are honest about the trust model, to their credit (`docs/rlm.md:143`):

> "The IPython kernel runs model-generated Python and project commands with the worker's operating-system
> permissions. It is a durable control environment, **not a security sandbox**."

**The conclusion for OSA is not "the single-tool thesis is wrong."** It is that Prime bought its
4x prefix reduction by deleting the permission broker, the path policy, and the audit trail —
three things OSA has and Prime does not. The prefix saving is real; the price is the entire safety
surface. §6 proposes how to take one without the other.

---

## 4. Self-verification: Prime Agent has none, and OSA is ahead

This was the highest-value question going in. The answer is unambiguous.

**Goal completion is a model self-report with one precondition.**
`agent-session.ts:3148-3165`, the entire completion path:

```ts
private _completeGoalFromHost(): GoalState {
    if (!this._goalState.objective || this._goalState.status === "idle") {
        throw new Error("cannot complete goal because this thread has no goal");
    }
    const goal = this._goalWithAccountedWallClock();
    this._clearQueuedGoalContexts();
    this._setGoalState({ ...goal, active: false, status: "complete", lastReason: "Goal achieved", …});
```

The only check is *that a goal exists*. No gate command, no diff inspection, no test run, no second
model. Every safeguard is prose in the re-injected continuation prompt (`core/goals.ts:212-229`):

> "Before marking the goal complete, audit the current state against every requirement in the
> objective. Do not rely on intent, partial progress, memory of earlier work, or a plausible final
> answer as proof of completion."

That is a string the model is free to ignore. The `goal` SKILL.md states the design plainly:
*"the harness keeps continuing the goal until the completion call arrives."* The loop is externally
bounded; the success criterion is not.

**A repo-wide search for a verification subsystem** (`verifier|judge|critic|grader|reviewer|red-green|
test.validity`) returns, in full: OAuth PKCE code verifiers; a doc example naming a subagent
`'api-reviewer'`; the auto-refine reviewer (which judges whether a *memory write* is warranted, never
work correctness); and one prompt string. **There is no reviewer subagent, no test-validity check,
no red-green enforcement, no critique loop, and no independent confirmation of any claimed result.**

The autonomous continuation prompt (`core/autonomous.ts:45-46`) points at a component that is not
in this repo:

> "No human input is available in autonomous mode. Continue working until the host evaluator,
> verifier, or configured autonomous limits stop the run." … "the verifier/evaluator decides
> completion when configured gates pass."

Inside this codebase the only thing behind the word "verifier" is a shell-exit-code loop. The real
referent is the external RL environment (`prime-rl` / `verifiers`) Prime runs this agent inside.
**Prime Agent does not verify itself; Prime's training infrastructure verifies it.** That is a
coherent strategy for a lab that owns both — and it is not available to OSA.

**Two things that could be mistaken for verification, and are worth taking anyway:**

1. **Gates are user-authored shell commands, and the agent cannot touch them.**
   `AgentAutonomousGateConfig` is `{commands?: string[], maxRetries?: 3, timeoutMs?: 5min}`
   (`core/autonomous.ts:20-24`), default `commands: []`. Success is **exit code 0**, nothing else
   (`:322`). Gates are configurable **only via CLI flags** (`--autonomous-gate`, `main.ts:602-633`);
   the in-session `/autonomous` accepts only `on|off|status`. **The agent has no exposed surface to
   author or edit its own gates.** That authorship boundary is the single best safety decision in
   the repo.

2. **The no-op detector** (`core/autonomous.ts:294-311`). Before rerunning a *failed* gate, the host
   snapshots the worktree (`git status --porcelain -z -uall` + `diff --binary HEAD` + a sha256 over
   untracked files, `:374-444`); if it matches the previous failure's snapshot it refuses to rerun:

   > "The autonomous gate was not rerun because the workspace has not changed since this failure.
   > Edit source files, tests, or a blocker artifact before attempting to finish again."

   This kills "run the tests again and hope". It proves *something changed* — not that the change
   was relevant.

Neither addresses OSA's actual failure mode: a model writing a real red→green test that measures
the wrong property. **Prime Agent has no answer to that.** If the gate is `npm run check` and the
model weakens a test to make it pass, nothing in this codebase notices. Their README says so
without spin (`README.md:88`): *"A passed gate checks only what that gate verifies; reaching a
limit does not imply task success."*

**OSA is materially ahead here.** `lib/optimal_system_agent/agent/loop/goal_verifier.ex` (1,874
lines) is an independent read-only skeptic panel — N fresh subagents instructed to *refute* goal
completion, strict-majority-refute aggregation, fail-closed on uncertainty, `:off_track` distinct
from `:incomplete`. That has no counterpart in Prime Agent. **Do not weaken it to look more like
theirs.**

---

## 5. Compaction, sessions, daemon — the corrections

**Compaction is not async and there is no GC agent.** `_checkCompaction` →
`_runAutoCompaction` (`agent-session.ts:8167`) → `_performCompaction` (`:7170`) → `compact()`
(`core/compaction/compaction.ts:745`) → `completeSimple(model, …)` (`:596`) — the session's own
model, same process, `await`ed, turn stalled. The only asynchrony is *scheduling*: the `compact`
skill sets a flag. `agent-session.ts:2846`:

> "Compaction would abort the run executing the requesting cell, so `compact.run` only schedules
> it; `_checkCompaction` consumes the request at the turn boundary."

This is **structurally the same as OSA's** inline compaction, not better.

**But the denominator is right, and OSA's is not.** `compaction.ts:229-233`:

```ts
export function shouldCompact(contextTokens: number, contextWindow: number, settings: CompactionSettings): boolean {
	if (!settings.enabled) return false;
	if (contextWindow <= 0) return false;
	return contextTokens > contextWindow - settings.reserveTokens;
}
```

`contextWindow` comes from `this.model?.contextWindow` (`agent-session.ts:8037`), sourced from an
auto-generated per-model catalog (`packages/ai/src/models.generated.ts`, 1,163 entries with real
200000 / 400000 / 1000000 values). **This is the fix for OSA's hardcoded-128k-denominator bug.**

Their version has its own defect, in the opposite direction: `reserveTokens: 16384` is *absolute*,
so on a 1M-window model auto-compaction fires at 983,616 tokens — 98.4% full — and then keeps
~20k, discarding ~96% of context in one shot. And `generateSummary` (`:556`) sends *all* of
`messagesToSummarize` in one request **with no input token budget**, while its sibling
`generateBranchSummary` does exactly that budgeting (`branch-summarization.ts:294-297`). The only
guard is `TOOL_RESULT_MAX_CHARS = 2000` (`compaction/utils.ts:83`), which is carrying the whole
design. **Take the per-model denominator; make the reserve fractional, not absolute.**

**The genuinely novel idea: the kernel as out-of-band memory.** Compaction rewrites the transcript;
the kernel is a separate process, so Python state is untouched. They exploit this deliberately.
`compaction.ts:498-499` injects into the summarization prompt:

> "Note: the IPython kernel keeps running after this summary — every Python variable, import, and
> helper you defined stays available. The cells that defined them won't appear above, so record in
> the summary any names worth remembering so you reuse them instead of redefining them."

And post-compaction `_notifyKernelStateAfterCompaction` (`agent-session.ts:6967-7013`) **probes the
live namespace** (bounded, abortable) and appends a hidden message:

```
<ipython_state>
Your IPython kernel persisted through compaction; all variables, imports, and helpers you defined
remain available. These names are still defined: …
</ipython_state>
```

Across *session resume* the kernel is gone, so they snapshot it with `dill`, per-variable so one
unpicklable object is skipped rather than aborting the whole snapshot, 256 MB cap, atomic
`os.replace` (`core/kernel/state-snapshot.ts:5-11,78,91-107`). The file's own header comment is the
most honest sentence in the repo:

> "The kernel is otherwise spawned fresh on resume, leaving the model believing it still has access
> to variables/imports it defined earlier."

Cost: a full `dill` of the user namespace runs 1.5 s after **every successful cell**
(`DEFAULT_SNAPSHOT_DEBOUNCE_MS = 1500`), non-adaptive. With a large DataFrame in scope that is a
real recurring tax.

**Sessions.** JSONL, `id`/`parentId` tree, `~/.prime/agent/sessions/<id>.jsonl`, version 3.
Steady state is O(1) `appendFileSync`. Two real defects: **nothing is written to disk at all until
the first assistant message arrives** (`session-manager.ts:1456-1462`, and that `hasAssistant`
check is an O(N) `.some()` on every append); and **session files are never fsynced**, while three
lesser journals are (`command-recovery-journal.ts:178,204,211`, `cron-jobs.ts:1557`,
`orphan-process-journal.ts:38`). IDs are 8-char, unique only within a file. `/fork` writes a new
file carrying `parentSession` as a bare path string — one-directional, breaks if the source moves.
**OSA's transcript durability work is on the right side of this comparison; their JSONL is not a
model to copy wholesale.**

**Daemon.** Entirely Prime's own (~19.5k lines, 111 commits). Unix socket only, `0700` dir /
`0600` socket, **no authentication** — `handleConnection` sets `authenticated: true`
unconditionally (`daemon-supervisor.ts:1012-1024`), and the docs admit the boundary is filesystem
permissions (`docs/daemon.md:120`). "Recoverable workers" is thinner than it sounds: on crash,
in-flight operations are **not replayed** — `catalog.markInterrupted` appends a visible marker
(`daemon-catalog-process.ts:210-219`):

```
<prime_agent_worker_interrupted>
The isolated session worker stopped during in-flight work. The saved transcript was recovered, but
uncertain model, tool, bash, or child-agent work was not replayed. Inspect external side effects
before continuing.
</prime_agent_worker_interrupted>
```

Telling the model in-band that its own history has a hole is the right call and worth stealing.
"Reattach with event replay" is oversold: `createDaemonReplayInfo` (`daemon-protocol.ts:1107-1165`)
returns `"complete"` only when nothing was missed; **every genuine gap yields
`event_replay_not_available`**. It is snapshot-plus-sequence-fence, not a replay log.

---

## 6. Ranked: what OSA should take

Ranked by (value to OSA) × (confidence it is real) ÷ cost.

### 1. MCP servers as a runtime namespace, not declared schemas — **take this first**

**What.** `docs/mcp-integrations.md:5-8`. MCP tools are never declared to the model; the model
discovers them at runtime (`await linear.list_tools()`, `help(linear.list_issues)`).

**Why OSA.** OSA's MCP auto-discovery is in flight. Declaring N discovered MCP tools as schemas
would blow the 7.3k budget open with no ceiling. This makes the cost **zero prefix tokens**
regardless of server count.

**Lands in.** `lib/optimal_system_agent/mcp/client/tool_bridge.ex` and
`lib/optimal_system_agent/tools/prompt_assembler.ex`. OSA already has the mechanism —
`tool_search` / deferred tools. This is the same idea taken one step further: don't declare MCP
tools at all; expose one `mcp_call(server, tool, args)` plus a discovery call.

**Cost.** Low. One extra round-trip before first use of an MCP tool; models are demonstrably fine
with discover-then-call. **Permissioning stays intact** because the call still goes through an OSA
tool with a real schema. This is the single-tool win *without* the single-tool price.

### 2. Per-model context window as the compaction denominator

**What.** `compaction.ts:229-233` + `agent-session.ts:8037` + a generated catalog
(`models.generated.ts`, 1,163 entries).

**Why OSA.** OSA compacts against a hardcoded 128k denominator, firing ~9x too early on 1M-context
models — a known, measured defect.

**Lands in.** `lib/optimal_system_agent/agent/loop/compaction_thresholds.ex` and
`lib/optimal_system_agent/agent/loop/context_window.ex`.

**Cost.** Low-medium: someone must own a model catalog and keep it current. **Do not copy their
absolute `reserveTokens: 16384`** — make the reserve fractional, or it fires at 98% on a 1M model
and throws away 96% of context in one pass.

### 3. The autonomous no-op detector

**What.** `core/autonomous.ts:294-311, 374-444`. Worktree snapshot (`git status --porcelain -z
-uall` + `diff --binary HEAD` + sha256 over untracked); refuse to rerun a failed gate if the
workspace is byte-identical to the previous failure.

**Why OSA.** Cheap, mechanical, model-proof. It cannot be argued with. It does not solve the
wrong-property problem, but it kills an adjacent one — burning turns rerunning an unchanged check.

**Lands in.** `lib/optimal_system_agent/agent/loop/goal_verifier.ex` (as a pre-check before
spending a skeptic panel) or `lib/optimal_system_agent/verification/`.

**Cost.** Very low. ~70 lines. Highest value-per-line in this document.

### 4. Kernel/state-as-out-of-band-memory, and the honesty markers

**What.** Three related patterns: (a) tell the summarizer that some state survives compaction and
to record pointers to it (`compaction.ts:498`); (b) after compaction, **probe the live state** and
inject `<ipython_state>` listing what is actually still there (`agent-session.ts:6967-7013`);
(c) on crash recovery, append `<prime_agent_worker_interrupted>` telling the model its own history
has a hole.

**Why OSA.** OSA resumes with a synthetic continuation and does not tell the model what survived
versus what was reconstructed. (b) in particular is the good bit — it is a *probe*, not a promise.
OSA has an analogous surface: files written, shell state, `use_context` refs.

**Lands in.** `lib/optimal_system_agent/agent/compact_restore.ex` and
`lib/optimal_system_agent/agent/loop/context_collapse.ex`; the crash marker in
`lib/optimal_system_agent/runtime/session_teardown.ex`.

**Cost.** Low. Mostly prompt-side, plus one bounded probe with a timeout.

### 5. The gate-authorship boundary, stated as a rule

**What.** Gates are shell commands supplied **only** from outside the session
(`main.ts:602-633`); `/autonomous` accepts `on|off|status` and nothing else. The agent has no
surface to author or edit its own success criterion.

**Why OSA.** OSA has `overdrive` (no-prompts autonomous). This is the invariant that keeps such a
mode honest, and it is worth writing down explicitly rather than holding by accident.

**Lands in.** `lib/optimal_system_agent/agent/permission_mode.ex` and the `overdrive` config path
— as an assertion plus a test, not new machinery.

**Cost.** Near zero. Likely already true in OSA; the value is making it a checked invariant.

### 6. Monotonic-restriction for project-scoped settings

**What.** `docs/settings.md:73`: *"Project settings can only further restrict telemetry: they
cannot re-enable a global opt-out."* Prime applies this to exactly one setting.

**Why OSA.** OSA has a known bug: an untrusted project `.osa/settings.json` grants permissions
ungated. "Project scope may only narrow, never widen" is the right general rule, and Prime states
it cleanly even though they apply it in only one place.

**Lands in.** `lib/optimal_system_agent/permissions.ex` and the settings merge path.

**Cost.** Low. It is a merge-policy change plus tests. Note this fixes an OSA bug; it is not a
feature port.

### 7. Progressive skill disclosure with a Python-callable contract

**What.** `formatSkillsForPrompt` (`core/skills.ts:450-481`) puts only `<name>/<type>/<description>/
<location>` in the prefix; bodies load on demand. Python-backed skills additionally expose a typed
callable.

**Why OSA.** OSA already does progressive disclosure via `tool_search`. The *new* part is that a
skill can be an executable contract rather than instructions. Worth studying, not urgent.

**Lands in.** `lib/optimal_system_agent/tools/prompt_assembler.ex`, `soul/tools_section.ex`.

**Cost.** Medium. Real design work; overlaps existing OSA machinery.

### 8. Two small operational borrowings

- **`min-release-age=7`** in `.npmrc` + a matching dependabot cooldown (`AGENTS.md:48-51`) — a
  cheap supply-chain defence against compromised fresh releases. Applies to OSA's JS/TUI deps.
- **`nano-rlm`'s compaction trigger** (`nano-rlm-src/src/rlm/engine.py:549`) fires on
  `usage.prompt_tokens` — **the provider's own reported count from the previous response** — not on
  a local estimate. That removes an entire class of estimator drift. Strictly better than either
  Prime Agent's or OSA's approach and it is ~5 lines.

---

## 7. What OSA should **not** take

**The single-tool architecture, as they built it.** The 4x prefix saving is real, but they paid for
it by deleting the permission broker, the path policy, and the audit trail — and the deletion is
not incidental, it is *structural*: once every action is an opaque Python string, there is nothing
left to gate. OSA's `permission_broker.ex` and path policy are worth more than 13k tokens. Take
item 1 instead: it captures most of the prefix win at none of this cost.

**Their compaction shape.** Inline blocking `completeSimple` is what OSA already does. The absolute
`reserveTokens` is worse than a fractional threshold. No input budget on the summarization request
is a latent failure. Take only the denominator.

**Their session persistence.** No fsync; nothing written until the first assistant message;
8-char IDs unique only per file; fork parent as a bare path string. OSA just fixed transcript
discard — do not regress toward this.

**Unbounded self-rewriting harness state.** The Continual Harness has **no size cap, no diff
review, and no user confirmation**; `applyRefinementProposal` writes and hot-swaps the live system
prompt in the same block (`agent-session.ts:7930-7935`). It runs **automatically every 25 assistant
turns** by default (`settings-manager.ts:883-897`, `enabled ?? true`, `turnInterval … : 25`), gated
only by a second LLM asked whether a memory write is warranted. And the whole `/refine` path can be
bypassed: `prime-agent-runtime/src/rlm/harness.py` lets any cell call
`create_prompt_note(..., global_=True)` straight into `~/.prime/agent/harness/harness_state.json`
with no review, no history, no rollback record, and no user visibility. Their own code comments
acknowledge the race (`agent-session.ts:7903`). If OSA ever builds this, the disk write must be the
gated path, not one of two.

**Their `base_system_prompt` "immutability".** The guard at `refinement.ts:671-673` is an id-string
check and is cosmetic; real immutability is structural (harness state can only *append*). Meanwhile
`core/resource-loader.ts:864-872` will silently let a checked-out repo replace the entire system
prompt:

```ts
private discoverSystemPromptFile(): string | undefined {
    const projectPath = join(this.cwd, CONFIG_DIR_NAME, "SYSTEM.md");
    if (existsSync(projectPath)) {
        return projectPath;
    }
```

`CONFIG_DIR_NAME = ".prime/agent"` (`config.ts:507`). No trust prompt, no confirmation. The same
loader auto-discovers `.prime/agent/extensions/` (`resource-loader.ts:657`) and executes it as
TypeScript. **`cd` into a hostile repo and it owns your prompt and runs your code.** This is the
same class of bug as OSA's untrusted-`.osa/settings.json` hole — which is the useful lesson: it is
a *class*, not a one-off. Fix it at the loader, for every project-scoped resource, not per-setting.

**Their benchmark presentation.** §1. Independent of the code, the pattern — undefined metric,
best-of-3 labelled `Best@1`, a 0.1-point margin, and a repo that quietly reports the median — is a
thing to recognise, not imitate.

---

## 8. What I could not determine

- **Whether the single-tool design actually helps capability.** No controlled comparison exists —
  not in the repo, not in the blog. Prime's models are trained against this prompt
  (`system-prompt.ts:126`, "the trained buildRlmPrompt prefix"), so their results conflate harness
  and training. Whether an untrained frontier model does better with one `ipython` tool than with
  22 schemas is **an open empirical question**, and OSA can answer it cheaply for itself with
  `code_sandbox` + `shell_execute` on a bench slice. Nothing here settles it.
- **What RHAE is.** Undefined in the repo; not derivable from the artifacts; not stated in the blog.
- **How the reported ARC runs were actually produced**, given `MAX_ACTIONS = 500` versus 5,000-action
  games and a `fixed_broker_client.py` that does not exist in the repo.
- **Real-world behaviour of any of this.** Nothing was executed. No `prime-agent` process was
  started, no port bound, no daemon socket opened. Every claim above is read from source at the
  pinned SHAs.
- **Whether `nano-rlm` or `prime-agent` is the better study object for OSA long-term.** `nano-rlm`
  is 5k lines, MIT, and expresses the same thesis at 1.3k tokens of prefix with markedly cleaner
  code (its ACP mode even refuses `session/load` on the honest grounds that *"an arbitrary live
  Python kernel cannot be reconstructed after the ACP process exits"*). If OSA does run the
  single-tool experiment, `nano-rlm` is the cheaper reference.

---

## Appendix: provenance table

| subsystem | origin | evidence |
|---|---|---|
| `tools/ipython.ts`, `core/kernel/**`, `prime-agent-runtime/` | **Prime** | `9f17320f0 (#2)`, `8bfef71c4 (#16)`, 41 kernel commits |
| removal of pi's 7 tools | **Prime** | `4a7a55c9a (#3)` |
| `prompts/rlm.ts` | **Prime** | `b396363a8 add model agnostic rlm system prompt (#4)` |
| `core/refinement/`, `core/goals.ts`, `core/autonomous.ts`, `core/cron-jobs.ts` | **Prime** | zero commits before fork |
| `core/agent-messages.ts`, `modes/daemon/**` | **Prime** | `2c30b48b4 (#207)`, `3ad60e982 (#74)` |
| `core/compaction/**` | **pi**, 7 Prime commits | mechanism inherited |
| `core/session-manager.ts`, fork/branch | **pi** | inherited |
| `core/skills.ts` | **pi**, 3 Prime commits | inherited |
| `system-prompt.ts`, `bash.ts`, `edit.ts`, `path-utils.ts`, `output-accumulator.ts`, `beforeToolCall`, all `examples/extensions/*` | **pi** | inherited |
