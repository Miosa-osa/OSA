# Submit path: codex and Claude Code vs OSA

**Question:** what happens between the user pressing enter and the first token appearing?

Companion to `docs/submit-path-grok.md` (written) and `docs/submit-path-opencode.md`. Same frame,
same rules: this is a **sequence**, not a code review. No measurements were taken; OSA is read as
written.

---

## Sources — which trees, and why

| Tree | What it actually is | SHA / date | Used? |
|---|---|---|---|
| `~/projects/research/codex-src` | openai/codex, the real upstream Rust repo | `92cbfb4d` — **2026-08-10** | **Yes**, primary |
| `~/projects/research/claude_code_research/free-code` | `paoloanzn/free-code` — a de-obfuscated, transpiled build of Claude Code's TypeScript, shipping **inline base64 sourcemaps carrying the original `.tsx` sources and comments** | `38c09970` — **2026-04-01** | **Yes**, primary for CC |
| `~/.local/share/claude/versions/2.1.228` | the **real, current** Claude Code binary on this machine | installed 2026-08-12 | **Yes**, for cross-checking |
| `~/.local/share/zed/.../claude-agent-sdk/cli.js` | real minified CC bundle, v0.2.38 | 2026-07-20 | Yes, cross-check |
| `~/projects/research/ClaudeCode-Source-March31` | **not source.** It is `chatgptprojects/clear-code`, a marketing/docs repo ("Clear-Code — The Ultimate Guide to Open-Source AI Coding Assistants") containing only markdown + an AUDIT folder. `find -name '*.ts' -o -name '*.js'` → **0 files.** | `e188f077` — 2026-04-03 | **No** — nothing to trace |
| `~/projects/research/claude_elixir` | **not Claude Code.** It is `Miosa-osa/osa-claude-code` — *our own* half-finished Elixir port of CC, with a `MASTER_PORT_CHECKLIST.md` full of unticked boxes | `0999c62d` — 2026-04-02 | **No** — it is a derivative of the thing we are trying to study |

The earlier bad pass in this project drew conclusions from a stale clone. Two of the four "Claude
Code" trees on this box are not Claude Code at all, and the one real reconstruction is **four months
old**. So every structural claim about CC below is labelled either *(free-code)* — readable, April —
or *(confirmed in 2.1.228)* — grepped out of today's shipping binary. Where the two disagree, the
binary wins and I say so.

---

# Part 1 — codex, submit → first token

`~/projects/research/codex-src` @ `92cbfb4d`, **2026-08-10** (two days old). Paths are
`codex-rs/...`.

### Stage 0. Submit — pure, then spawned

| # | Step | file:line | Cost |
|---|---|---|---|
| 0.1 | Composer enter → `submit_user_message` | `tui/src/chatwidget/input_submission.rs:65` | pure |
| 0.2 | `submit_user_message_with_history_and_shell_escape_policy` — pre-flight guards: session-not-configured → queue and return; empty message → return; images-unsupported → restore and return; `!cmd` shell escape → local execution, never reaches the model | `tui/src/chatwidget/input_submission.rs:97-160` | pure |
| 0.3 | `Op::UserInput` reaches the core session handler and is destructured | `core/src/session/handlers.rs:196-205` | — |
| 0.4 | `new_turn_with_sub_id` — builds the `TurnContext` for this turn | `core/src/session/handlers.rs:214` | in-memory |
| 0.5 | `steer_input(...)` — if a turn is already running, the message is *steered into it* rather than starting a new one | `core/src/session/handlers.rs:226-233` | in-memory |
| 0.6 | On `NoActiveTurn`: merge `additional_context`, build `Vec<TurnInput>`, then **`sess.spawn_task(ctx, task_input, RegularTask::new())`** | `core/src/session/handlers.rs:251-268` | **spawned** |
| 0.7 | `spawn_task` → `abort_all_tasks(Replaced)` → `start_task` → `tokio::spawn` | `core/src/tasks/mod.rs:279-296`, `:297+` | the turn runs off the caller |

Same shape as grok and as OSA's TUI: nothing blocking before the paint. The one behavioural
difference worth noting is 0.5 — codex will **steer a live turn** with the new message instead of
queueing it behind the turn's completion.

### Stage 1. What is assembled once — codex's answer is a *diffed state machine*

This is where codex diverges most from grok, and where it is closest to OSA.

codex has a **`WorldState`** — `core/src/context/world_state/mod.rs` — with ~15 typed sections:
`agents_md`, `apps_instructions`, `collaboration_mode`, `compact_permissions`,
`context_window_guidance`, `environment`, `environments_instructions`, `model`, `multi_agent_mode`,
`multi_agent_usage_hint`, `permissions`, `personality`, `plugins_instructions`, `realtime`, `tools`.

Each implements `WorldStateSection` with a serializable `Snapshot`. The core operation is not
"render" but **`render_diff(previous: PreviousSectionState<'_, Value>) -> Option<Box<dyn
ContextualUserFragment>>`** (`core/src/context/world_state/mod.rs:56-62`, blanket impl `:101+`).
`None` means *nothing changed, emit nothing this turn*.

The fragment it returns is not a system-prompt block. `ContextualUserFragment`
(`context-fragments/src/fragment.rs:14`) has `role()`, `markers()`, `body()`, and
`into() -> ResponseItem::Message { role, content: [InputText { text: render() }] }`
(`context-fragments/src/fragment.rs:48-60`) — **it becomes an ordinary conversation item**, exactly
grok's discipline, reached independently.

The environment section shows the mechanism concretely (`core/src/context/world_state/environment.rs`):
it holds `current_date: Option<String>` (`:18`) carried through the snapshot (`:64`, `:94`, `:146`),
and emits an update only when `turn_context_values_changed` or the per-environment map actually
differs (`:112-146`), with `EnvironmentUpdate::Current(_) | EnvironmentUpdate::Unavailable` as the
delta alphabet (`:185`).

And AGENTS.md (`core/src/context/world_state/agents_md.rs:9-11`) reveals the cache-critical detail:

```rust
const REPLACEMENT_NOTICE: &str =
    "These AGENTS.md instructions replace all previously provided AGENTS.md instructions.";
const REMOVAL_NOTICE: &str = "The previously provided AGENTS.md instructions no longer apply.";
```

**codex never edits an earlier context item. It appends a superseding one.** That is how it gets
grok's strict-prefix property without asserting it: history is append-only by construction, so
request *N* is a prefix of *N+1* as a structural consequence rather than an invariant to be checked.

**This is the single most important finding for OSA in this document**, because OSA already has a
`WorldState`. The brief is right that grok has no counterpart and that OSA's is strictly better than
grok's as a transmission discipline. codex has one too, it is a near-twin, and it is further along
in exactly one respect: the `render_diff`-returns-`Option` contract, plus append-only supersession
with explicit replacement notices. OSA does not need to invent this; it needs to finish it.

`prompt_cache_key` is a first-class request field (`codex-api/src/common.rs:41`, `:270`, `:293`),
so cache identity is asserted to the provider rather than inferred.

### Stage 2. Tool schemas — prebuilt and `Arc`-cloned

`CoreToolRuntime::immutable_spec(&self) -> Option<&Arc<ToolSpec>>`
(`core/src/tools/registry.rs:53-57`), documented as:

> Returns a shared spec when both the spec and search metadata are immutable.

So the per-turn cost for a stable tool is an `Arc` clone — grok's "clone prebuilt structs", in Rust's
own idiom. Code-mode definitions are lazily cached alongside (`registry.rs:60-63`).

Against OSA's three full passes per request (`tools/registry.ex:216-244`,
`schema_normalizer.ex:87-120`, `Anthropic.format_tools/1`), this is the same gap grok exposed, from a
second direction.

### Stage 3. MCP — off the wire, same conclusion as grok and Claude Code

`ToolExposure` (`tools/src/tool_executor.rs:51-76`) is a six-way enum: `Direct`, `Deferred`,
`DeferredModelOnly`, `DirectModelOnly`, `CodeModeOnly`, `Hidden`. `is_deferred()` is
`Deferred | DeferredModelOnly` (`:88-90`). The doc comment on `Deferred` (`:58-62`):

> Register this tool for later discovery, but omit it from the initial model-visible tool list.
> Deferred tools must provide search metadata via `ToolExecutor::search_info`.

MCP tools are assigned exposure in one place — `core/src/mcp_tool_exposure.rs:89-93`:

```rust
let exposure = if search_tool_enabled {
    ToolExposure::Deferred
} else {
    ToolExposure::Direct
};
```

`search_tool_enabled(turn_context)` is `model_info.supports_search_tool &&
provider.capabilities().namespace_tools` (`core/src/tools/spec_plan.rs:580-582`). Exposure is
resolved once per turn into the final enum at `spec_plan.rs:223-245`, and the deferred set is
surfaced to the model as bare namespace names via `deferred_tool_namespaces()`
(`core/src/tools/registry.rs:390-393`). MCP handlers themselves are cached behind a weak binding ref
(`CachedMcpHandlers`, `core/src/mcp_tool_exposure.rs:58-61`) so reconnects do not rebuild them.

**All three references now agree**: MCP tool schemas do not belong on the per-request wire. grok
excludes them and reaches them through a BM25 search/use pair; codex marks them `Deferred` behind a
native `ToolSpec::ToolSearch`; Claude Code marks every MCP tool deferred and sends names only.

**The portability caveat is sharp and it points at grok.** codex gates deferral on
`provider.capabilities().namespace_tools` — a *provider* capability. Claude Code gates on the model
supporting `tool_reference` blocks and refuses to enable it against a non-first-party
`ANTHROPIC_BASE_URL`. Both lean on server-side cooperation. OSA is multi-provider and cannot. **OSA
should copy grok's client-side search/use shape and codex's `ToolExposure` vocabulary, not either
one's server-side mechanism.**

### Stage 4. Disk and network before the provider call

The rollout recorder — codex's session-persistence layer, the direct counterpart to OSA's
checkpoint write plus SQLite insert — is a bounded channel to a dedicated writer task. Its own
comment (`rollout/src/recorder.rs:888-895`) states the rule:

> A reasonably-sized bounded channel. If the buffer fills up the send future will yield, which is
> fine – we only need to ensure we do not perform *blocking* I/O on the caller's thread.
> … Spawn a Tokio task that owns the file handle and performs async writes.

`record_canonical_items` is an `async fn` that only enqueues (`recorder.rs:925-935`). The turn does
not wait for bytes to land.

OSA, at the same point in its turn, awaits: a whole-history rewind-checkpoint disk write
(`loop.ex:1149` → `checkpoint.ex:422-430`); a 5 s `GenServer.call` into `FSCheckpoint.Server` whose
handler shells out to git (`fs_checkpoint/server.ex:177-180`); a synchronous SQLite insert plus the
session titler (`turn_pipeline.ex:218`, `:446`); and a synchronous HTTP embedding call with a 5 s
timeout (`memory/search.ex:174-178`). Four awaited I/O operations against codex's zero and Claude
Code's zero.

### Stage 5. Fast path, and the paint

There is no separate no-tools fast path — every turn is a `RegularTask` through the same pipeline.
The relevant shortcuts are earlier and cheaper: `!cmd` never reaches the model
(`input_submission.rs:150-160`), and a live turn absorbs the message via `steer_input` rather than
starting a second one (`handlers.rs:226`).

Between submit and first token the TUI shows a status indicator that schedules its own repaint at
`Duration::from_millis(32)` (`tui/src/status_indicator_widget.rs:245-246`) — about 31 fps, versus
OSA's 200 ms / 5 fps tick and Claude Code's 150 ms shimmer. codex is the fastest waiting-state
animation of the three, by a wide margin, and it costs nothing: it is a self-rescheduling widget,
not a global tick.

---

# Part 2 — Claude Code, submit → first token

Line numbers are `free-code/src/...` unless marked otherwise.

### Stage 0. The keystroke, and what paints immediately

| # | Step | file:line | Cost |
|---|---|---|---|
| 0.1 | `onSubmit` in the REPL | `screens/REPL.tsx:3145` | pure |
| 0.2 | `repinScroll()` | `screens/REPL.tsx:3154` | pure |
| 0.3 | `addToHistory` (in-memory), clear input buffer | `screens/REPL.tsx:3320`, `:3356-3365` | pure |
| 0.4 | `setUserInputOnProcessing(input)` — **this is the paint**: placeholder + spinner appear on the next Ink frame, before any I/O | `screens/REPL.tsx:3372` | pure state |
| 0.5 | `await awaitPendingHooks()` — blocks on the SessionStart hook if it is still running | `screens/REPL.tsx:3492` | **awaited**, first turn only |
| 0.6 | `await handlePromptSubmit(...)` | `screens/REPL.tsx:3493` → `utils/handlePromptSubmit.ts:120` | — |
| 0.7 | `queryGuard.reserve()` *before* the first await, so a double-submit queues instead of double-dispatching | `utils/handlePromptSubmit.ts:437` | pure |
| 0.8 | `await processUserInput(...)` — slash/bash-mode parse, attachment resolution | `utils/handlePromptSubmit.ts:476` | awaited |
| 0.9 | `void fileHistoryMakeSnapshot(...)` — **fire-and-forget** | `utils/handlePromptSubmit.ts:528` | off-path |
| 0.10 | `await onQuery(...)` | `utils/handlePromptSubmit.ts:560` → `screens/REPL.tsx:2858` → `:2664` | — |

Note 0.9 against OSA. CC's file snapshot — the direct analogue of OSA's rewind checkpoint — is
`void`ed. OSA awaits its equivalent twice: the whole-history checkpoint disk write
(`loop.ex:1149` → `checkpoint.ex:422-430`) and a 5 s `GenServer.call` into `FSCheckpoint.Server`
whose handler shells out to git (`fs_checkpoint/server.ex:177-180`).

### Stage 1. Inside `onQueryImpl` — what is awaited and what is not

| Step | file:line | Awaited? |
|---|---|---|
| `diagnosticTracker.handleQueryStart` | `screens/REPL.tsx:2670` | `void` |
| `maybeMarkProjectOnboardingComplete()` | `screens/REPL.tsx:2678` | `void` |
| **Session title generation via Haiku** | `screens/REPL.tsx:2696` | **fire-and-forget `.then()`** |
| `store.setState` for permission rules | `screens/REPL.tsx:2714` | sync |
| `getToolUseContext(...)` | `screens/REPL.tsx:2749` | sync |
| `queryCheckpoint('query_context_loading_start')` | `screens/REPL.tsx:2770` | instrumentation |
| **the one blocking join** — `Promise.all([checkAndDisableBypassPermissionsIfNeeded, checkAndDisableAutoModeIfNeeded?, getSystemPrompt(), getUserContext(), getSystemContext()])` | `screens/REPL.tsx:2771-2775` | **awaited** |
| `buildEffectiveSystemPrompt(...)` | `utils/systemPrompt.ts:41`, called `REPL.tsx:2784` | sync |

The session titler is the sharpest single contrast in this document. **CC also runs a Haiku titler
on the first turn, and it does not wait for it.** OSA runs its titler synchronously inside
`turn_pipeline.ex:446`, next to a synchronous SQLite insert at `:218`.

### Stage 2. What is assembled once vs per turn

**System prompt** — `constants/prompts.ts:444`, `getSystemPrompt()`. The outer function is **not**
memoized and runs every turn. Its *sections* are:

- `systemPromptSection(name, compute)` (`constants/systemPromptSections.ts:20`) marks a section
  cacheable; `resolveSystemPromptSections()` (`:43`) reads a **module-level `Map`**
  (`bootstrap/state.ts:1641`, `STATE.systemPromptSectionCache` at `:203`/`:399`).
- Cache is cleared **only on `/clear` and `/compact`** (`systemPromptSections.ts:65`).
- Cached-once sections: `session_guidance`, `memory`, `ant_model_override`, `env_info_simple`,
  `language`, `output_style`, `scratchpad`, `frc`, `summarize_tool_results`,
  `numeric_length_anchors`, `token_budget`, `brief` (`prompts.ts:491-555`).
- Exactly **one** section is deliberately uncached:
  `DANGEROUS_uncachedSystemPromptSection('mcp_instructions', …, 'MCP servers connect/disconnect
  between turns')` (`prompts.ts:513-520`).

Contrast with OSA: `TurnPipeline.clear_message_caches/0` (`turn_pipeline.ex:157-163`) drops the
system-message cache at **every** user turn — CC drops its equivalent only on `/clear` and
`/compact`, and even then at section granularity, not wholesale. And on a cache hit OSA still runs
`Context.build/1` in full (`react_loop.ex:1824`), executing all 21 dynamic block builders
(`context.ex:468-503`) per ReAct iteration. CC's cached sections return the stored string.

**Context** — `context.ts`, all three are `lodash-es/memoize` with **no resolver**, i.e. one cached
promise for the life of the process:

- `getGitStatus = memoize(async () => …)` — `context.ts:36`
- `getSystemContext = memoize(async () => …)` — `context.ts:116` (runs `getGitStatus`)
- `getUserContext = memoize(async () => …)` — `context.ts:155` (reads CLAUDE.md via
  `getMemoryFiles()`/`getClaudeMds()`)

Invalidated only by an explicit `getUserContext.cache.clear?.()` in `setSystemPromptInjection()`
(`context.ts:29`), which exists solely for an internal cache-break debug command.

**`currentDate` is computed inside `getUserContext` and therefore frozen at first call for the whole
session.** This is functionally identical to grok freezing `current_date` at build time. It is a
*deliberate cache-stability trade*, and it has the same known cost: in a session running past
midnight the model is told the wrong date. Both harnesses accept that; the byte-stability of the
prefix is worth more than date accuracy.

**Background prefix — yes, and it is explicit.** `main.tsx` has a
`startDeferredPrefetches()` (~`:380`) that runs *after* the first render — its own comment says it
"doesn't block the initial paint" — and fires, unawaited:

```
void initUser(); void getUserContext(); prefetchSystemContextIfSafe(); void getRelevantTips();
                                                              main.tsx:404-407
```

`prefetchSystemContextIfSafe()` (`main.tsx:358`) gates the `getSystemContext()` warm-up on the trust
dialog having been accepted, because git commands can execute hooks — `void getSystemContext()` at
`main.tsx:367` / `:375`. `--bare` mode skips the whole thing on the stated grounds that with no
user-is-typing window to hide it in, the prefetch is pure overhead.

So CC's answer to grok's background prefix task is: **warm the memoized getters during the window in
which the user is typing their first message.** By the time `REPL.tsx:2771` awaits them they are
usually already-resolved promises. This is the same idea as grok's armed background task, reached by
a different route, and — importantly for us — it needs no new concurrency primitive, only that the
expensive thing be memoized and touched early.

### Stage 3. Tool schemas

`utils/toolSchemaCache.ts` — a session-scoped module-level `Map` (`TOOL_SCHEMA_CACHE`, `:18`). Its
own comment states the intent exactly:

> Tool schemas render at server position 2 … Memoizing per-session locks the schema bytes at first
> render — mid-session GB refreshes no longer bust the cache.

`toolToAPISchema()` (`utils/api.ts:119`) keys on `tool.name` (or `name:JSON(inputJSONSchema)` for
tools carrying a per-instance schema — MCP, `StructuredOutput` — `:147-150`). On a miss it runs
`zodToJsonSchema` (`:160`) and stores the **base** shape (`:169-208`). Every later call does a cheap
**overlay** (`:211-230`) adding only `defer_loading` and `cache_control`, the two fields that
legitimately vary per turn.

Called per request as `Promise.all(filteredTools.map(toolToAPISchema))`
(`services/api/claude.ts:1235-1246`) — so the array is rebuilt per request, but from cached bases,
and it is **one** pass.

OSA does **three** passes over ~15.5 k tokens per request: reflection per tool per `Context.build`
(`tools/registry.ex:216-244`), a full walk in `SchemaNormalizer.normalize_tools/1`
(`schema_normalizer.ex:87-120`), then a third map in `Anthropic.format_tools/1`. None of them
memoize.

### Stage 4. MCP — the answer to the 12-server question

This is the most directly transferable thing in the document, and unlike most of this report it is
**confirmed in the shipping 2.1.228 binary**, not only in the April reconstruction.

*(free-code)* `tools/ToolSearchTool/prompt.ts:62`, `isDeferredTool(tool)`:

```
if (tool.alwaysLoad === true) return false        // opt-out via _meta['anthropic/alwaysLoad']
if (tool.isMcp === true) return true              // MCP tools are ALWAYS deferred
if (tool.name === TOOL_SEARCH_TOOL_NAME) return false
```

Whether deferral is *applied* is decided by `isToolSearchEnabled()` (`utils/toolSearch.ts:385`):
the model must support `tool_reference` blocks, `ToolSearchTool` must not be disallowed, and the
mode must be `tst` (always) or `tst-auto` (threshold on tool count / description size);
`standard` disables it.

When active, `services/api/claude.ts:1152-1172` builds `filteredTools`: non-deferred tools always
go on the wire; deferred tools go on the wire **only** if `extractDiscoveredToolNames(messages)`
(`:1158`) finds the model already fetched them via `ToolSearchTool` in this conversation. In their
place a compact **name-only** `<available-deferred-tools>` list is prepended as a plain user message
(`:1330-1345`).

Confirmed in **2.1.228** (strings from the real binary):

- the tool itself: `"Fetches full schema definitions for deferred tools so they can be called."`
- its parameter doc: `Query to find deferred tools. Use "select:<tool_name>" for direct selection, or keywords to search.`
- `ToolSearchTool: cache invalidated - deferred tools changed` — the deferred set is cached and
  invalidated on change, not recomputed per turn
- a preserved source comment: *"Deferred-tool names discovered before this compaction.
  `extractDiscoveredToolNames` reads this back on the next turn so the tool-schema filter keeps
  including them after the `tool_reference`-carrying messages were summarized away."*
- the proxy guard: `[ToolSearch:optimistic] disabled: ANTHROPIC_BASE_URL=… is not a first-party
  Anthropic host. Set ENABLE_TOOL_SEARCH=true (or auto / auto:N) if your proxy forwards
  tool_reference blocks.`
- the model guard: `model does not support tool_reference blocks. This feature is available on
  Claude Sonnet 4+, Opus 4+, Haiku 4.5+, and newer models.`

**The one caveat that matters for OSA.** CC's mechanism leans on a *server-side API feature* —
`tool_reference` content blocks, which the Anthropic API resolves. grok's equivalent is entirely
client-side: a BM25 index over tool descriptions with a search/use tool pair, no provider
cooperation. **OSA should copy grok's shape, not CC's**, because OSA must work against providers
that have no `tool_reference` support. But CC independently confirms the *policy*: MCP tools are
deferred by default with a per-server opt-out, names are cheap, schemas are fetched on demand, and
the discovered set survives compaction so the cache does not thrash.

### Stage 5. The request, and prompt-cache discipline

`queryLoop` (`query.ts:241`) pre-API work, all awaited, all in-process, no network:
`applyToolResultBudget` (`:379`), snip (`:403`, gated), `microcompact` (`:414`), context-collapse
(`:441`, gated), `autocompact` (`:454`). Two prefetches are started and **not** awaited here:
`startSkillDiscoveryPrefetch` (`:331`) and `startRelevantMemoryPrefetch` (`:301`).

That last one is worth naming. OSA's counterpart — a **synchronous HTTP embedding call with a 5 s
timeout** (`memory/search.ex:174-178`) — is the same feature, on the critical path, over the network.
CC's is a `using`-scoped prefetch whose result is consumed after the tool phase.

`yield { type: 'stream_request_start' }` (`query.ts:337`) flips the spinner to "requesting" *before*
the HTTP call is issued.

Then `deps.callModel` (`query.ts:659` → `query/deps.ts:35` → `services/api/claude.ts:752`):
tool schemas (`:1235`), message normalization (`:1266`), `buildSystemPromptBlocks` (`:1376`, defined
`:3213`), `addCacheBreakpoints` (`:1701`, defined `:3063`), then the streaming request under
`withRetry` (`services/api/withRetry.ts:170`).

**Cache-control layout:**

- `getCacheControl()` — `claude.ts:358` — `{type:'ephemeral', ttl?:'1h', scope?}`. The 1 h TTL
  decision is **latched in `STATE`** for session stability, with a comment (`:404-405`) noting that
  a mid-session flip would itself invalidate ~20 k tokens.
- System prompt is split into up to **4 blocks** by `splitSysPromptPrefix()` (`utils/api.ts:321`):
  attribution header (uncached), CLI sysprompt prefix, static content before
  `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` (global scope), dynamic tail (uncached). The sentinel is defined
  at `constants/prompts.ts:114` and **confirmed in the real bundle** as
  `xG1="__SYSTEM_PROMPT_DYNAMIC_BOUNDARY__"`.
- Exactly **one** message-level `cache_control` marker per request — `addCacheBreakpoints`
  (`claude.ts:3063`), comment at `:3078`, placed at `messages.length - 1`.
- When an MCP tool forces a tool-position cache marker (`needsToolBasedCacheMarker`, `claude.ts:1212`)
  CC **drops down from global to org scope** rather than let MCP churn poison the global tier.

**Prefix-stability enforcement — CC's answer to grok's strict-prefix assertion, and it is stronger.**
In 2.1.228 there is a live per-request cache-stability watchdog. For each
`(querySource, agentId)` it stores a hash of: the system prompt (and a hash *per block*, plus per-block
lengths), the tool schema set (and a hash *per tool*), the `cache_control` placements, model, betas,
fast mode, global cache strategy, effort, extra body params, and a hash of every message. On the next
request it diffs all of them and computes `firstChangedMessageIndex`. Then, when
`cache_read_input_tokens` actually drops, it attributes the break in plain English:

```
model changed (X → Y) · system prompt changed (+N chars) · tools changed (+A/-B tools) ·
tools changed (tool prompt/schema changed, same tool set) · fast mode toggled ·
global cache strategy changed · cache_control changed (scope or TTL) · betas changed (+a -b) ·
effort changed · extra body params changed · defer_loading presence flipped ·
message history mutated at index I/N · possible 1h TTL expiry (prompt unchanged) ·
possible 5min TTL expiry (prompt unchanged) · likely server-side (prompt unchanged, <5min gap)
```

emitted as `[PROMPT CACHE] …` and as a `tengu_prompt_cache_break` telemetry event.

grok asserts request *N* is a strict prefix of *N+1*. CC does not assert — it **observes, diffs, and
names the culprit at runtime**. For OSA that is the better shape: it turns "the cache is 100 % miss"
(the measured state today, per `reference_harness_flow_comparison`) from a mystery into a log line.

### Stage 6. Fast path, and the paint

There is **no** no-tools fast path. Every turn goes through the same `queryLoop`. The only shortcut
is `shouldQuery === false` — pure local slash commands never reach `onQuery`
(`screens/REPL.tsx:2733-2748`).

Between submit and first token the screen shows: the placeholder from step 0.4, a spinner whose verb
cycles from `constants/spinnerVerbs.ts` on a 150 ms shimmer (`SHIMMER_INTERVAL_MS`,
`bridge/bridgeStatusUtil.ts:21`, consumed at `components/Spinner.tsx:372`), and an elapsed counter on
an independent 1000 ms `setInterval` (`hooks/useElapsedTime.ts:30`). The *label* — `requesting` →
`thinking` → `responding` — is driven purely by inbound stream events through `onSetStreamMode`
(`utils/messages.ts:2984-3018`), not by a tick.

---

# Part 3 — Streaming mechanics

## codex

**1. Draw scheduling — elapsed-time gate, deadline-based, 120 fps.**
`tui/src/tui/frame_rate_limiter.rs` is a 62-line pure helper whose module doc states the intent:

> Widgets sometimes call `FrameRequester::schedule_frame()` more frequently than a user can
> perceive. This limiter clamps draw notifications to a maximum of 120 FPS to avoid wasted work.

```rust
pub(super) const MIN_FRAME_INTERVAL: Duration = Duration::from_nanos(8_333_334);   // :13
pub(super) fn clamp_deadline(&self, requested: Instant) -> Instant { … }           // :23-31
pub(super) fn mark_emitted(&mut self, emitted_at: Instant) { … }                   // :34-36
```

Note the shape: widgets request a *deadline*, the limiter **clamps it forward**, and the async
scheduler sleeps until it. That is a cleaner formulation than a floor applied after the fact, but it
is still an elapsed-time gate — **not** write-side backpressure. It does not consult the terminal.

So on draw scheduling the field is: **grok alone has written-ack backpressure.** codex clamps to
8.33 ms, Claude Code throttles to 16 ms, OSA floors at 16 ms
(`app/event_loop.rs:1391-1411`). OSA is not behind the field here; it is behind grok, along with
everyone else. That is worth saying plainly because it changes the priority of that item from
"fix a defect" to "adopt an improvement two of four references also lack".

The one thing OSA should take from codex's version is the *deadline* formulation and the fact that
the limiter is a small pure struct with unit tests (`frame_rate_limiter.rs:38-61`) rather than
inline conditions in the event loop. OSA's floor is applied only when consecutive batches are
stream-only; codex's clamp is unconditional and therefore has no such carve-out to get wrong.

**2. Delta coalescing — codex does not coalesce deltas, it paces *lines*.**
`tui/src/streaming/chunking.rs` is an adaptive two-gear commit policy:

> In `ChunkingMode::Smooth`, one queued line is drained per baseline commit tick. When queue
> pressure rises, it switches to `ChunkingMode::CatchUp` and drains queued backlog immediately so
> display lag converges as quickly as possible. … The policy is source-agnostic: it depends only on
> queue depth and queue age. — `chunking.rs:1-11`

with explicit hysteresis constants (`chunking.rs:90-116`): `ENTER_OLDEST_AGE` 120 ms,
`EXIT_OLDEST_AGE` 40 ms, `EXIT_HOLD` 250 ms, `REENTER_CATCH_UP_HOLD` 250 ms,
`SEVERE_OLDEST_AGE` 300 ms.

This is a genuinely different model from OSA's and Claude Code's. Both of those paint whatever text
has accumulated whenever the frame gate opens; the visible rate is the provider's rate. codex
decouples them: provider deltas fill a **line queue**, and a commit tick drains that queue at a
deliberately smoothed pace, catching up when it falls behind. OSA's measured 342 deltas → 233 draws
is the emergent behaviour of a gate; codex's is a control loop with a target.

Whether that is *better* is a taste question — it deliberately adds display lag to buy evenness —
but it is the only reference that treats streaming cadence as something to control rather than
observe, and the hysteresis constants are the hard part someone else has already tuned.

**3. Incremental markdown mid-stream — confirmed, and the table holdback is real.**
`tui/src/streaming/render.rs:1-26`:

> Completed top-level blocks are retained while the final block stays mutable, avoiding repeated
> rendering of the stable prefix as newline-bearing deltas arrive. … The prefix before both
> boundaries is immutable; only the final top-level Markdown block is [re-rendered].

with a **two-part boundary**, which neither OSA nor Claude Code has:

```rust
stable_source_len: usize,     // :24   source-text boundary
stable_rendered_len: usize,   // :26   the rendered-line boundary corresponding to it
```

Tracking the rendered boundary alongside the source boundary is what lets codex commit *lines* into
scrollback (see #2) rather than re-render a growing string — the two mechanisms are the same design.

The per-construct holdback is `tui/src/streaming/table_holdback.rs`:

```rust
enum TableHoldbackState {          // :23-32
    None,                          // no table — all rendered lines may flow to the stable queue
    PendingHeader { header_start },// last non-blank line looks like a header; wait one delta
    Confirmed { table_start },     // header + delimiter seen; from table_start on stays mutable
}
```

with the stated reason (`:4-6`): *"adding a row can reflow earlier table rows instead of committing
a stale render to scrollback"*, and a deliberately conservative scanner with one-line lookbehind
(`:34-38`). Fence tracking is separate and shared (`crate::table_detect::FenceTracker`).

**So the claim in the brief is confirmed at file:line.** But note precisely what it buys: table
holdback protects against *committing* a stale table, not against re-rendering cost. codex's
unstable tail can still be an open code fence. On the specific measured OSA problem — 2 544 µs per
delta on a 200-line open fence — codex is in the same position as OSA and Claude Code. **None of the
three references solves the open-fence re-parse.** grok's resumable syntax state carried across
re-renders is the only approach in the reference set that would, and it remains the right target.

**4. Speculative rendering of unterminated constructs.** codex's holdback machinery is
**block-level, not span-level**. `TableHoldbackState` and the fence tracker decide where the mutable
tail begins; nothing in `streaming/` inspects an unclosed `**` or a half-typed `[link](htt`. Those
are handed to the markdown renderer inside the mutable tail and rendered as whatever the renderer
makes of them — literal, then restyled when the closer lands.

**Conclusion across the whole reference set: nobody suppresses.** Not codex, not Claude Code
(`marked` emits unclosed inline spans as literal text, no special-casing in
`utils/markdown.ts:49+`), not OSA. The reflow-on-close behaviour the owner diagnosed is universal.
That does not make it correct — the mutating-URL live hyperlink is genuinely worse than the others'
behaviour because it is *interactive*, not merely visual — but it means there is no reference
implementation to copy, and this stays an original decision. The narrow, defensible version:
suppress only the constructs where the intermediate state is actively misleading (an OSC-8 hyperlink
with an incomplete URL), and leave visual-only churn (bold, italic) alone.

**5. Between submit and first token.** A status indicator widget that reschedules its own frame at
`Duration::from_millis(32)` (`tui/src/status_indicator_widget.rs:245-246`) and calls
`self.frame_requester.schedule_frame()` on state change (`:181`). Repaint while waiting is therefore
**widget-driven, not globally ticked** — the widget owns its own cadence and the rest of the app
paints only on events. This is the structurally right answer and it is cheap: OSA's 200 ms global
tick exists to animate one spinner, and it repaints everything to do it.

**6. Frame atomicity.** DEC 2026, via crossterm rather than hand-rolled: `use
crossterm::SynchronizedUpdate` (`tui/src/tui.rs:18`), applied at `stdout().sync_update(|_| …)` —
`tui/src/tui.rs:944`, `:1009`, `:1028`, `:1075`. Same mechanism as OSA and Claude Code. **All three
agree; OSA is correct here and needs no change.**

## Claude Code

**1. Draw scheduling.** CC ships a **forked Ink** (`src/ink/ink.tsx`). The render scheduler is

```
const deferredRender = () => queueMicrotask(this.onRender);
this.scheduleRender = throttle(deferredRender, FRAME_INTERVAL_MS, {leading:true, trailing:true});
                                                              ink/ink.tsx:213
export const FRAME_INTERVAL_MS = 16                           ink/constants.ts:2
```

driven from the reconciler's `resetAfterCommit` (`ink.tsx:203-209`). The microtask defer is there so
the paint runs *after* layout effects commit — otherwise the cursor lags a keystroke.

This is an **elapsed-time gate, not write-side backpressure** — the same class of mechanism as OSA's
16 ms floor at `app/event_loop.rs:1391-1411`, and weaker than grok's written-ack. So: **grok is
alone here.** OSA is not behind Claude Code on draw scheduling; both are behind grok. That should
change how the fix is framed — it is an improvement over the state of the art in two of four
references, not a defect relative to the field.

(There is a second, faster drain at `FRAME_INTERVAL_MS >> 2` ≈ 4 ms — `ink.tsx:758` — but it is
scroll-momentum only, not streaming.)

**2. Delta coalescing.** None at the data layer. Every `text_delta` goes straight to React state:
`onStreamingText?.(text => (text ?? '') + deltaText)` (`utils/messages.ts:3047-3052`). Coalescing is
purely a side effect of the 16 ms throttle — a burst inside one window collapses to one paint. This
is the same emergent behaviour as OSA's measured 342 deltas → 233 draws at 80 tok/s and 1:1 at
40 tok/s. **OSA and CC are doing the same thing here.**

**3. Incremental markdown mid-stream.** CC has a dedicated `StreamingMarkdown`
(`components/Markdown.tsx:186`, used at `components/Messages.tsx:709`) separate from the settled
`Markdown`. Its algorithm:

```
const boundary = stablePrefixRef.current.length;
const tokens = marked.lexer(stripped.substring(boundary));   // lex only from the boundary
let lastContentIdx = tokens.length - 1;                       // skip trailing 'space' tokens
while (…tokens[lastContentIdx].type === 'space') lastContentIdx--;
let advance = 0; for (i < lastContentIdx) advance += tokens[i].raw.length;
if (advance > 0) stablePrefixRef.current = stripped.substring(0, boundary + advance);
                                                     components/Markdown.tsx:212-226
```

`stablePrefix` is rendered by a memoized `<Markdown>` and never re-parsed; only `unstableSuffix` is.
The boundary is **monotonic**, with a `startsWith` reset as the only escape hatch (`:206-208`).

This is **the same boundary rule as OSA's**, expressed differently: the last complete top-level
token, i.e. the last blank line at depth 0 outside a fence. And it has **exactly the same unbounded
case**, which CC's own docstring states as a feature rather than a hazard:

> marked.lexer() correctly handles unclosed code fences as a single token, so block boundaries are
> always safe. — `components/Markdown.tsx:179-181`

Safe, yes — but it means an open 200-line fence *is* the unstable suffix and gets fully re-lexed per
delta. **CC does not solve OSA's 2 544 µs/delta fence problem; it has it too.** The only thing CC
adds that OSA lacks is `hasMarkdownSyntax()` (`Markdown.tsx`, `MD_SYNTAX_RE`), a single regex over
the first 500 chars that skips `marked.lexer` entirely for plain prose — the comment puts the saving
at ~3 ms per call and notes it covers most short assistant replies. That is a cheap, fully portable
win for OSA's 1 256 µs prose case.

There is also a module-level LRU `tokenCache` keyed by content hash, capped at 500
(`TOKEN_CACHE_MAX`), but by construction it only helps virtual-scroll remounts of *finished*
messages — during streaming the content string changes every delta and never hits.

**4. Speculative rendering of unterminated constructs.** **No holdback.** There is no suppression
logic anywhere in `utils/markdown.ts` (`formatToken`, `:49+`) or in `StreamingMarkdown`. `marked`'s
inline tokenizer simply fails to match an unclosed `**` or `[link](htt` and emits it as literal text;
on the delta that brings the closer, the same block re-lexes and the span becomes styled — with the
same four-column reflow and downstream line shift OSA exhibits.

So **OSA's diagnosed defect is shared with Claude Code**. It is a genuine open decision, not a bug
OSA uniquely has, and the reference set gives no cover for either answer: neither CC nor (per this
trace) OSA suppresses, and the question of whether to is still ours to decide.

**5. Between submit and first token.** Covered in Part 2 Stage 6. Two independent intervals — 150 ms
shimmer and 1000 ms elapsed — and event-driven label transitions. **OSA's 200 ms tick is a 5 fps
spinner against CC's ~6.7 fps shimmer; this is not a meaningful gap.**

**6. Frame atomicity.** CC uses DEC 2026, same as OSA. `ink/termio/dec.ts:37-38` defines
`BSU = decset(DEC.SYNCHRONIZED_UPDATE)` / `ESU = decreset(...)`; `ink/terminal.ts` probes support in
`isSynchronizedOutputSupported()` (~`:67-104`) and exposes `SYNC_OUTPUT_SUPPORTED` (`:183`); the
flush wraps the frame (`:200-246`). **Confirmed in the real bundle**: `W7q="\x1B[?2026h"`,
`arY="\x1B[?2026l"`.

One detail worth stealing: CC **excludes tmux from the support probe** on the stated grounds that
tmux parses and proxies every byte but does not implement DEC 2026. If OSA's probe does not special-
case tmux, that is a concrete, cheap correctness fix.

CC also carries a renderer choice OSA does not: `"fullscreen"` uses a *flicker-free alt-screen
renderer with virtualized scrollback* (equivalent to `CLAUDE_CODE_NO_FLICKER=1`) versus `"default"`,
the classic main-screen renderer — and it emits a `tengu_flicker` telemetry event carrying
`desiredHeight` / `availableHeight` / `reason` whenever a frame could not fit, rate-limited to one
per second (strings at 2.1.228). That `desiredHeight`-vs-`availableHeight` instrumentation is the
same idea as the `desired_height` trait already on the OSA steal-list from grok, arrived at
independently by a second reference.

---

# Part 4 — the diff against OSA, ranked

## 4a. The three-way answer table

| Question | grok | codex | Claude Code | OSA today |
|---|---|---|---|---|
| Assembled once vs per turn | build-time system prompt + background prefix task | `WorldState` sections diffed; `render_diff → None` when unchanged | section-level `Map` cache + `memoize`d context getters | `Soul.static_base/1` memoized in `persistent_term` ✅; but system-message cache dropped every turn and `Context.build/1` runs in full |
| Background/deferred prefix | yes, armed at initialize, `take()`n by first prompt | not needed — diffed state means turn 2+ emits nothing | yes, `startDeferredPrefetches()` warms memoized getters during first-typing window | none |
| Tool schemas | materialized at registration, cloned | `immutable_spec() -> &Arc<ToolSpec>`, cloned | `TOOL_SCHEMA_CACHE` base + 2-field overlay | reflected + normalized + formatted, **3 passes, every request** |
| MCP off the wire | yes — BM25 search/use, client-side | yes — `ToolExposure::Deferred`, provider-gated | yes — always deferred, `tool_reference`, model-gated | **no** |
| Disk/network awaited pre-request | no | no — rollout writer is a channel to a spawned task | no — snapshot `void`ed, titler `.then()`ed, memory prefetch unawaited | **four**: checkpoint write, 5 s git `GenServer.call`, SQLite + titler, 5 s HTTP embedding |
| No-tools fast path | no | no | no | n/a |
| Cache-prefix protection | frozen `current_date` + strict-prefix assertion | append-only supersession (structural) + `prompt_cache_key` | frozen `currentDate`, `DYNAMIC_BOUNDARY` split, TTL latched, **runtime cache-break attribution** | **100 % miss** — `split_system/2` flattens cache blocks around a µs timestamp |
| Draw scheduling | **written-ack backpressure** | 120 fps deadline clamp | 16 ms throttle | 16 ms floor, conditional |
| Delta coalescing | — | line queue + adaptive commit tick w/ hysteresis | emergent from throttle | emergent from floor |
| Open-fence re-parse | resumable syntax state | **not solved** | **not solved** | **not solved** |
| Unterminated span suppression | — | **no** | **no** | **no** |
| DEC 2026 | — | yes | yes | yes ✅ |

Read the "no" columns carefully. On four of the twelve rows — no-tools fast path, open-fence
re-parse, span suppression, DEC 2026 — OSA is level with or ahead of the field. The 15–20 s is
concentrated in three rows: awaited I/O, tool-schema passes, and MCP on the wire.

## 4b. Ranked, with portability stated plainly

### 1. Get the four awaited I/O operations off the path — *largest win, fully portable*

codex and Claude Code both do the same persistence work OSA does, and **neither waits for it**.
codex: a bounded channel to a writer task, with the rule written into the comment — *"we only need
to ensure we do not perform blocking I/O on the caller's thread"* (`rollout/src/recorder.rs:888-895`).
Claude Code: `void fileHistoryMakeSnapshot(...)` (`utils/handlePromptSubmit.ts:528`), the Haiku
titler as a bare `.then()` (`screens/REPL.tsx:2696`), the memory prefetch as a `using`-scoped
non-awaited handle (`query.ts:301`).

OSA's four — `loop.ex:1149`/`checkpoint.ex:422-430`, `fs_checkpoint/server.ex:177-180`,
`turn_pipeline.ex:218`/`:446`, `memory/search.ex:174-178` — have no counterpart in *either*
reference. This is not a difference in approach; it is work the references simply do not do here.

Portability: total. A BEAM application is better positioned for this than either reference — `Task`
plus a `GenServer` cast is less machinery than a Tokio channel with a writer task. The care needed
is ordering: the checkpoint must be durable before a rewind can target it, which is a barrier at
*rewind* time, not at *submit* time.

Note the two 5 s timeouts specifically. A 5 s timeout on the critical path is not a safety net, it
is a latency budget being spent. The git `GenServer.call` and the embedding HTTP call together can
account for 10 s of a 15–20 s complaint on their own.

### 2. Stop reflecting tools three times — *large, fully portable*

`immutable_spec() -> Option<&Arc<ToolSpec>>` (`core/src/tools/registry.rs:53-57`) and
`TOOL_SCHEMA_CACHE` (`utils/toolSchemaCache.ts:18`) are the same idea in two languages: **build the
wire-format schema once, at registration, and hand out a reference.** Claude Code's version even
isolates the two fields that legitimately vary per turn (`defer_loading`, `cache_control`) into a
cheap overlay (`utils/api.ts:211-230`), so the cached bytes stay byte-identical.

OSA's `tools/registry.ex:216-244` → `schema_normalizer.ex:87-120` → `Anthropic.format_tools/1` is
three walks over ~15.5 k tokens per request, none memoized. On the BEAM the natural fix is the one
OSA already uses correctly for `Soul.static_base/1`: `persistent_term`, keyed by tool version. Note
Claude Code's cache comment as the design constraint — *"Memoizing per-session locks the schema bytes
at first render"* — the point is not only speed, it is that a re-derived schema is a re-derived
*byte string*, and that is a cache break.

### 3. Take MCP tool schemas off the wire — *large, portable, and it shrinks the 15.5 k*

Unanimous across all three references. The owner runs 12 servers; those schemas are the bulk of the
15.5 k.

Portability requires a choice, and the choice is **grok's**, not codex's or Claude Code's. Both of
those gate on a server-side capability (`provider.capabilities().namespace_tools`,
`spec_plan.rs:580-582`; `tool_reference` model support, `utils/toolSearch.ts:385`) and Claude Code
explicitly refuses to enable it through a non-first-party proxy. OSA must work against providers that
offer neither.

What to take from codex and Claude Code instead is the *policy vocabulary*, which is more thought
through than grok's binary include/exclude:

- codex's `ToolExposure` six-way enum (`tools/src/tool_executor.rs:51-76`) — `Direct`, `Deferred`,
  `DeferredModelOnly`, `DirectModelOnly`, `CodeModeOnly`, `Hidden`. OSA will want at least
  Direct/Deferred/Hidden, and the `*ModelOnly` distinction the moment sub-agents get a different
  tool surface than the top-level model.
- Claude Code's **per-server opt-out**: `_meta['anthropic/alwaysLoad']`, checked *first*
  (`tools/ToolSearchTool/prompt.ts:63-66`). Some MCP servers exist to be used on turn one; a blanket
  defer breaks them.
- Claude Code's **compaction survival**: discovered tool names are extracted from history and
  re-included even after the messages that carried them were summarized away (preserved comment in
  2.1.228). Without this, every compaction silently un-discovers the model's tools mid-task.

### 4. Make prefix stability observable — *not a latency saving, but it converts 47 k into a cache hit*

OSA's prompt cache is measured at **100 % miss**, and the cause is known: `split_system/2` flattens
the cache blocks around a microsecond timestamp. Fix that first; it is a one-line class of bug.

Then adopt Claude Code's *watchdog*, which is a better answer than grok's assertion. In 2.1.228, per
`(querySource, agentId)`, each request stores hashes of the system prompt (whole **and per block**,
with per-block lengths), the tool set (whole **and per tool**), `cache_control` placements, model,
betas, fast mode, cache strategy, effort, extra body params, and every message — then diffs them
against the previous request and computes `firstChangedMessageIndex`. When `cache_read_input_tokens`
actually drops it emits a `[PROMPT CACHE]` line naming the culprit from a fixed taxonomy:

> `model changed (X → Y)` · `system prompt changed (+N chars)` · `tools changed (+A/-B tools)` ·
> `tools changed (tool prompt/schema changed, same tool set)` · `cache_control changed (scope or
> TTL)` · `betas changed` · `effort changed` · `defer_loading presence flipped` ·
> `message history mutated at index I/N` · `possible 1h TTL expiry (prompt unchanged)` ·
> `possible 5min TTL expiry (prompt unchanged)` · `likely server-side (prompt unchanged, <5min gap)`

An assertion tells you *that* the prefix changed in a test. This tells you *what* changed, in
production, with the delta in characters. For a 47 k prefix that is currently 100 % miss, that is
the difference between a fix and a hunt.

Two cheap companions from the same code: **latch the cache TTL decision in session state** so a
mid-session config flip cannot invalidate the prefix (`claude.ts:404-405` says the cost is ~20 k
tokens), and **freeze the date**. grok freezes `current_date` at build time; Claude Code freezes
`currentDate` inside a `memoize`d `getUserContext` (`context.ts:155`), with the same known cost of
being wrong past midnight. Two of four references make the same trade; it is the settled answer.

### 5. Stop clearing the system-message cache every turn — *moderate, fully portable*

`TurnPipeline.clear_message_caches/0` (`turn_pipeline.ex:157-163`) fires at every user turn. Claude
Code clears its equivalent **only on `/clear` and `/compact`** (`constants/systemPromptSections.ts:65`),
at *section* granularity, and marks exactly one section as deliberately uncached — `mcp_instructions`,
because MCP topology changes between turns (`constants/prompts.ts:513-520`).

That last detail is the whole design: find the one or two things that genuinely change, mark those,
and cache everything else. OSA's 21 dynamic block builders (`context.ex:468-503`) running per ReAct
iteration even on a cache hit (`react_loop.ex:1824`) is the opposite policy — everything is treated
as volatile because a few things are.

### 6. Finish `WorldState`'s diff contract — *moderate, and OSA is closest to the finish line here*

The brief says `WorldState` has no counterpart in grok and is strictly better as a transmission
discipline. Both halves hold. But codex **has** one, and it is ahead in two specific ways worth
copying:

- `render_diff(previous) -> Option<Fragment>` (`core/src/context/world_state/mod.rs:56-62`) —
  returning `None` for "unchanged, emit nothing" as the *primary* contract, not an optimisation.
- **Append-only supersession.** `REPLACEMENT_NOTICE` / `REMOVAL_NOTICE`
  (`core/src/context/world_state/agents_md.rs:9-11`): a changed AGENTS.md does not rewrite the old
  fragment, it appends a new one that says the old no longer applies. History is therefore
  append-only by construction, and strict-prefix holds without anyone asserting it.

That second point is the elegant part, and it is the one thing in this document that OSA could adopt
without touching latency at all and still gain: it makes cache-prefix stability a property of the
data structure rather than a discipline anyone has to maintain.

### 7. Cheap, unranked, take them anyway

- **`hasMarkdownSyntax()`** — Claude Code runs one regex over the first 500 chars and skips
  `marked.lexer` entirely for plain prose (`components/Markdown.tsx`, `MD_SYNTAX_RE`), saving ~3 ms
  per call by its own comment. Directly applicable to OSA's measured 1 256 µs prose case.
- **Exclude tmux from the DEC 2026 probe** — Claude Code does, on the grounds that tmux parses and
  proxies every byte without implementing 2026 (`ink/terminal.ts:67-104`). If OSA's probe does not,
  that is a correctness bug, not a preference.
- **`desiredHeight` / `availableHeight` flicker telemetry** — Claude Code emits `tengu_flicker` with
  both, rate-limited to one per second, whenever a frame could not fit. This is the second reference
  (after grok's `desired_height` trait) to arrive at the same instrumentation independently.
- **Deadline-clamp instead of post-hoc floor** — codex's `clamp_deadline`
  (`tui/src/tui/frame_rate_limiter.rs:23-31`) is unconditional, which means it has no
  "stream-only batches" carve-out to get wrong, unlike OSA's conditional floor at
  `app/event_loop.rs:1391-1411`.
- **Widget-owned repaint cadence** — codex's status indicator reschedules itself at 32 ms
  (`status_indicator_widget.rs:245-246`) instead of the app running a global tick. OSA's 200 ms tick
  exists to animate one spinner and repaints everything to do it.

## 4c. Not portable / do not adopt

- **`tool_reference` blocks and native `ToolSpec::ToolSearch`.** Both depend on server-side support
  OSA cannot assume across providers. Adopt the policy, not the transport.
- **Collapsing the TUI/backend split.** codex runs the pager and agent in one process; Claude Code
  is one Node process. OSA's separate TUI binary over HTTP+SSE is a product decision and the SSE
  stream is opened once per session, so the per-turn tax is one localhost POST. It is not in the
  15–20 s. Leave it.
- **codex's `WorldState` extension API surface** (`codex_extension_api::WorldStateSectionContribution`
  etc.) — real, but it exists to let plugins contribute sections. OSA has no such requirement yet and
  it would be scaffolding without a building.
- **codex's adaptive line-commit chunking** (`streaming/chunking.rs`) — genuinely interesting, and
  the hysteresis constants are pre-tuned, but it *adds* display lag to buy evenness. That is a
  product taste decision, and it should not be made as a side effect of a latency workstream.

## 4d. Where OSA is already right

Stated so it does not get re-litigated:

- `Soul.static_base/1` memoized in `persistent_term` — this is exactly what Claude Code's
  `TOOL_SCHEMA_CACHE` and codex's `immutable_spec` are for. OSA already has the pattern; it just has
  not applied it to tools or to `Context.build`.
- `WorldState` — no grok counterpart, and codex's twin is ahead only on the `Option` contract and
  append-only supersession. The concept is right.
- **DEC 2026 synchronized output** — all three references use it; OSA already does.
- **Submit → paint at 13–17 ms** — the TUI is not the problem in any of the four harnesses, and OSA's
  is measured in the same band. Everything in this document is behind the paint.
- **Escape-aware width, two-level sanitizer, band arbiter, PTY harness** — beat grok's, and nothing
  in codex or Claude Code displaces them. Claude Code's Ink fork is a React reconciler writing ANSI
  through a throttle; it has no equivalent of the band arbiter at all.
- **Open-fence re-parse and unterminated-span reflow** — real defects, but **universal**. Neither
  codex nor Claude Code solves either. grok's resumable syntax state is the only prior art for the
  first, and there is no prior art at all for the second.
