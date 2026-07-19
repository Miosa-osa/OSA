# Context Compactor

Intelligent sliding-window context compaction with importance-weighted retention. Runs as a GenServer that records metrics; the actual compaction logic is pure functions safe to call from any process.

**Module:** `OptimalSystemAgent.Agent.Compactor`

---

## When Compaction Runs

`Compactor.maybe_compact/1` is called in two places:

1. At the start of every `process_message` call (before the loop).
2. On context overflow error during the loop (up to 3 overflow retries).

The function is safe — it never raises. On any error it returns the original message list unchanged.

---

## Three Zones

Messages are divided into zones based on position from the end of the non-system message list:

| Zone | Positions (from end) | Treatment |
|------|----------------------|-----------|
| HOT | Last 20 messages | Never touched — always verbatim |
| WARM | Messages 21–50 | Progressive compression pipeline |
| COLD | Messages 51+ | Collapsed to a single key-facts summary |

System messages are separated before zoning and prepended back after compaction.

---

## Activation Thresholds

| Threshold config key | Default | Severity | Pipeline target |
|---------------------|---------|----------|-----------------|
| `:compaction_warn` | `0.85` | `:background` | 70% of max tokens |
| `:compaction_aggressive` | `0.85` | `:aggressive` | 60% of max tokens |
| `:compaction_emergency` | `0.95` | `:emergency` | 50% of max tokens |

Note: warn and aggressive share the same default, so in practice the first trigger hits both. The targets reduce the conversation to 70%, 60%, or 50% of the context window depending on severity.

---

## Progressive Compression Pipeline

Steps run sequentially. After each step the token count is checked — the pipeline stops as soon as usage drops below the target. Steps that are no longer needed are skipped.

**Step 1 — Strip tool-call argument details**

Replaces the `arguments` field on every tool call in the WARM zone with `"[args stripped]"`. Keeps the call name and result so the LLM knows what was done without the verbose input payloads.

**Step 2 — Merge consecutive same-role messages**

Merges adjacent `user`–`user` or `assistant`–`assistant` messages by concatenating their content with a newline. Does not merge messages that have `tool_calls` or `tool_call_id` fields. On merge, takes the higher importance score.

**Step 3 — Summarize warm-zone message groups (LLM call)**

Groups warm-zone messages by importance score (lowest first) into chunks of 5. Each group with more than 200 tokens is sent to the LLM for summarization using the `compactor_summary` prompt template (fallback hardcoded). The summary replaces the group as a single `system` role message with `[Warm Summary]` prefix and importance `1.5`. Groups that fail LLM summarization are kept verbatim.

**Step 4 — Compress cold zone to key facts (LLM call)**

Sends all cold-zone messages to the LLM using the `compactor_key_facts` prompt template (fallback hardcoded). The LLM extracts decisions made, user preferences, key data/results, and commitments. The result replaces the entire cold zone as a single `system` message with `[Context Summary]` prefix and importance `2.0`. On LLM failure, falls through to step 5.

**Step 5 — Emergency truncate**

No LLM call. Keeps only the HOT zone (last 20 messages). Prepends a topic notice to the system messages: `[Context truncated due to length. Earlier conversation was about: <user message excerpts>]`. This is a last resort — the topic notice is extracted from the first 100 characters of each dropped user message.

---

## Importance Scoring

Each non-system message is annotated with an importance score before the pipeline runs. Higher scores resist compression:

| Factor | Bonus/Penalty |
|--------|--------------|
| Base score | `1.0` |
| Has tool calls | `+0.5` |
| Role is `"tool"` (tool result) | `+0.3` |
| Content length / 500 (capped) | `+0..0.3` |
| Content matches acknowledgment pattern | `-0.5` |

Acknowledgment patterns: `ok`, `okay`, `sure`, `thanks`, `thank you`, `got it`, `yes`, `no`, `yep`, `nope`, `k`, `kk`, `alright`, `cool`, `nice`, `great`, `perfect`, `noted`, `ack`, `roger`, `👍`, `👌`.

The minimum importance score is `0.1`.

The warm-zone step sorts messages by importance ascending before grouping, so the least important messages are summarized first.

---

## Token Estimation

Uses the Go tokenizer (`OptimalSystemAgent.Go.Tokenizer.count_tokens/1`) for accurate BPE counts when available. Falls back to:

```
words * 1.3 + punctuation_chars * 0.5
```

For message lists, each message adds 4 tokens of framing overhead. Tool call arguments are counted separately as `name_tokens + arg_tokens + 4` per call.

---

## LLM Calls

Both summary LLM calls use `MiosaProviders.Registry.chat/2` (the default configured provider):

| Call | Temperature | Max tokens |
|------|-------------|------------|
| `call_summary_llm/1` (warm zone) | `0.2` | `400` |
| `call_key_facts_llm/1` (cold zone) | `0.1` | `512` |

In test environments, `:compactor_llm_enabled` can be set to `false` to disable LLM calls and return stub summaries instead.

---

## Metrics

The GenServer records compaction metrics via `handle_cast({:record_compaction, tokens_saved, step})`:

```elixir
Compactor.stats()
# Returns:
# %{
#   compaction_count: integer,
#   tokens_saved: integer,
#   last_compacted_at: DateTime.t() | nil,
#   pipeline_steps_used: %{step_name => count}
# }
```

---

## Public API

```elixir
Compactor.maybe_compact(messages)
# Returns possibly-compacted message list. Never raises.

Compactor.utilization(messages)
# Returns float (0.0–100.0) — percentage of max_tokens used.

Compactor.estimate_tokens(messages_or_string)
# Returns non_neg_integer token count estimate.

Compactor.stats()
# Returns compaction metrics map.
```

---

## This-Cycle Additions (Wave 2b/2c)

The pipeline above is the original 3-zone/5-step design. This cycle added a
grok/opencode-parity layer of quality and continuation improvements on top of
it — see `docs/BACKLOG.md` for commit references. Config keys below are
Elixir application env; see
[Configuration → Agent Behavior](../../getting-started/configuration.md#compaction).

**Verbatim latest-user-query preservation** — the most recent `role: "user"`
message across the full history is wrapped in `<user_query>...</user_query>`
tags and prepended to any LLM-generated summary, completely untouched by the
summarizing model — mirrors grok `summary.rs:143 wrap_user_query`. This
guarantees the user's actual last ask is never paraphrased away by a
compaction pass.

**Token-budgeted, turn-aware tail selection** — `preserve_recent_budget/0`
replaces a fixed message-count tail with a token budget: 25% of the usable
context window, clamped to `[2_000, 8_000]` tokens by default, or an explicit
positive-integer override via `compaction_preserve_recent_tokens`. Mirrors
opencode's `compaction.ts select`/`splitTurn` and grok's `select.rs
select_tail`.

**Prune tier** (non-LLM, opencode `PRUNE_PROTECT`/`PRUNE_MINIMUM`/
`PRUNE_PROTECTED_TOOLS` parity) — walks tool-result messages newest-first,
accumulating a running token estimate of their still-intact output.
Everything within `compaction_prune_protect_tokens` (default `40_000`) stays
untouched; once that budget is crossed, every OLDER tool result's output is
erased outright (replaced with a short "N tokens reclaimed" marker) rather
than summarized. Protected tool names (`compaction_prune_protected_tools`,
default `["skill", "use_skill", "find_skill", "save_skill", "create_skill",
"list_skills", "task_write", "exit_plan_mode", "enter_plan_mode"]`) are never
counted against the budget and never erased. The tier only mutates anything
when the reclaimable total exceeds `compaction_prune_minimum_tokens`
(default `20_000`) — a partial win below that isn't worth a compaction pass.

**Media-strip + overflow replay** — on a context-overflow LLM error, media
(image) blocks are stripped from messages (`strip_media_from_messages/1`)
before the request is retried, up to the existing 3-overflow-retry cap. This
is a cheap, high-signal reclaim step that runs before falling through to
heavier compaction.

**Divide-and-conquer chunk summarization** — oversized zones are chunked at
`compaction_chunk_token_limit` (default `3_000` tokens) per chunk for
summarization, instead of one unbounded LLM call over the whole zone.

---

## Post-Compaction Auto-Continue

**Module:** `OptimalSystemAgent.Agent.Loop.ProactiveCompaction` (gate),
wired in `react_loop.ex`

When a compaction pass actually changes the message list mid-turn, the loop
sets `state.just_compacted` (and `state.just_compacted_overflow` when the
compaction was triggered by a context-overflow error rather than a proactive
threshold). If `ProactiveCompaction.continuation_enabled?/0` is true, the
loop auto-continues the turn on the freshly-compacted context instead of
silently returning a (possibly truncated) response — the model gets to
finish what it was doing with a smaller but still-coherent context, rather
than the compaction pass being the last thing that happens in the turn. The
flags are cleared as soon as the model continues on its own.

See also: [loop.md](loop.md), [context.md](context.md), [goal-orchestration.md](goal-orchestration.md)
