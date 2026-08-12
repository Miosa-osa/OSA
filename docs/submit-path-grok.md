# Submit path: grok-build vs OSA

**Question:** what happens between the user pressing enter and the first token appearing?

**Reference:** `~/projects/research/grok-build-src` @ `75e73f3d` (2026-08-09). Crates cited as
`crates/codegen/<crate>/src/...`.
**OSA:** `~/projects/osa/OSA` @ `2c85f445` (v1.0.83), read as written — not measured. The
Hermes lane owns OSA's real timings.

Everything below is a **sequence**, not a review. Where grok does the same work OSA does, the
interesting fact is almost always *where* it does it, not *whether*.

---

## Part 1 — grok's sequence, submit → first token

### Stage 0. The TUI, before anything is sent

grok's pager is a `tokio::select!` loop (`xai-grok-pager/src/app/event_loop.rs:2310`) whose input
arm calls `drain_and_process`, which routes the key into a **pure** `dispatch(Action, &mut AppView)
-> Vec<Effect>`. Dispatch performs no I/O at all. Effects are executed afterwards, separately.

| # | Step | file:line | Cost |
|---|---|---|---|
| 0.1 | Enter in the composer resolves to `Action::SendPrompt(text)` | `app/agent_view/prompt.rs:494-560` | pure |
| 0.2 | `dispatch_send_prompt` → `dispatch_send_prompt_inner` | `app/dispatch/prompt.rs:172`, `:417` | pure; one `unified_log::info` |
| 0.3 | Slash-registry resolution (only if text starts with `/`) | `app/dispatch/prompt.rs:524-730` | in-memory registry; MRU persistence is explicitly queued off-thread (`:619-620`) |
| 0.4 | Plain prompt: `enqueue_prompt_with_skill_tokens` → local queue | `app/dispatch/prompt.rs:881-883` | pure |
| 0.5 | `maybe_drain_queue(agent)` — idle agent drains in the **same dispatch call**, no deferred tick | `app/dispatch/queue.rs:216`, called at `prompt.rs:927` | pure |
| 0.6 | Drain: push the user bubble into scrollback, `start_turn_boundary` → `AgentState::TurnRunning`, `turn_started_at = Instant::now()`, `scrollback.follow_new_turn` | `app/dispatch/queue.rs:357-402`, `app/agent_view/session.rs:510-521` | pure |
| 0.7 | Drain returns `Effect::SendPrompt { agent_id, session_id, text, prompt_id, … }` | `app/dispatch/queue.rs:470-478` | pure |
| 0.8 | Event loop takes `app.pending_effects` and calls `process_effects` | `app/event_loop.rs:2320-2325` | — |
| 0.9 | `effects::execute` → `tasks.spawn(async move { … acp_send(req, &tx).await … })` | `app/effects/mod.rs:1083-1137` | **spawned; the UI thread never awaits it** |
| 0.10 | `presenter.request(false)` → draw | `app/event_loop.rs:2350-2353`, `:394-409` | one frame |

So the indicator is painted **in the same frame as the keystroke**, from state that dispatch already
mutated. The status line is driven off `AgentState::TurnRunning` + `TurnActivity`, and while waiting
it renders `Thinking…` / `Waiting…` with a live elapsed counter
(`views/turn_status.rs:660-730`). Draw cadence is capped at 16 ms
(`xai-grok-shell/src/util/config/resolve/display_refresh.rs:12`, applied at
`app/event_loop.rs:378-391`).

**OSA does the same thing, correctly.** `priv/rust/tui/src/app/handle_actions.rs:602-712`:
`add_user_message`, `transition(AppState::Processing)`, `activity.start()`, then
`tokio::spawn` for `client.orchestrate(&req)`. Nothing blocking. The measured 13–17 ms paint is
consistent with this. **The TUI is not the problem in either harness.** Everything below is behind
the paint.

One transport difference: grok's "ACP send" is an in-process `mpsc` + `oneshot` round trip
(`xai-acp-lib/src/channel.rs:34-58`) — the pager and the agent are the same OS process on a
`LocalSet`. OSA's TUI is a separate binary posting to the Elixir backend over HTTP and reading SSE
(`priv/rust/tui/src/client/http.rs`, `client/sse.rs:92`). The SSE stream is opened once per session
(`app/handle_actions.rs:1410-1434`), not per turn, so the per-turn tax is one localhost POST. That
is real but it is milliseconds — it does not explain 15–20 s.

---

### Stage 1. What is assembled ONCE, at session start

This is the load-bearing part of the whole comparison.

There are **two** once-only assemblies, and between them they absorb everything OSA recomputes.

**(a) `AgentBuilder::build()`** — `xai-grok-agent/src/builder.rs:671`. This runs at session spawn (or
an explicit agent rebuild) and does:

- decrypt the prompt template — the templates ship as XOR-obfuscated byte arrays
  (`xai-grok-agent/src/prompt/prompt_encrypted.rs:6`, seeds `:14`), decrypted by
  `template.rs:17-51`. No `OnceLock`; it re-decrypts, but only here.
- **read AGENTS.md / rules from disk** — `builder.rs:1079-1083`
- **`git2::Repository::discover` + gitignore build** — `builder.rs:1090-1093`
- **scan skills** — `builder.rs:676-683`, seeded into the bridge at `:1142-1152`
- freeze `build_timestamp_utc` and `current_date` into the `PromptContext` — `builder.rs:1162-1185`
- render the whole system prompt through MiniJinja — `builder.rs:1186-1189` →
  `xai-grok-agent/src/prompt/context.rs:262-301`
- store it as a plain `String` on the `Agent` — `agent.rs:34`, read-only accessor `agent.rs:110`

The only three non-test readers of `.system_prompt()` are `spawn.rs:1093` and
`model_switch.rs:92`/`:171`. **None is on the turn path.**

`agent_ops.rs:4698-4715` then sends `SessionCommand::Initialize { system_prompt }`, and the session
actor's `initialize` (`xai-grok-shell/src/session/acp_session_impl/session_setup.rs:35-49`) writes it
to disk once and installs it as `conversation[0]`. Per turn it is item 0 with `Arc<str>` content
(`prompt_build.rs:229`) — a refcount bump.

**(b) The deferred environment prefix**, below.

Immediately after, the run loop spawns the **deferred prefix**:

```rust
SessionCommand::Initialize { system_prompt } => {
    session.initialize(system_prompt).await;
    let s = session.clone();
    let handle = tokio::task::spawn_local(async move { s.build_prefix_background().await });
    session.deferred_prefix.arm(handle);
}
```
— `session/acp_session_impl/run_loop.rs:562-569`

`build_prefix_background` (`session_setup.rs:94-111`) → `build_user_message_prefix`
(`acp_session_impl/prompt_build.rs:467-509`) → `build_templated_user_message`
(`prompt_build.rs:516-586`) is where **all** the environment discovery lives:

- MCP handshake wait, bounded 3 s (`acp_session_impl/mcp_snapshot.rs:247-322`)
- `git2::Repository::discover` + `git_status_short` / `jj_status`, 2 s timeout
  (`prompt_build.rs:526`, `:590-618`)
- `read_agents_config_with_paths` — AGENTS.md / vendor `.claude` / `.cursor` rule files
  (`prompt_build.rs:527`, partitioned at `:37-68`)
- skill registry listing (`prompt_build.rs:553`)
- MCP server + gateway enumeration (`prompt_build.rs:554`, `:633-690`)
- shell + OS detection (`prompt_build.rs:555`, `:557`)

The first prompt awaits it exactly once:

```rust
pub(super) async fn ensure_prefix_ready(&self) {
    let Some(mut handle) = self.deferred_prefix.take() else { return };   // ← take(): once per session
    …timeout(10s)… conversation.insert(insert_at, ConversationItem::user(prefix));
}
```
— `session_setup.rs:114-176`, called from `run_loop.rs:612`

`take()` means the second and every later turn hit the `return` on line 116 and pay **zero**. By the
time a human has typed a prompt, the background task has long finished, so even turn 1 usually pays
nothing.

**(c) Tool schemas — generated once, at registration and finalize.**

- `schemars` JSON-Schema generation per tool at registration time:
  `xai-grok-tools/src/registry/types.rs:1921-1935` (`generate_schema<T>()`), called at `:612` and,
  for MCP, `:1837`.
- The wire-ready `ToolDefinition` — description interpolation, schema-description rendering,
  truncation patching — is materialized once at **finalize**: `registry/types.rs:1151-1185`, run from
  `xai-grok-tools/src/bridge.rs:70-93`, i.e. once per `AgentBuilder::build()`.

The per-turn call just clones the finished structs:

```rust
pub fn tool_definitions_builtins_only(&self) -> Vec<ToolDefinition> {
    self.tools.read().iter()
        .filter(|t| !t.client_name.contains("__"))
        .map(|t| t.definition.clone())
        .collect()
}
```
— `xai-grok-tools/src/registry/types.rs:1391-1398`

No reflection, no schema generation, no JSON walk. `serde` serializes at HTTP body time.

**How many tools actually go on the wire: ~31.** The `grok-build` preset is 19 entries
(`xai-grok-agent/src/config.rs:263-287`) plus 12 workspace tools (`config.rs:176-194`).
That `!t.client_name.contains("__")` filter on line 1394 excludes **every MCP tool from the sent
list entirely**. MCP is reached through two always-present tools instead — `search_tool`
(`xai-grok-tools/src/implementations/search_tool/mod.rs:1`) returns a matching tool's
`input_schema` on demand (`xai-tool-runtime/src/search.rs:22-26`), and `use_tool`
(`implementations/use_tool/mod.rs:1-20`) dispatches by qualified `server__tool` name. The index is
BM25, rebuilt per search call and documented as sub-ms
(`xai-grok-shell/src/session/tool_index.rs:1-6`).

Notably, plan-mode tool filtering is currently a **no-op** —
`filter_cursor_tools_by_plan_mode` ignores `_plan_active`
(`xai-grok-shell/src/session/acp_session_impl/session_mode.rs:25-30`). grok enforces plan/readonly at
the permission layer, not by reshaping the schema list. The only real per-turn filter is dropping
`web_search` under backend search (`sampler_turn.rs:139-146`).

---

### Stage 2. Per turn, shell side

`session/prompt` arrives on the session actor's command channel
(`run_loop.rs:596`). In order:

| # | Step | file:line | Cost |
|---|---|---|---|
| 2.1 | `ensure_prefix_ready()` | `run_loop.rs:612` | **no-op after the first turn** (`session_setup.rs:115-117`) |
| 2.2 | `queue_input(...)` then `maybe_start_running_task` | `run_loop.rs:668-687` | in-memory queue |
| 2.3 | `handle_prompt(...)` | `acp_session_impl/turn.rs:241` | — |
| 2.4 | `ensure_session_disk_writable()` | `turn.rs:283` → `acp_session_impl/updates.rs:358-361` | **early-returns unless a disk-full flag is already latched.** Free in the normal case |
| 2.5 | slash-skill resolve + `command_availability()` | `turn.rs:315-325`, `acp_session.rs:1193` | in-memory (skills already loaded; disk reload is driven by the fsnotify watcher at `run_loop.rs:204-211`) |
| 2.6 | user-echo `SessionNotification` emitted to the client | `turn.rs:548-566` | channel send — **this is when the user's bubble is confirmed, before any model work** |
| 2.7 | `parse_prompt_with_skills`, image normalize, truncation | `turn.rs:567-651` | pure unless images attached |
| 2.8 | persistence: `persistence_tx.send(PersistenceMsg::ContentChunk(...))` | `turn.rs:663-667` | **unbounded channel, fire-and-forget** |
| 2.9 | `chat_state_handle.push_user_message(user_chat)` | `turn.rs:823` | actor message, no disk |
| 2.10 | `UserPromptSubmit` hook dispatch | `turn.rs:828-836` | only if hooks configured |
| 2.11 | `process_conversation_turn_with_recovery` → `process_conversation_turn` | `turn.rs:855`, `:1522`, `:1895` | — |
| 2.12 | `prepare_tool_definitions_timed()` | `turn.rs:1936` → `acp_session_impl/sampler_turn.rs:111-135`, `:210-215` | clone of prebuilt structs + a plan-mode filter |
| 2.13 | reminders: MCP / date-rollover / plan-mode / interjections / monitor events | `turn.rs:2075-2091` | in-memory string pushes |
| 2.14 | `first_turn_memory_reminder()` | `turn.rs:2079` → `turn.rs:1668` | **first turn only**, and a block persisted by an earlier segment is reused verbatim rather than re-searched |
| 2.15 | `refresh_token_if_expired()` | `turn.rs:2101` → `sampler_turn.rs:1204` | in-memory unless actually near expiry |
| 2.16 | `check_auto_compact_needed()` | `turn.rs:2105` → `compaction.rs:1868-1885` | token estimate from cached counters |
| 2.17 | `turn_base_tool_specs(&tool_definitions)` | `turn.rs:2121-2126` → `sampler_turn.rs:138-146` | one filter + `ToolSpec::from` map |
| 2.18 | `chat_state_handle.build_request(...)` | `turn.rs:2138-2152` → `xai-chat-state/src/handle.rs:334`, actor arm `actor/mod.rs:285-304` | one actor round trip; integrity repair + assembly |
| 2.19 | `PhaseChanged { WaitingForModel }` emitted | `turn.rs:2185-2196` | client sees the phase before the HTTP call |
| 2.20 | `run_turn_via_sampler(request)` → `submit_and_collect` | `turn.rs:2203` → `sampler_turn.rs:1142-1160`, `xai-grok-sampler/src/handle.rs:113` | **network** |

Nothing in 2.1–2.19 touches disk or the network in the steady state. The residual I/O is all gated:

- `load_effective_config()` → `ConfigLayers::load()` (`xai-grok-config/src/loader.rs:419-463`) is a
  real uncached disk read, but it is reached only from (i) the JWT-near-expiry branch
  (`sampler_turn.rs:1326`) and (ii) `notification_drain.rs:161`, which is explicitly guarded to fire
  only when **≥2 prompts are queued** — the comment on `notification_drain.rs:153-160` says it
  "keeps the single-prompt promote off disk". A normal single prompt never reads config.
- `UserPromptSubmit` hooks (`turn.rs:826-834`) dispatch non-blocking and short-circuit when the event
  isn't registered (`hook_dispatch.rs:238-248`).
- The durable user-message flush barrier (`turn.rs:790-822`, `PersistenceMsg::FlushAndAck` awaited at
  `:808`) runs **only when the caller passed `persist_ack`**; otherwise `push_user_message` is
  fire-and-forget (`turn.rs:824`).
- Auth token minting is memoized per model (`sampler_turn.rs:238-260`) and only touches the network
  on cold cache or near-expiry.
- Image persistence to the session assets dir (`turn.rs:715-727`) only for image-bearing prompts.
- The `Blocking` MCP strategy makes only the *first* prompt wait (`sampler_turn.rs:113-121`), and the
  wait is measured and logged as `mcp_wait_ms` (`turn.rs:1937`, `:1946`).

---

### Stage 3. Provider → screen

| # | Step | file:line |
|---|---|---|
| 3.1 | HTTP stream opens → `SamplingEvent::StreamStarted` | `xai-grok-sampler/src/events.rs:31-34` |
| 3.2 | first content → `SamplingEvent::FirstToken` | `events.rs:37` |
| 3.3 | `SamplingEvent::ChannelToken { channel, text, chunk_index }` | `events.rs:40-46` |
| 3.4 | session translates: `handle_sampling_event` → `Event::PhaseChanged{StreamingText}` + `send_update(AgentMessageChunk)` | `session/acp_session_impl/tool_calls.rs:2547`, `:2570-2600` |
| 3.5 | pager receives on the ACP arm of the select loop; batches up to 32 ready messages, cut short if input arrives | `app/event_loop.rs:2177-2207`, `ACP_DRAIN_BATCH_MAX` at `:1841` |
| 3.6 | `acp/tracker.rs` appends to the streaming block | `acp/tracker.rs:803-805` |
| 3.7 | `presenter.request_throttled(now, 16ms)` → draw | `app/event_loop.rs:2209-2218` |

TTFT is recorded as a span field (`sampler_turn.rs:1162-1166`) and the whole pre-model window is
logged explicitly as `shell.handle_prompt.done { pre_turn_ms }` (`turn.rs:940-951`) and
`shell.turn.inference_start { elapsed_since_turn_start_ms }` (`turn.rs:2192-2199`). grok instrumented
exactly the number this investigation is about.

### Is there a fast path for a turn that needs no tools?

**No — and grok doesn't need one.** There is no branch that skips tool preparation or context
assembly for a text-only answer; the only emptiness handling is at wire level
(`tools: if tools.is_empty() { None } else { Some(tools) }`,
`xai-grok-sampling-types/src/conversation/responses.rs:154`). Every turn ships the full list. It
doesn't matter because the list is ~31 prebuilt structs and the per-turn cost is a `Vec` clone plus
one actor round trip. grok removed the cost instead of adding a bypass around it.

### Does grok pay a per-turn cost proportional to tool count and prompt size?

Proportional to tool **count**, yes — twice: `tool_definitions_builtins_only`
(`registry/types.rs:1391`) clones N structs once per user turn, and `turn_base_tool_specs`
(`sampler_turn.rs:138`) deep-clones the schema `Value`s once per *sampler loop iteration*. But each
unit is a struct clone, not a schema build, and N ≈ 31 rather than the hundreds OSA reflects over.
Proportional to prompt **size**, only at `serde` body-encode time, which is unavoidable for any
harness.

The two levers grok pulled are therefore *both* multiplicative: it made each unit cheap (prebuilt
structs) **and** it made N small (MCP off the wire behind `search_tool`).

The thing grok does *not* do is rebuild the prompt content. The system prompt is a string installed
once at `conversation[0]`; the environment prefix is a string built once in the background and
inserted once at `conversation[1]`. Both then ride along as ordinary conversation items forever.

Where grok *isn't* perfect: `turn_base_tool_specs` deep-clones each schema `serde_json::Value` and is
called **per sampler loop iteration**, not once per user turn (`turn.rs:2121-2126`), and
`run_turn_via_sampler(request.clone())` clones the whole request (`turn.rs:2211`). With ~31 tools
that is invisible; it would not be at OSA's schema volume.

### Stage 4. Prefix stability is an enforced invariant

This is the part most directly relevant to OSA's known 100% prompt-cache miss. grok treats the static
prefix as something that must be **byte-identical across turns**, and defends it in code and tests:

- `assert_prefix_stable` — "request N's serialised input must be a strict prefix of N+1" —
  `xai-grok-sampling-types/src/conversation/test_support.rs:152-156`, `:217-231`.
- Cache breakpoints are placed deliberately: `apply_cache_breakpoints`
  (`conversation/messages.rs:43-70`, invoked `:279`) marks the last system block, the conversation
  tip, and the previous-request boundary, and **deliberately leaves the 4th slot free** for gateway
  auto-caching (`messages.rs:39-42`). `mark_message_cache_breakpoint` (`messages.rs:6-37`) skips
  `Thinking` blocks the API rejects.
- The system prompt's `current_date` is **frozen at build time** (`builder.rs:1162-1185`). Midnight
  rollover is handled by a one-shot *user-side* `system-reminder` rather than re-rendering the
  prefix, with the reason stated inline: "the cached `<user_info>` prefix keeps its startup date to
  preserve the prompt cache" (`reminders.rs:495-520`).
- Memory context is not re-injected when already present — "skipping re-injection to preserve prompt
  cache" (`turn.rs:1692-1698`).
- Image eviction is batched near the 50 MB ceiling rather than per turn, because "eviction rewrites
  earlier turns and busts the KV-cache prefix… the original behavior — evicting every turn — caused
  chronic cache misses" (`xai-chat-state/src/actor/request_builder.rs:63-85`).
- Compaction head replacement carries the same note: "a changed head invalidates the KV prefix"
  (`xai-chat-state/src/commands.rs:164`).
- `prompt_cache_key` is left `None` for the main turn (`request_builder.rs:141`) and set to the
  session id for auxiliary side calls so they replay under the parent's key
  (`side_call.rs:52-75`).
- Cache accounting is first-class: `cached_prompt_tokens` (`conversation.rs:728`), accumulated
  `turn.rs:101`, reported `turn.rs:2345`, `:2373`, `:2406-2409`.

---

## Part 2 — the diff against OSA, as written

OSA's equivalent stages, from `Loop.run_and_reply/2` and `ReactLoop.run/1` outward. All file:line in
`lib/optimal_system_agent/` unless noted.

### 2a. What OSA does that grok does not do at all

| # | OSA does | file:line | grok's equivalent |
|---|---|---|---|
| **1** | **Writes a rewind checkpoint before the turn** — `File.mkdir_p!` + `Jason.encode!` of the *entire sanitized message history* + tmp-write + rename + prune, at the top of `handle_call({:process, …})` | `agent/loop.ex:1149` → `agent/loop/checkpoint.ex:396`, `:422-430` | nothing. grok's rewind points are written **after** the turn (`turn.rs:919-931`) |
| **2** | **`GenServer.call` to `FSCheckpoint.Server` (5 000 ms default) whose handler shells out to git**, inside that checkpoint | `agent/loop/checkpoint.ex:654-655` → `fs_checkpoint/server.ex:85-86`, `:177-180` | nothing on the path |
| **3** | **Synchronous SQLite insert of the user turn + `SessionTitler.ensure_title/2`** before the request | `agent/loop/turn_pipeline.ex:218`, `:438-446`; `store/session_transcript.ex:34-55` | fire-and-forget `persistence_tx.send` (`turn.rs:663`); the durable flush is post-turn (`turn.rs:919`). grok only blocks on persistence when a caller explicitly asks for `persist_ack` (`turn.rs:791-812`) |
| **4** | **Synchronous HTTP embedding call before the provider request** — `Memory.Search.embed/1`, `receive_timeout: 5_000` | `agent/memory/search.ex:157-188` (`@embed_timeout` `:104`), reached via `agent/context.ex:1035-1058` → `agent/memory.ex:307-383` | nothing. grok's `first_turn_memory_reminder` runs on the **first** turn only and reuses a persisted block verbatim (`turn.rs:1668`) |
| **5** | **Deliberately invalidates the system-message cache at every user turn** — `clear_message_caches/0` deletes `:osa_system_msg_cache`, the git cache and the workspace-overview cache | `agent/loop/turn_pipeline.ex:67`, `:157-163` | grok has no such invalidation; the prefix is `take()`n once and is gone from the path forever (`session_setup.rs:115`) |
| **6** | **Rebuilds tool descriptors reflectively per `Context.build`** — `list_tools_direct/0` `Enum.map`s every builtin calling `mod.name()/description()/parameters()`, sorts twice, then `list_active/0` `Enum.reject`s with a `function_exported?/3` + `mod.deferred?()` per tool and a `should_defer?` per MCP tool | `tools/registry.ex:216-244`, `:77-104`, reached from `agent/context.ex:1290-1330`, `:1364-1370` | `Vec<ToolDefinition>` clone (`registry/types.rs:1391`) |
| **7** | **Re-serializes every tool schema per request, twice** — `SchemaNormalizer.normalize_tools/1` does a full recursive walk of every JSON schema node with no memoization, then `Anthropic.format_tools/1` maps the whole list again | `providers/registry.ex:276`, `:434-449`; `tools/schema_normalizer.ex:87`, `:96-120`; `providers/anthropic.ex:1353-1397` | one `serde` encode of prebuilt structs |
| **8** | **Reads the progress ledger from disk twice per turn** | `agent/loop/message_handler.ex:463` and again `agent/memory/coordinator.ex:122`, both → `agent/progress_ledger.ex:96-102` | no equivalent |
| **9** | **Enumerates and JSON-decodes the whole skill library twice per turn** | `store/skill_library.ex:103-106`, `:128-140`, from `agent/memory/coordinator.ex` (B-phase) and again from `agent/context.ex:1556-1578` | skills are listed once, inside the background prefix (`prompt_build.rs:553`) |
| **10** | **`Path.wildcard("~/.osa/personalities/*.{yaml,yml}")` + YAML parse of each, uncached, plus 4 × `File.stat` signature checks** on every build | `agent/context.ex:529-535` → `personality.ex:120-182`; `settings.ex:52-57`, `:353-367` | nothing |
| **11** | **Blocks up to 2 000 ms on a memory-synthesis yield**, with a *synchronous* memory search as the fallback | `agent/loop/react_loop.ex:358-370`, `:1850-1861` | nothing |
| **12** | **Four more 5 000 ms `GenServer.call`s** — `Memory.Store` ×2, `Agent.Tasks` ×2 | `agent/memory.ex:88`, `:157-179`; `agent/tasks.ex:115-117`, `:255-257` | chat-state is an in-process actor over `oneshot`; the only awaited call is `build_request` (`handle.rs:334`) |

Items 1–4 are on the path **before the ReAct loop even starts**. Items 5–12 repeat **per ReAct
iteration**, because `Context.build/1` is invoked unconditionally at `react_loop.ex:1824` even on a
process-dict cache hit — the cache only reuses the final system *message*, not the 21 block builders
that produced it (`agent/context.ex:468-503`).

### 2b. Where grok does the same work — and where it does it instead

| Work | OSA does it | grok does it |
|---|---|---|
| git branch / status / log | per `Context.build`, ETS-cached 30 s, 3 subprocesses on miss (`agent/context.ex:1421-1470`) | once, in the background prefix task, 2 s timeout (`prompt_build.rs:526`, `:590-618`) |
| AGENTS.md / CLAUDE.md / .cursorrules discovery | per `Context.build` via `ContextDiscovery.discover/1`, ETS-cached 60 s (`agent/context.ex:537-547`; `agent/context_discovery.ex:41-90`) | once, in the background prefix (`prompt_build.rs:527`, partitioned `:37-68`) |
| Nested project-instruction scan | per build when the history has file-touching tool calls (`agent/context.ex:561-651`) | once, same prefix; the AGENTS.md reminder is inserted at `conversation[2]` and left there (`session_setup.rs:143-152`) |
| Workspace/topology detection | reachable from `ContextDiscovery` / `ProjectInstructions`, ETS-cached (`workspace/topology.ex:123-150`) | `git2::Repository::discover` once in the prefix (`prompt_build.rs:545-549`) |
| MCP server enumeration | per `list_active/0` deferral filter (`tools/registry.ex:82-99`) | once in the prefix, bounded 3 s handshake wait (`mcp_snapshot.rs:247-322`); `Progressive` never waits (`sampler_turn.rs:112-124`) |
| MCP tool schemas on the wire | `list_active/0` filters *deferred* MCP tools per call (`tools/registry.ex:82-99`) — the rest still ship | **none ship at all** (`registry/types.rs:1394`); MCP is reached via `search_tool`/`use_tool` over a BM25 index (`search_tool/mod.rs:1`, `use_tool/mod.rs:1`, `tool_index.rs:1-6`) |
| Prompt-cache prefix stability | no enforced invariant; `split_system/2` flattens cache blocks around a live timestamp (known 100% miss) | tested invariant `assert_prefix_stable` (`test_support.rs:217-231`) + frozen `current_date` (`builder.rs:1162-1185`, `reminders.rs:495-520`) + rationed eviction (`request_builder.rs:63-85`) |
| Skill listing | twice per turn from disk (2a #9) | once in the prefix; disk reloads are driven by the fsnotify watcher (`run_loop.rs:204-211`) |
| System prompt string | memoized in `:persistent_term` (`soul.ex:198-214`, `:286-322`) — **OSA is already correct here** | built once at spawn, stored as `conversation[0]` (`agent_ops.rs:4698-4713`, `session_setup.rs:35-49`) |
| Session persistence | synchronous, pre-request (2a #3) | unbounded channel, flushed post-turn (`turn.rs:663`, `:919`) |
| Config load | not on the path | not on the path (`loader.rs:419` reached at startup + watcher only) |
| Auto-compaction check | `Compactor.maybe_compact` pre-turn + proactive check per iteration (`turn_pipeline.ex:236`; `react_loop.ex:279-330`) | cached token counters, one actor read (`compaction.rs:1868-1885`); speculative pass-1 is spawned, not awaited (`turn.rs:2093-2100`) |

The pattern is uniform. **grok does not have less environment context than OSA. It has the same
context, computed once, in a task that starts before the user has finished typing, and then carried
as a plain conversation item.**

### 2c. Goal tracking

`GoalTracker.tick_turn/1` (`agent/loop/react_loop.ex:338` → `agent/loop/goal_tracker.ex:307-324`,
`:768`, `:798`) is ETS read + ETS write, iteration-0 only. It is **not** a problem. grok's
equivalent goal-loop resource set is a comparable no-op (`turn.rs:849-852`). Do not spend effort
here.

Likewise `WorldState.assemble/3` (`agent/context/world_state.ex:213-253`) is genuinely good design
and has no grok counterpart — but it suppresses *re-emission* of stable sections, not their
*computation*. The 21 builders in `gather_dynamic_blocks/1` all still run before the ledger sees
their output.

---

## Part 3 — ranked: what adopting grok's choices would cut

Ranked by expected reduction of OSA's submit→first-token window, with portability called honestly.

### 1. Build the environment prefix once, in a background task, and insert it as a conversation item — *largest win, fully portable*

grok: `build_prefix_background` spawned at `run_loop.rs:563-568`, awaited at most once via
`deferred_prefix.take()` at `session_setup.rs:115`.

OSA: everything in `gather_dynamic_blocks/1` (`agent/context.ex:468-503`) that is *session-stable*
— bootstrap, personality, commands, agent roles, project_context, project_instructions, environment,
git_state, tool_process, skills catalogue — should be computed once per session into a single user
message inserted after the system message, exactly as grok does. `WorldState`'s existing "managed
labels" list (`world_state.ex:88-131`) is almost precisely that set, which means OSA has already
*identified* the stable sections and just doesn't act on it. This removes items 5, 6, 8, 9, 10 from
2a and every row of 2b from the per-iteration path.

Corollary: `TurnPipeline.clear_message_caches/0` (`turn_pipeline.ex:157-163`) should stop dropping
the system-message cache on every user turn, and `Context.build/1` should be genuinely skipped on a
cache hit rather than invoked and discarded (`react_loop.ex:1822-1848`).

### 2. Store built tool descriptors; never reflect or re-serialize per request — *large, fully portable*

grok stores `ToolDefinition` per tool and clones (`registry/types.rs:1391`). OSA calls
`mod.name()/description()/parameters()` per tool per `Context.build` (`tools/registry.ex:216-244`),
then walks every schema node in `SchemaNormalizer.normalize_tools/1`
(`tools/schema_normalizer.ex:87-120`) per request, then maps the whole list again in
`Anthropic.format_tools/1` (`providers/anthropic.ex:1353-1397`).

Given the established 15.5k tokens of tool schemas, that is three full passes over the largest
static structure in the request, on every request, on the BEAM. The fix is a `:persistent_term`
holding the already-normalised, already-provider-shaped tool list, keyed by
`{provider, active_tool_set_digest}`, invalidated on registry change — the same pattern
`Soul.static_base/1` (`soul.ex:198-214`) already uses correctly for the prompt. OSA has the pattern;
it just hasn't applied it to tools.

### 2b. Take MCP tool schemas off the wire entirely, behind a search/use pair — *large, portable, and it shrinks the 15.5k*

grok sends **~31 tool schemas**, period (`config.rs:263-287` + `:176-194`). Every MCP tool is
excluded by `!t.client_name.contains("__")` (`registry/types.rs:1394`) and reached through
`search_tool` — which returns the matched tool's `input_schema` on demand
(`xai-tool-runtime/src/search.rs:22-26`) — and `use_tool`, which dispatches by qualified name
(`implementations/use_tool/mod.rs:1-20`). The index is BM25, rebuilt per call, sub-ms
(`session/tool_index.rs:1-6`).

OSA already has the shape of this: `list_active/0` excludes *deferred* MCP tools
(`tools/registry.ex:82-99`) and `tool_search` is the mid-turn escape hatch. The difference is that
grok's default is "no MCP on the wire" and OSA's is "MCP on the wire unless marked deferred". Making
grok's the default directly attacks the 15.5k-token schema block that item 2 makes cheaper to build
but does not make smaller.

### 3. Get the synchronous embedding HTTP call off the path — *large, fully portable*

`Memory.Search.embed/1` (`agent/memory/search.ex:157-188`) is a network round trip with a 5 000 ms
`receive_timeout` issued *before* the provider request. grok makes no network call between receiving
a prompt and issuing the provider request. Either move recall to the async prefetch that already
exists (`react_loop.ex:341-350`) and let the turn proceed without it, or gate it the way grok gates
its memory reminder — first turn only, reusing a persisted block (`turn.rs:1668`).

### 4. Make pre-turn persistence fire-and-forget — *large, portable with care*

OSA writes the rewind checkpoint (whole history, `Jason.encode!` + rename, `checkpoint.ex:422-428`),
calls `FSCheckpoint.Server.head()` (5 000 ms `GenServer.call` whose handler shells out to git,
`fs_checkpoint/server.ex:177-180`), inserts the user turn into SQLite, and runs the session titler —
all before the request. grok sends persistence messages down an unbounded channel (`turn.rs:663`)
and flushes after the turn (`turn.rs:919`); it blocks only when a caller explicitly requests
`persist_ack` (`turn.rs:791-812`).

The care: OSA's rewind semantics need a durable pre-turn boundary. grok's answer is that the
*boundary* is a cheap marker and the *content* is written asynchronously. `FSCheckpoint.Server.head()`
in particular should be a cached value refreshed by the fs watcher, not a synchronous git shell-out
serialised behind any in-flight 30 s snapshot.

### 5. Stop reading the same file twice per turn — *moderate, trivially portable*

`ProgressLedger` is read at `agent/loop/message_handler.ex:463` and again at
`agent/memory/coordinator.ex:122`. The skill library is enumerated and JSON-decoded at
`store/skill_library.ex:103-106` from both `Memory.Coordinator` and `agent/context.ex:1556-1578`.
Both are pure duplication. This is small next to items 1–4 but it is free.

### 6. Drop the 2 000 ms blocking yield — *moderate, portable*

`Task.yield(memory_task, 2_000)` with a synchronous fallback (`react_loop.ex:358-370`) can add two
seconds to a turn that gains nothing from it. grok's nearest analogue —
`wait_for_mcp_templated_prefix_ready` — is bounded at 3 s but sits inside the *background* task
(`mcp_snapshot.rs:287-306`), so it never delays a turn.

### 6b. Make prefix stability a tested invariant — *not a latency saving on OSA's own path, but it converts the whole 47k prefix into a cache hit*

This one is worth calling out separately because it is cheap and OSA's prompt cache is a **known 100%
miss** — `split_system/2` flattens the cache blocks around a microsecond timestamp. grok's answers,
all portable:

- freeze `current_date` in the prefix at build time and handle midnight with a one-shot user-side
  reminder instead of re-rendering (`builder.rs:1162-1185`, `reminders.rs:495-520`)
- place cache breakpoints deliberately and leave one slot free
  (`conversation/messages.rs:39-70`)
- never re-inject content that is already present (`turn.rs:1692-1698`)
- batch, don't per-turn, anything that rewrites earlier turns (`request_builder.rs:63-85`)
- **assert it in a test**: `assert_prefix_stable` — request N's serialised input must be a strict
  prefix of N+1 (`test_support.rs:152-156`, `:217-231`)

Items 1 and 2 above are prerequisites: a prefix that is rebuilt per turn cannot be byte-stable.

### 7. Instrument `pre_turn_ms` — *not a saving, but the thing to do first*

grok logs `shell.handle_prompt.done { pre_turn_ms, total_elapsed_ms, turn_elapsed_ms }`
(`turn.rs:940-951`) and `shell.turn.inference_start { elapsed_since_turn_start_ms }`
(`turn.rs:2192-2199`) as first-class fields, plus `tool_prep_done { mcp_wait_ms, total_prep_ms }`
(`turn.rs:1943-1954`) and `build_request_done { build_request_ms }` (`turn.rs:2153-2160`). OSA has
`Observability.turn_start/1` but no equivalent decomposition of the pre-model window. The Hermes
lane is measuring this by hand right now; grok's answer is that it should be a permanent field.

### Not portable / do not adopt

- **grok's in-process TUI↔agent channel** (`xai-acp-lib/src/channel.rs:34`). OSA's TUI is a separate
  binary over HTTP+SSE and that is a product decision (remote sessions, desktop, Canopy). The hop is
  localhost and small; it is not where 15–20 s lives. Do not restructure for this.
- **grok's scrollback model.** Out of scope by prior decision.
- **`Soul.static_base/1`.** Already memoized in `:persistent_term` (`soul.ex:198-214`) with lazy
  invalidation (`:314-333`). This is *better documented* than grok's equivalent, which just leaves a
  string in `conversation[0]`. Leave it alone — the system prompt string is not the problem; the
  21 dynamic blocks around it are.
- **`GoalTracker.tick_turn/1`** (`goal_tracker.ex:307-324`). ETS-only, iteration-0 only. Not a cost.
- **`WorldState`** (`agent/context/world_state.ex`). No grok counterpart and strictly better as a
  *transmission* discipline. The fix is to make the block builders honour the same stable/dynamic
  split, not to replace WorldState.
- OSA's escape-aware width function, two-level sanitizer, band arbiter priority ladder, and PTY
  harness are all ahead of grok's equivalents (grok has no escape-aware width at all). Nothing in
  this document touches them.

---

## Summary

grok's submit path is thin because of one decision applied consistently: **anything that can be
computed from the session rather than the turn is computed once, in a task spawned at session
creation, and then carried as an ordinary conversation item.** The turn itself clones a `Vec`,
makes one actor round trip, and issues the HTTP request.

OSA's submit path is thick because the mirror-image decision was made: `Context.build/1` runs per
ReAct iteration, the cache that would have saved it is explicitly cleared at every user turn
(`turn_pipeline.ex:157-163`), and even a cache hit still invokes the builder
(`react_loop.ex:1824`). On top of that sit four things grok has nothing comparable to: a
whole-history checkpoint write, a git-shelling `GenServer.call`, a synchronous SQLite insert, and a
synchronous embedding HTTP call — all before the provider request.

The tool-schema story is the sharpest single contrast, and it is two failures stacked: grok pays one
struct clone per tool across **~31 tools** (MCP is off the wire entirely, behind `search_tool`);
OSA pays a reflective rebuild per `Context.build` plus two full schema walks per request, over
~15.5k tokens of schemas, every time.

And because nothing in OSA's prefix is stable across turns, none of that 47k is eligible for the
provider prompt cache — which grok protects with a frozen build-time date, deliberate cache
breakpoints, and a test that asserts request N's serialised input is a strict prefix of N+1.
