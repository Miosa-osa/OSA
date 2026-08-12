# Submit path: opencode

**Question:** what happens between the user pressing enter and the first token appearing?

**Source traced:** `sst/opencode`, branch `dev`, commit **`959c8bd4981fe838df102ddb7a7974e3117e92c6`**, committed **2026-08-12T10:32:23-05:00** (`docs: fix provider display name and PAT typos (#42034)`).

The clone at `~/projects/research/opencode-src` already existed at `550d1ffd` (2026-08-10), i.e. two days stale and 1 commit behind `origin/dev`. It was fetched and reset to `origin/dev` before reading. Every file:line below is against `959c8bd`.

---

## 0. Read this first: there are two prompt paths in the tree

opencode is mid-rewrite. Both paths are in the repo and it is easy to draw wrong conclusions by reading the wrong one.

| | **v1 — LIVE** | **v2 — in progress** |
|---|---|---|
| Location | `packages/opencode/src/session/*` | `packages/core/src/session/*` |
| Entry | `SessionPrompt.prompt` | `V2Session.prompt` |
| Is it what the TUI calls? | **Yes** | No |
| System prompt | rebuilt per turn | frozen per session in SQLite |

Proof the TUI is on v1: the TUI submits `{sessionID, agent, model, variant, parts: [...]}`
(`packages/tui/src/component/prompt/index.tsx:1091-1112`). That matches v1's
`SessionPrompt.PromptInput` (`packages/opencode/src/session/prompt.ts:1499-1520`, note `parts:`),
not the v2 payload `{id, prompt, delivery, resume}`
(`packages/server/src/handlers/session.ts:139-150`).

So **§1–§3 below describe what actually ships today (v1)**. §4 describes the v2 design, which
matters because it is where opencode is deliberately moving and it is the part most worth stealing.

---

## 1. The sequence — user presses enter to first token (v1, live)

### Phase A — in the TUI process, before anything leaves the machine

1. **`prompt.submit` keybinding fires** — `packages/tui/src/component/prompt/index.tsx:349-355` and `:569`, dispatching `submit()`.
2. **Reentrancy guard** — `packages/tui/src/component/prompt/index.tsx:930-943`. A boolean `submitting` latch, not a lock; costs nothing.
3. **IME flush + cheap local rejections** — `:947-969`. Reads `input.plainText`, then a run of pure in-memory guards (disabled, workspace creating, autocomplete open, empty input, no agent, `exit`/`quit`/`:q`, no model selected). All synchronous, all reads of already-loaded state.
4. **Workspace liveness check** — `:973-989`. Reads `sync.session.get()` and `project.workspace.status()` from the local reactive store, populated at startup. No I/O.
5. **(new sessions only) `await sdk.client.session.create(...)`** — `:999-1012`. This is the **only awaited network call before the prompt is sent**, and only on the first message of a session.
6. **Paste expansion + part assembly** — `:1019-1050`. Pure string/array work over extmarks already in memory.
7. **Fire-and-forget POST** — `:1108-1130`:
   ```ts
   sdk.client.session.prompt({ sessionID, ...selectedModel, agent, model, variant, parts: [...] },
     { throwOnError: true }).catch(...)
   ```
   **Not awaited.** `void`-style dispatch with a `.catch` that only raises a toast.
8. **Composer cleared immediately** — `:1131-1137`. `input.extmarks.clear()`, `setStore("prompt", {input:"", parts:[]})`, `props.onSubmit?.()`. This happens in the same synchronous tick as step 7, so the next SolidJS render frame shows an empty composer regardless of what the server is doing.

**What the user sees while waiting.** opencode paints *nothing optimistic*. There is no locally-inserted user bubble — a grep for `optimistic` across `packages/tui/src` and `packages/core/src` returns zero hits. The composer empties (local, instant); the user's message bubble and the "working" state appear only when the server echoes them back over SSE. The busy state is derived, not stored:

```ts
status(sessionID) {
  ...
  const last = messages.at(-1)
  if (!last) return "idle"
  if (last.role === "user") return "working"
  return last.time.completed ? "idle" : "working"
}
```
`packages/tui/src/context/sync.tsx:584-593`. So "working" starts the moment the user message row lands via `message.updated` (`packages/tui/src/context/sync.tsx:322-347`). opencode gets away with no optimistic paint because that round trip is a localhost POST plus one SQLite insert.

The spinner itself is `packages/tui/src/routes/session/index.tsx:1667` (`Thinking` / `Thinking: <title>`) plus per-tool spinners at `:2180`, `:2309`, `:2380`.

### Phase B — server side, before the provider call

9. **HTTP handler** — `packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts:295-309`. `requireSession` then `promptSvc.prompt(...)`. Note the response is held open for the whole turn; the TUI does not care because it never awaited it.
10. **`SessionPrompt.prompt`** — `packages/opencode/src/session/prompt.ts:1052-1071`:
    - `sessions.get` (SQLite read)
    - `revert.cleanup(session)`
    - **`createUserMessage(input)`** — `:635-...`. Resolves agent + model, writes the user message row, and resolves attachment parts (file reads **only if the user attached files**). This write is what unblocks the TUI's "working" state.
    - `sessions.touch`
    - then `loop({sessionID})`.
11. **`runLoop`** — `packages/opencode/src/session/prompt.ts:1081-1341`. Per iteration:
    - `status.set(sessionID, {type:"busy"})` — `:1092`
    - `MessageV2.filterCompactedEffect(sessionID)` — `:1096`, reloads history from SQLite each iteration
    - loop-exit check on `lastAssistant.finish` — `:1113-1140`. **Exits when the model returned text with no tool calls.** There is no auto-continue after a text-only answer.
    - `title(...)` forked on step 1 — `:1140-1141`, `Effect.forkIn(scope)`, off the critical path
    - overflow compaction check — `:1160-1167`
    - `agents.get`, `SessionReminders.apply` — `:1169-1183`
    - **assistant message row written before the provider call** — `:1185-1201`. This is what pins the spinner on.
    - `processor.create(...)` — `:1219`
    - **`SessionTools.resolve(...)`** — `:1226-1241` (see §2)
    - `summary.summarize` forked on step 1 — `:1253`, off critical path
    - `plugin.trigger("experimental.chat.messages.transform")` — `:1255`
    - **system prompt assembly, four pieces in parallel** — `:1257-1262`:
      ```ts
      const [skills, env, instructions, mcpInstructions, modelMsgs] = yield* Effect.all([
        sys.skills(agent), sys.environment(model), instruction.system(),
        sys.mcp(agent, session.permission), MessageV2.toModelMessagesEffect(msgs, model),
      ])
      ```
    - `handle.process({system, messages, tools, model, ...})` — `:1274-1288` → provider stream.
12. **Request compile** — `packages/opencode/src/session/llm/request.ts:57-78` merges the base prompt text with the assembled pieces and deliberately collapses to **exactly two system messages**; `:148` and `:183` resolve + sort tools; `:208-213` drops wholly-denied tools. Caching markers applied at `packages/opencode/src/provider/transform.ts:359-406` (`applyCaching`), called at `:484`.

### Phase C — first token to screen

13. Provider chunk → `text-delta` → published on the in-process event bus, **not persisted**. The schema is explicit about it:
    ```
    // Stream fragments are live-only; Text.Ended is the replayable full-value boundary.
    ```
    `packages/schema/src/session-event.ts:208-219`. `Text.Delta` is declared without the durable `...options` spread that `Text.Started`/`Text.Ended` carry, so it never reaches SQLite. Deltas are accumulated in a plain in-memory `Map` and only the coalesced final string is written on `Text.Ended` (`packages/core/src/session/runner/publish-llm-event.ts:91-118`, v2 equivalent; v1 does the same via its processor).
14. Event → **SSE**, one long-lived stream opened once at TUI startup — `packages/server/src/handlers/event.ts:20-49` (`text/event-stream`, `X-Accel-Buffering: no`, 15s heartbeat).
15. TUI reduces the event into the reactive store — `packages/tui/src/context/sync.tsx:322-347` — and SolidJS re-renders the affected node only.

**Net: zero disk and zero network hops on the per-token path.**

---

## 2. What is assembled per turn vs once at startup

### Once, at module load (free forever)

- **All base system prompts.** `packages/opencode/src/session/system.ts:6-15` imports `anthropic.txt`, `beast.txt`, `gpt.txt`, `codex.txt`, `gemini.txt`, `kimi.txt`, `trinity.txt`, `meta.txt`, `default.txt` as bundler text imports. Variant selected by model id at `:27-45`. **No per-request disk read.**
- **All tool descriptions.** `packages/opencode/src/tool/read.ts:7` `import DESCRIPTION from "./read.txt"`, same for `edit`, `grep`, `glob`, `write`, `task`, `skill`, `webfetch`, `websearch`, `question`, `lsp`, `todo`, `apply_patch`, `plan`, `shell/prompt`. No `readFile` anywhere in tool-description paths.

### Once, lazily, then cached for the process lifetime

- **Built-in tool registry construction**, including the filesystem glob for user-defined tools (`Glob.scanSync("{tool,tools}/*.{js,ts}")`, `packages/opencode/src/tool/registry.ts:179-181`) and dynamic `import()` at `:187`, all inside an `InstanceState.make` (`:116-249`) → a `ScopedCache` keyed by directory (`packages/opencode/src/effect/instance-state.ts:26-52`).
- **Skill discovery + frontmatter parse** — `packages/opencode/src/skill/index.ts:259-287`, same `InstanceState` mechanism. Glob patterns at `:24-26`.
- **MCP connect + `tools/list`** — see §3.
- **Model catalog** — `packages/core/src/models-dev.ts`. Load order at `:216-230` is *disk cache → compiled-in snapshot → network*, memoized with `Effect.cachedInvalidateWithTTL(populate, Duration.infinity)` at `:232`, refreshed by a background fiber on a 60-minute schedule at `:253-256`. Disk cache at `~/.cache/opencode/models.json` with a 5-minute TTL and an flock'd atomic write (`:165-224`). **Never fetched on a turn.**
- **Everything the TUI needs to render.** Bootstrap fires providers, agents, config, sessions, commands, LSP status, **MCP status**, formatters, session status, provider auth and VCS all at mount, non-blocking — `packages/tui/src/context/sync.tsx:500-556`.

### Per turn

- The four system-prompt fragments (`sys.skills`, `sys.environment`, `instruction.system`, `sys.mcp`) — `packages/opencode/src/session/prompt.ts:1257-1262`.
- `sys.environment` is pure string interpolation over already-resolved state — `packages/opencode/src/session/system.ts:63-99`. Note `Is directory a git repo` comes from `ctx.project.vcs`, a precomputed field, **not a git subprocess**. It does contain `Today's date: ${new Date().toDateString()}` at `:78`, which sits inside the cached region and therefore breaks the prompt cache once per day at midnight. This is the one sloppy bit of v1 and v2 fixes it (§4).
- `instruction.system()` walks for instruction files — `packages/opencode/src/session/instruction.ts:296-315`. If `config.instructions` contains `http(s)://` entries it performs **live HTTP GETs with a 5s timeout, blocking the provider call** (`:152-161`). Nobody has this configured by default.
- Tool resolution and schema conversion — §3.
- History reload from SQLite each iteration.

---

## 3. Tools and MCP — how 12 servers stay off the hot path

This is the part most directly relevant to OSA.

**MCP connection is lazy-once, cached forever, never re-done per turn.**
The whole fleet is connected inside a single `InstanceState.make` initializer —
`packages/opencode/src/mcp/index.ts:492-529`, with `Effect.forEach(..., {concurrency: "unbounded"})`.
`InstanceState` is a `ScopedCache` with `capacity: Number.POSITIVE_INFINITY` and a lazy lookup
(`packages/opencode/src/effect/instance-state.ts:26-52`). Every public MCP method begins with
`yield* InstanceState.get(state)` — `tools()` `:668`, `clients()` `:611`, `instructions()` `:616`,
`status()` `:592`.

Consequences:

- **First turn of a process pays the full connect cost**, awaited, bounded by `DEFAULT_TIMEOUT = 30_000` per server (`packages/opencode/src/mcp/index.ts:38`, applied at `:226`, resolved at `:286`/`:359`). With 12 servers connected concurrently that is *max*, not *sum* — but a single slow server still gates the first turn.
- **Every turn after that is a pure cache read.** No connect, no `tools/list`, no round trip.
- Tool definitions are captured once at connect (`:391`, stored at `:523`) and refreshed **push-based** off the `notifications/tools/list_changed` handler in a background watcher (`:442-472`). Failure flips a server to `{status:"failed"}` (`:408-414`) rather than breaking the turn — a 5-state machine at `:100-107` (`connected | disabled | failed | needs_auth | needs_client_registration`).
- The TUI's MCP status badge (`packages/tui/src/routes/session/footer.tsx:13-14`) reads the same cached state via a startup fetch, so the display costs nothing per turn.

**But: opencode does NOT keep MCP tools off the per-request prompt.** By default every tool of every connected server is advertised on every request — `packages/opencode/src/session/tools.ts:390-490` iterates all of `mcp.tools()` with no allowlist, and `mcp.tools()` gates only on `status === "connected"` (`packages/opencode/src/mcp/index.ts:675`). Filtering happens *last*, by name, and only removes **wholly denied** tools — `packages/opencode/src/session/llm/request.ts:208-213` via `Permission.disabled` (`packages/opencode/src/permission/index.ts:204-214`). Conversion cost is paid even for tools that get dropped.

The one real deferral mechanism is **code mode**, behind `flags.experimentalCodeMode`:
`packages/opencode/src/session/tools.ts:388` returns *before* adding any MCP tool, and instead the
servers are described as a text catalog inside a single `execute` tool's description —
`packages/opencode/src/tool/registry.ts:275-284`, `packages/opencode/src/tool/code-mode.ts:210`.
That is structurally the same idea as OSA's deferred-MCP virtualization. **OSA already ships this on
by default; opencode has it behind an experimental flag.** OSA is ahead here.

**Schema conversion is half-memoized.**
- `ToolJsonSchema.fromSchema` is `WeakMap`-memoized on the schema object — `packages/opencode/src/tool/json-schema.ts:6,9-10,19`. Built-in tool `parameters` objects live in `InstanceState`, so this is a hit after turn one.
- `ProviderTransform.schema` is **not** memoized — `packages/opencode/src/provider/transform.ts:1514`, re-walking and sanitizing every tool schema on every request.
- The v2 registry does this properly: `packages/core/src/tool/tool.ts:76-89` caches the built `ToolDefinition` in a per-tool `Map<string, ToolDefinition>`, so `definition(name, tool)` is a reference return after first use. `packages/core/src/tool/registry.ts:106-122` (`materialize`) is then a pure `Map` walk with a wildcard permission filter — no allocation of schemas at all.

**Skills are prompt, not tools.** One `skill` tool exists; the catalog is rendered into an
`<available_skills>` block (`packages/opencode/src/session/system.ts:101-113`) and the skill *body*
is only read when the tool is called (`packages/opencode/src/tool/skill.ts:22-60`). Only names +
descriptions ride the per-request prompt.

**Sizes, for scale.** Base system prompts: `anthropic.txt` **8,212 bytes** (~2.1k tokens);
largest is `gemini.txt` at 15,372. All 15 tool descriptions together: **15,073 bytes** (~4k tokens).
So opencode's static prefix is on the order of **6–8k tokens**, against OSA's established ~47k.

---

## 4. The v2 design — the part worth stealing

v2 is not live yet, but it is where the interesting engineering is, and it is a direct answer to
OSA's problem.

**The system prompt is rendered once per session and frozen in SQLite.**
`packages/core/src/session/runner/llm.ts:183`:
```ts
const initialized = yield* SessionContextEpoch.initialize(db, loadSystemContext(agent), session.id)
...
const system = initialized ?? (yield* SessionContextEpoch.prepare(db, events, loadSystemContext(agent), session.id))
```
`packages/core/src/session/context-epoch.ts:80-87` — `initializeOnce` short-circuits on `exists()`
and never evaluates the context Effect at all. On later turns `prepareOnce` (`:40-79`) loads the
stored row and, when nothing changed, returns `{baseline: stored.baseline}` — **the exact same bytes
as last turn, read from a table, not re-rendered.**

**Drift is delivered as a conversation message, not by mutating the prefix.**
`packages/core/src/session/context-epoch.ts:71-77` publishes a `SessionEvent.ContextUpdated`
appended at the tail. The date source is defined with a `baseline` renderer *and* an `update`
renderer for exactly this:
```ts
load: DateTime.nowAsDate.pipe(Effect.map((date) => date.toDateString())),
baseline: (date) => `Today's date: ${date}`,
update: (_previous, date) => `Today's date is now: ${date}`,
```
`packages/core/src/system-context/builtins.ts:34-39`. Full replacement of the baseline happens only
after a compaction (`context-epoch.ts:63-70`).

**The `<env>` block is built once at layer construction**, then served as a constant —
`packages/core/src/system-context/builtins.ts:16-33`, `load: Effect.succeed(environment)` at `:28`.
It deliberately contains no date.

**Three cache breakpoints, on by default.** `packages/llm/src/cache-policy.ts:23-38`:
```
AUTO = { tools: true, system: true, messages: "latest-user-message" }
```
Applied in `compile` at `packages/llm/src/route/client.ts:345`, only for
`anthropic-messages` / `bedrock-converse` (`cache-policy.ts:44`), lowered at
`packages/llm/src/protocols/anthropic-messages.ts:234-251` with `ANTHROPIC_BREAKPOINT_CAP = 4`.
The reasoning is written down in the file header: the latest-user-message breakpoint exists so that
**every intra-turn tool round-trip re-reads the whole conversation from cache instead of re-prefilling
it.** OpenAI gets an explicit `promptCacheKey` derived from the session id instead
(`packages/core/src/session/runner/llm.ts:204,207`).

**Auth is a SQLite read, network only near expiry** —
`packages/core/src/integration.ts:385-402`, refresh only when the credential is inside a 5-minute
expiry window.

**Where v2 is *not* clean.** `snapshots.capture()` sits directly on the critical path, immediately
before the stream — `packages/core/src/session/runner/llm.ts:217`. It shells out to real `git`
against a shadow git dir (`packages/core/src/snapshot.ts:129-142` → `git.tree.capture`), and its
result is only needed to diff *after* the turn. It is best-effort (`:142` swallows failures and
yields `undefined`) and skipped entirely when the project is not a git repo or `snapshots: false`
(`:124-127`), so it is forkable — they just have not forked it. **This is the same mistake OSA makes
with `fs_checkpoint`, so it is not a stick to beat OSA with; it is a shared bug.**

---

## 5. Fast path for a turn that needs no tools?

**There is none, in either version.** Tools are always materialized and always sent. The only
tool-free request shape is the terminal one: when the agent's configured step limit is reached,
`isLastStep` sends zero tools plus `toolChoice: "none"`
(`packages/core/src/session/runner/llm.ts:203,212-214`; v1 equivalent at
`packages/opencode/src/session/prompt.ts:1178,1284-1287`).

What opencode does instead is make tool assembly *cheap enough not to need a fast path*: memoized
schemas, a cached registry, a small tool set, and an MCP fleet resolved once per process. The lesson
is not "add a fast path", it is "make the slow path not cost anything".

---

## 6. Diff against OSA, as written

### 6a. What OSA does that opencode does not

**0. Not a difference: the HTTP hand-off.** OSA's `POST /sessions/:id/message`
(`lib/optimal_system_agent/channels/http/api/session_routes.ex:888`) is already fire-and-forget —
`SessionManager.process_message_async/3`
(`lib/optimal_system_agent/runtime/session_manager.ex:227`) starts a supervised Task and returns 202
immediately, exactly like opencode's `promptAsync`
(`packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts:311-329`). The blocking is
*internal*: that Task makes one long `GenServer.call` into the session's `Loop`
(`lib/optimal_system_agent/agent/loop.ex:202`, timeout `:agent_turn_timeout_ms`, default 24h), so
every other call to that Loop queues behind the turn. That costs concurrency, not
time-to-first-token. **Do not chase this as a latency fix.**

**1. OSA writes the whole conversation to disk before the turn starts.**
`lib/optimal_system_agent/agent/loop.ex:1149` calls `maybe_rewind_checkpoint(state, message)` as the
*first* statement of the handler, synchronously.
`lib/optimal_system_agent/agent/loop/checkpoint.ex:396-437`:
- `safe_fs_head()` → a synchronous `GenServer.call(FSCheckpoint.Server, :head)`
  (`lib/optimal_system_agent/agent/loop/checkpoint.ex:654-655`,
  `lib/optimal_system_agent/fs_checkpoint/server.ex:85-89`, 5s default timeout) whose handler
  (`lib/optimal_system_agent/fs_checkpoint/server.ex:440-444`) **shells out to `git rev-parse HEAD`
  in the shadow repo, uncached, every turn**
- `sanitize_messages(messages)` — an O(N) walk over the entire history
- `Jason.encode!(entry)` of the **entire message list**
- `File.write!` + `File.rename!`
- `prune_rewind` — directory listing and deletes

This is O(conversation size) on every single turn, before any work. opencode's nearest equivalent
(`snapshots.capture`) is a git tree write that does not touch the transcript at all.

**2. OSA rebuilds the system prompt every iteration and then throws it away.**
This is the single most costly structural finding.
`lib/optimal_system_agent/agent/loop/react_loop.ex:1822-1848`:
```elixir
defp cached_context(state) do
  cache_key = {state.plan_mode, state.session_id, Process.get(:osa_memory_version, 0), state.channel}
  case Process.get(:osa_system_msg_cache) do
    {^cache_key, cached_system_msg} ->
      full = Context.build(state)                                  # <- full rebuild
      case full do
        %{messages: [_system | rest]} -> %{full | messages: [cached_system_msg | rest]}   # <- discarded
        ...
```
The cache *hit* branch still calls `Context.build(state)` in full and then **replaces the freshly
built system message with the cached one**. Every block in
`Context.gather_dynamic_blocks/1` (`lib/optimal_system_agent/agent/context.ex:468-501`, **21 blocks**)
is computed, the world-state diff is run, the budget fitter runs, `estimate_tokens_messages` walks
the whole conversation (`:83`) — and the result is dropped. opencode v2's equivalent
(`SessionContextEpoch.initialize`) does not even *evaluate* the context Effect when the epoch already
exists (`packages/core/src/session/context-epoch.ts:80-87`).

**3. OSA has genuinely more per-turn gates.** `TurnPipeline.run`
(`lib/optimal_system_agent/agent/loop/turn_pipeline.ex:48-93`) runs nine named steps before dispatch:
cancel-flag clear, overrides, turn-count, `Limits.check`, cache clears, `UserPromptSubmit` hook,
prompt-injection guard, `prepare_turn`, `route_genre`. Then `prepare_turn` (`:211-252`) additionally
persists the user turn to the transcript store, mints a turn id, emits `turn_start`, and runs
`compact_and_refresh_tokens`. Then `dispatch_message` (`:1696-1743` in `loop.ex`) may enter a whole
plan-mode ReactLoop of its own before the real turn starts. opencode's v1 pre-LLM work is
`sessions.get` + `revert.cleanup` + `createUserMessage` + `touch`
(`packages/opencode/src/session/prompt.ts:1055-1058`) — four steps.

**4. OSA performs memory recall three separate times per turn.**
- `Memory.Coordinator.recall_block/3` during `MessageHandler.build_messages`
  (`lib/optimal_system_agent/agent/loop/message_handler.ex:437`,
  `lib/optimal_system_agent/agent/memory/coordinator.ex:113-156`) — ledger read + `EpisodicStore.recall`
  (JSON files) + `SkillLibrary.find_skills`
- `Memory.Synthesis.search_relevant/1` as an async prefetch
  (`lib/optimal_system_agent/agent/loop/react_loop.ex:341-352`), then
  **`Task.yield(memory_task, 2_000)` blocks the turn for up to two seconds**
  (`:361`), and on timeout the *same work is redone inline* via `maybe_inject_memory/2` (`:366,1850`)
- `Context.recall_scored` → `Memory.recall_hybrid/2` inside every `Context.build`
  (`lib/optimal_system_agent/agent/context.ex:1040-1044`, `lib/optimal_system_agent/memory.ex:307`)

Each bottoms out in a `GenServer.call(Memory.Store, …, 5_000)`
(`lib/optimal_system_agent/memory.ex:68,88`) or a file/DB scan. opencode awaits nothing comparable —
it has no memory-recall step on the submit path at all.

**5. OSA scans the whole skill library twice per context build, and reads skill bodies inline.**
`SkillLibrary.list_skills/0` does `File.ls!` of the skills directory plus a `File.read` +
`Jason.decode` **per skill file** (`lib/optimal_system_agent/store/skill_library.ex:129-140`), and it
is reached twice — once via `Memory.Coordinator` (`coordinator.ex:141`) and again via
`learned_skills_block` (`lib/optimal_system_agent/agent/context.ex:1556-1560`). Separately,
`skills_block` calls `SkillLoader.load_body(skill[:path])` — **a file read per triggered skill**
(`lib/optimal_system_agent/tools/registry.ex:557-560`). opencode's equivalent is
`InstanceState`-cached, scanned once per process
(`packages/opencode/src/skill/index.ts:259-287`), and skill *bodies* are read only when the `skill`
tool is actually called (`packages/opencode/src/tool/skill.ts:22-60`).

**6. Two uncached `File.read`s on every single `Context.build`.**
`bootstrap_block/0` reads `USER.md` and `BOOTSTRAP.md` with no cache
(`lib/optimal_system_agent/agent/context.ex:953,963,976`). Plus `ProgressLedger.summarize/1` reads the
session ledger markdown per turn (`lib/optimal_system_agent/agent/loop/message_handler.ex:463`,
`lib/optimal_system_agent/agent/progress_ledger.ex:219`), and `GoalTracker.tick_turn/1` does a
`Jason.encode!` + `AtomicFile.write` of the goal sidecar **every turn**
(`lib/optimal_system_agent/agent/loop/goal_tracker.ex:307,790,807`). opencode's `<env>` equivalent is
a process-lifetime constant (`packages/core/src/system-context/builtins.ts:16-33`).

**7. Tool schemas are normalized and serialized from scratch on every provider request, twice.**
- `Providers.Registry.chat_stream/3` runs `sanitize_tool_schemas/1` →
  `SchemaNormalizer.normalize_tools/1` over **every tool, unmemoized**, on every request
  (`lib/optimal_system_agent/providers/registry.ex:276,434-448`,
  `lib/optimal_system_agent/tools/schema_normalizer.ex:87`) — including on every fallback re-entry.
- `format_tools/1` rebuilds the `{"name","description","input_schema"}` maps per request
  (`lib/optimal_system_agent/providers/anthropic.ex:1361-1369`; OpenAI-compatible equivalent at
  `lib/optimal_system_agent/providers/openai_compat.ex:765`).
- Then `ImageBudget.run/2` **`Jason.encode_to_iodata!`s the entire request body just to measure its
  byte size** (`lib/optimal_system_agent/providers/image_budget.ex:118,168-173,503-507`) before Req
  serializes the same body again at `Req.post(json: body)`
  (`lib/optimal_system_agent/providers/anthropic.ex:257,714-716`). With a ~47k-token body that is two
  full JSON encodes per request.

opencode memoizes the schema conversion (`packages/opencode/src/tool/json-schema.ts:6,9-10,19`;
v2's `packages/core/src/tool/tool.ts:76-89` returns a cached `ToolDefinition` by reference) and
serializes once. Note opencode's `ProviderTransform.schema` is *also* unmemoized
(`packages/opencode/src/provider/transform.ts:1514`) — but over ~15 small tools, not OSA's set.

**8. OSA can insert an entire extra provider round-trip before the real one — twice.**
- `TurnPipeline.compact_and_refresh_tokens` → `bounded_compaction/2`
  (`lib/optimal_system_agent/agent/loop/turn_pipeline.ex:236,270,321-348`) runs the compactor in a
  `Task.Supervisor.async_nolink` and then **`Task.yield`s up to `:compaction_timeout_ms`, default
  120_000 ms**. On the aggressive tier the summarizer makes its own provider HTTP call.
- Then `ReactLoop.do_iteration` re-checks the band
  (`lib/optimal_system_agent/agent/loop/react_loop.ex:282-330`) and `:aggressive` calls
  `ProactiveCompaction.compact/2` — **another synchronous provider round-trip**, in the same
  iteration. The dedup comment at `turn_pipeline.ex:254-268` exists precisely because these two used
  to fire back to back.

opencode has the equivalent check (`packages/core/src/session/runner/llm.ts:215`,
`packages/opencode/src/session/prompt.ts:1160-1167`) but it is a token-count gate that only escalates
to a summarization call on genuine overflow, with no 120s yield in front of it. **If the owner's
15–20s is not constant, this is the first thing to rule out** — a turn that trips the warn band pays
a full extra model call before the one he is waiting on.

**9. OSA's static base is 30,901 tokens — measured, in its own comment.**
`lib/optimal_system_agent/agent/context.ex:105-106`: *"MEASURED at v1.0.82: `:full` is 30,901 tokens
and `:lite` is 24,375"*. `priv/prompts/SYSTEM.md` is 41,243 bytes on disk. opencode's `anthropic.txt`
is 8,212 bytes. That is a **5x** difference in the base prompt alone, before tools.

### 6b. Where OSA is already ahead — do not "fix" these

- **Static base caching.** `Soul.static_base/0,1` is `:persistent_term`-backed with per-variant keys
  (`lib/optimal_system_agent/soul.ex:141-146,198-205`). Interpolation happens once. This is at least
  as good as opencode's bundler text imports.
- **Tool registry reads.** `Tools.Registry.list_active/0` reads `:persistent_term`
  (`lib/optimal_system_agent/tools/registry.ex:77-79`) — lock-free, no GenServer hop. opencode's
  equivalent is a `Map` behind a `ScopedCache` lookup, comparable.
- **The tool array is built once at boot, not per turn.** `Loop.init` builds
  `state.tools` via `Tools.filter_applicable_tools/1`
  (`lib/optimal_system_agent/agent/loop.ex:935,952-953`) and only rebuilds it on a coordinator toggle
  (`:1363`); per iteration it is merely re-*filtered*
  (`lib/optimal_system_agent/agent/loop/tool_filter.ex:51-59`). opencode resolves its tool set fully
  on every turn (`packages/opencode/src/session/tools.ts:41`, called from
  `packages/opencode/src/session/prompt.ts:1226`). **OSA is ahead here** — the cost is downstream, in
  normalization and serialization (§6a.7), not in list construction.
- **MCP schemas never leave `:persistent_term`.** `MCP.Client.Manager` publishes the aggregate map
  (`lib/optimal_system_agent/mcp/client/manager.ex:105,311`) and the registry only reads it
  (`lib/optimal_system_agent/tools/registry.ex:79,117,231`); refresh is an explicit
  `Registry.register_mcp_tools/0` → `Manager.reload/0` (`registry.ex:448`). Same shape as opencode's
  `ScopedCache` + push invalidation, and with `should_defer?` (`registry.ex:93-97`) OSA additionally
  keeps deferred servers out of the default toolbox by default.
- **Deferred MCP tools, on by default.** OSA's MCP virtualization keeps deferred servers off the
  per-request prompt as standard behaviour. opencode ships the same idea (code mode) **behind an
  experimental flag** and otherwise advertises every tool of every connected server. With 12 servers,
  OSA's default is the better one.
- **Cache breakpoints and block structure.** The memory note that OSA is at 100% cache miss because
  `split_system/2` flattens the blocks is **stale**. As of the current tree,
  `lib/optimal_system_agent/agent/context.ex:240-247` emits the same three-tier shape opencode v2
  converges on — static base (cached), world state (cached), volatile (uncached) — with the live
  timestamp deliberately isolated in the uncached tail;
  `lib/optimal_system_agent/providers/anthropic.ex:790-846` preserves those markers through
  `split_system/2`; and `:1353-1359` adds a **third breakpoint on the tools array** with a
  correct-and-documented reason (Anthropic's tiered invalidation) and a `@min_cacheable_tools_bytes`
  floor so the breakpoint is not wasted. That is more careful than opencode v1's `applyCaching`
  (`packages/opencode/src/provider/transform.ts:359-406`).
- **World-state diffing.** `WorldState.assemble` replays unchanged sections byte-for-byte
  (`lib/optimal_system_agent/agent/context.ex:287-300`). opencode v1 has no equivalent; v2 achieves
  the same end by a different means (freeze + append deltas).
- **git and project discovery are ETS-TTL cached.** `cached_git_info` with a 30s TTL
  (`lib/optimal_system_agent/agent/context.ex:1417-1433`) and `ContextDiscovery.discover` with its own
  ETS cache (`lib/optimal_system_agent/agent/context_discovery.ex:41-57`). opencode v1 does not shell
  out to git at all here (it reads a precomputed `ctx.project.vcs`), so this is a draw, not a loss.
- **No auto-continue after a text-only answer** — opencode exits the loop
  (`packages/opencode/src/session/prompt.ts:1113-1140`). This confirms the established finding that
  OSA is the outlier; it is not something opencode does better *within* a turn, it is a policy
  difference between turns.

### 6c. Where opencode does the same work — but somewhere else

| Work | opencode does it… | OSA does it… |
|---|---|---|
| Base system prompt text | bundler import at module load | `:persistent_term`, once — **parity** |
| System prompt *assembly* | v1: per turn (4 small pieces). v2: **once per session, frozen in SQLite** | per iteration, full rebuild, then discarded |
| Environment `<env>` block | v2: once at layer construction | per iteration (cheap, but rebuilt) |
| Date in prompt | v2: separate source; drift becomes a *conversation message* | correctly isolated in the uncached volatile block — **parity with v2** |
| Project instructions (AGENTS.md) | v1: per turn walk; v2: per turn walk but output only lands if changed | per iteration via `project_instructions_block` |
| Tool list construction | per turn (`SessionTools.resolve`) | **once at `Loop.init`** — OSA ahead |
| Tool JSON schemas | `WeakMap`/`Map` memoized per tool (v2: cached `ToolDefinition` by reference) | re-normalized **and** re-serialized per request, unmemoized |
| Request body serialization | once, by the HTTP client | **twice** — `ImageBudget` measures by encoding, then Req encodes |
| MCP connect + `tools/list` | lazy-once per process, `ScopedCache`, push-invalidated | `:persistent_term`, explicit reload — **parity, OSA ahead on deferral** |
| Skill discovery | lazy-once, `InstanceState`; bodies read only on tool call | full library scan **twice** per build + body read per triggered skill |
| Memory recall | not present at all | **three** recalls per turn, one awaited up to 2s |
| Transcript persistence | one row insert per message | synchronous SQLite insert **plus** a full-history JSON rewrite per turn |
| Working-tree snapshot | `snapshots.capture()` **on the critical path** (v2) — same bug | `git rev-parse HEAD` via blocking `GenServer.call`, uncached, per turn |
| Model catalog | lazy-once + disk cache + background 60-min refresh | `effective_context_window` may issue an Ollama `/api/show` probe (3s), ETS-cached |
| First token → screen | in-memory bus → SSE → reactive store; **deltas never persisted** | provider callback → PubSub → SSE (`llm_client.ex:243-253`, `agent_routes.ex:65,118-146`) — **parity** |

---

## 7. Ranked: what adopting each would cut from OSA's submit path

Ranked by expected saving on the 15–20s complaint. I have not measured OSA (another lane owns that);
these are structural estimates with the reason stated.

**1. Stop rebuilding the system prompt on the cache-hit path.** *Largest, cheapest, lowest risk.*
`react_loop.ex:1826` calls `Context.build(state)` in full and discards its system message. Splitting
`Context.build/1` so the cache-hit path builds only the message list — or better, adopting v2's
epoch model and storing the rendered baseline against the session — removes 21 block computations,
a world-state diff, a budget fitter run and an O(N) token estimate **per iteration**. On a turn with
6 iterations that is 6x the saving. Fully portable; `:persistent_term`/ETS make it natural on the BEAM.
*Timing I would want (not taking it): wall time of one `Context.build/1` call at a realistic
conversation length.*

**2. Fork the rewind checkpoint off the critical path.** `loop.ex:1149` → `checkpoint.ex:396-437`.
It is best-effort already (`rescue` at `:434`), it JSON-encodes the whole history, and nothing later
in the turn reads its result. Move it to a `Task.Supervisor.async_nolink` and drop the blocking
`GenServer.call` to `FSCheckpoint.Server`. Note opencode has the *same* bug at
`packages/core/src/session/runner/llm.ts:217`, so this is not "catching up", it is "both should fix it".
Portable, small diff. Saving grows linearly with conversation length — likely the dominant term in
long sessions.

**2b. Rule out the compaction gate before optimising anything else.** §6a.8. Two independent
compaction paths sit between submit and the provider call, one of them behind a **120-second**
`Task.yield` (`turn_pipeline.ex:270,321-348`) and both capable of issuing a full extra provider
round-trip (`react_loop.ex:286-288`). This is not a structural fix so much as a diagnosis: if the
15–20s is variable rather than constant, an extra summarization call explains it far better than any
of the millisecond-scale items below. opencode's equivalent gate is a token count with no yield
(`packages/core/src/session/runner/llm.ts:215`).
*Timing I would want (not taking it): whether a slow turn logged a compaction event.*

**3. Add the `latest-user-message` cache breakpoint.** OSA currently spends breakpoints on tools +
static base + world state (`anthropic.ex:1353`, `context.ex:244-247`) and **none on the messages**
(grep for `cache_control` in `anthropic.ex` shows all sites are system/tools). opencode's AUTO policy
puts the third on the latest user message precisely so that a turn that explodes into many
assistant/tool round-trips re-reads the whole conversation from cache
(`packages/llm/src/cache-policy.ts:5-13, 23-27`). Given the established `↑96.5k in` cumulative
figure, OSA is re-prefilling the growing conversation on every iteration. This does not shorten
time-to-first-token on iteration 1, but it should materially shorten iterations 2..N — which is most
of a 15–20s wait. Anthropic allows 4 breakpoints; OSA uses 3, so this one is free.

**4. Collapse the three memory recalls into one, and cap the await.** §6a.4. Three independent
recalls run per turn — `Coordinator.recall_block`, the `Synthesis` prefetch (awaited up to 2s, and
*redone inline* on timeout), and `Context.recall_scored` inside every `Context.build`. Fixing item 1
already removes the third from iterations 2..N; deduplicating the first two and cutting the 2s
ceiling to a few hundred ms removes the rest. opencode has no memory step on the submit path at all,
so there is no reference design to copy — this is purely OSA's own cost. Worst case 2s, plus the
`GenServer.call(Memory.Store, …, 5_000)` fan-out.

**5. Cache the skill library and stop reading skill bodies inline.** §6a.5. `File.ls!` + per-file
`Jason.decode` of the whole library happens **twice per context build**, plus a body read per
triggered skill. opencode's model is the fix and it is directly portable: scan once into
`:persistent_term`/ETS (opencode: `InstanceState`,
`packages/opencode/src/skill/index.ts:259-287`), keep only names + descriptions in the prompt, and
read the body only when the tool is called (`packages/opencode/src/tool/skill.ts:22-60`). Scales with
library size, so the saving is unknown without a count — *timing I would want: number of skill files
and the wall time of one `SkillLibrary.list_skills/0`.*

**6. Drop the double JSON encode and memoize schema normalization.** §6a.7. `ImageBudget` encodes the
entire request body purely to measure its size (`image_budget.ex:118,503-507`) and Req encodes it
again (`anthropic.ex:257`). At ~47k tokens that is two full serializations of a large structure per
request, on every iteration. Measure with `:erlang.iolist_size` on the already-built iodata, or skip
the budget pass entirely when the request contains no image parts. Separately, memoize
`SchemaNormalizer.normalize_tools/1` and `format_tools/1` against the tool-list identity — the list
is already built once at `Loop.init`, so a `:persistent_term` slot keyed on the filtered set works.
Small, self-contained diffs; likely worth tens to low hundreds of ms per iteration.

**7. Cache `bootstrap_block`, `ProgressLedger.summarize`, and the `GoalTracker` sidecar write.**
§6a.6. Two uncached `File.read`s per `Context.build`, one ledger read per turn, one JSON encode +
atomic write per turn. Individually small; collectively they are the same class of mistake opencode
avoids by making `<env>` a process-lifetime constant
(`packages/core/src/system-context/builtins.ts:16-33`). Cheap to fix, and item 1 already removes most
of the `Context.build` half.

**8. Shrink the static base.** 30,901 tokens (its own measurement, `context.ex:105`) against
opencode's ~2.1k. This does not directly cost wall time when the cache hits — but it costs the full
1.25x write on every cache miss, and it is what makes the double encode in item 6 expensive. A large,
opinionated content edit rather than a structural fix, so it ranks below 1–7.

**Not portable / not recommended:**
- **Do not restructure `handle_call` into `handle_cast` for latency.** OSA's HTTP layer already
  returns 202 immediately (§6a.0); the internal blocking costs concurrency, not time-to-first-token.
  The refactor is real (state thread is the return value, `during_turn/1` toggles `trap_exit` for
  crash recovery, `loop.ex:1685-1694`) and buys nothing against the 15–20s complaint.
- opencode's `InstanceState` `ScopedCache` has no advantage over `:persistent_term` + ETS, which OSA
  already uses. Nothing to steal.
- opencode paints nothing optimistic and waits on a server round trip for the user bubble; OSA's
  13–17 ms local paint is better. Do not change it.
- Code mode as a tool-deferral strategy is behind an experimental flag in opencode and already
  default-on in OSA.
- opencode's `snapshots.capture()` sits on its own critical path
  (`packages/core/src/session/runner/llm.ts:217`). It is a bug there too — cite it as convergent
  evidence for recommendation 2, not as a design to copy.
