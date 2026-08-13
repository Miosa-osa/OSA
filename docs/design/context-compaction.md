# Context compaction

Status: design specification. Describes what OSA's context-compaction subsystem
should be, what it already is, and the ordered path between the two.

**The problem in one sentence:** a long-running agent will always run out of
context window, and the only question is whether the moment it happens is a
controlled, instrumented, recoverable fold — or a provider 400 followed by a
blind scramble to throw away whatever is largest.

All file:line citations are OSA's, relative to the repository root. Where this
document describes a mechanism OSA does not have yet, it specifies the mechanism
directly. A reference harness that already ships a mature version of this
subsystem was studied while writing it; its mechanisms are described here in our
own words, in enough detail to build from this document alone.

**Contents**

- Part 1 — What compaction has to get right
- Part 2 — The mechanism, in full
  - 2.1 The trigger
  - 2.2 Anti-thrash: suppression, not hysteresis
  - 2.3 What is sent to the summarizer
  - 2.4 What is preserved
  - 2.5 The summary prompt
  - 2.6 Extracting the summary safely
  - 2.7 Failure handling and the input ladder
  - 2.8 Rebuilding the conversation
  - 2.9 Iteration and summary-of-summary
  - 2.10 Offloading the pre-compaction transcript
  - 2.11 Durable notes before the rollover
  - 2.12 Prompt-cache interaction
  - 2.13 Two-pass and prefire
  - 2.14 Recap — the adjacent mechanism
- Part 3 — Where OSA stands today
- Part 4 — Gaps and defects
- Part 5 — Target design for OSA
- Part 6 — Implementation plan
- Appendix — the numbers, in one place

---

# Part 1 — What compaction has to get right

Compaction is destructive and irreversible from the model's point of view. Once
the transcript is folded, the detail is gone from the window; nothing the agent
does later can recover it unless we deliberately left a path back. That makes
six properties non-negotiable.

1. **The denominator must be real.** The trigger fraction is meaningless if the
   window it is a fraction *of* is a guess. OSA has already been burned by this
   exactly once, and the scar tissue is documented in
   `lib/optimal_system_agent/agent/loop/context_window.ex:9-29`: the compactor
   read a flat 128k default and was never handed the per-model window, so on a
   1M-token model a full LLM summarization pass fired at roughly 11% occupancy,
   repeatedly, each one permanently destroying fidelity.

2. **Firing must be cheaper than not firing.** A compaction costs one LLM
   round-trip in the tens of seconds, blocks the turn, and loses information. It
   must fire late enough to be rare and early enough that the summarization
   request itself still fits in the window with room for its output.

3. **It must not thrash.** A compaction that fails, or that succeeds without
   getting under the line, must not immediately re-fire. This needs an explicit
   latch and an undershoot margin, not a prayer.

4. **The bands must be well-ordered.** Whatever thresholds exist —
   warn, flush, compact, block — must be provably monotonic across the entire
   range of context windows OSA supports, including the small local ones.

5. **Continuity must be seamless.** The successor turn must resume mid-stream
   without asking the user anything, without recapping, and without re-reading
   files it already read.

6. **The pre-compaction transcript must survive somewhere.** Not in the window —
   on disk, addressable, and ideally readable by the agent itself with the tools
   it already has.

---

# Part 2 — The mechanism, in full

The reference harness does **full-replace** compaction. It never selects a tail
to keep and discards the rest: it summarizes the whole conversation and then
rebuilds a fresh history from a fixed template. That distinction matters for
everything below.

## 2.1 The trigger

**The number is 85%, not 80%.** Compaction fires when estimated total tokens
reach 85% of the model's context window. That default is overridable through a
five-tier precedence chain, resolved at session start *and again on every model
switch*:

    environment variable
      > per-model user config
      > global user config
      > per-model remote/fleet setting
      > global remote/fleet setting
      > compiled-in default (85)

Values outside `0..=100` are rejected with a debug log rather than clamped, so a
typo cannot silently disable compaction.

The comparison is scaled integer arithmetic, never floating point:

    fires when:  used * 100 >= context_window * threshold_percent

with a `false` short-circuit for a zero window. The `>=` is deliberate and
regression-tested: at a 1000-token window and 85%, the gate fires at exactly
850, one token earlier than a `>` gate. Display percentages are computed
separately and rounded half-up, so the meter and the gate agree to within one
point without the gate inheriting float drift.

**The denominator is the real per-model window**, read from the resolved
sampling config as a non-zero integer. A fixed 256k fallback appears in exactly
two places, both paths where the sampling config is structurally absent rather
than merely unknown. A debug environment variable can pin the window for
testing; nothing else fabricates one.

**Four independent gates fire compaction**, all before the model call except the
third:

| Gate | When | Condition |
|---|---|---|
| Pre-sampling | Start of every turn, before the request is built | `used >= threshold%` of window |
| Preflight overflow | After tool results are appended, before the next request | `used > window` outright |
| On-error | After a provider error | Provider-reported window present, and the estimate exceeds it |
| Model switch | First turn after the model changes | Previous window recorded, new window smaller |

The pre-sampling gate additionally honours a debug force flag (consumed by
compare-and-swap so it fires exactly once) and refuses to fire while a memory
flush is in progress.

Token accounting is `bytes / 4` for text, a flat 765 per image, plus a separate
estimate of the serialized tool schemas — which matters, because the tool block
is a fixed multi-thousand-token tax on every request and a compactor that
ignores it under-counts by exactly the amount it can least afford. The running
figure is "exact provider-reported count as of the last response, plus a
byte-estimate of everything appended since", so tool results that have not yet
been through a round-trip are still counted.

## 2.2 Anti-thrash: suppression, not hysteresis

There is no hysteresis band and no cooldown timer. Instead there is a five-state
suppression latch, and the states differ in *what clears them* — which is the
part worth stealing, because "retry later" is the wrong answer for most
compaction failures:

| State | Set by | Cleared by |
|---|---|---|
| `none` | — | — |
| `turn` | A resolvable failure | Next turn start (self-heals) |
| `sticky` | A size or schema failure retrying can never fix | Only a change in the context budget: a successful compaction, a rewind, or a model switch to a larger window |
| `until-success` | A billing/credit block, which the client cannot observe directly | A successful model call returning 200 |
| `auth` | An expired credential | Login or token refresh — deliberately *not* "until a 200", because waiting for a sample deadlocks when the context is already over the window |

Manual compaction ignores the latch entirely. Every automatic gate checks it
first and early-returns.

Separately, an in-flight compaction is guarded by a **cancel gate with holder
counting** rather than a boolean, because a background pre-pass and a
foreground compaction can overlap: the first entrant installs a cancellation
token, nested entrants share it (including a token already cancelled by a user
stop), and the gate goes idle only when the last holder drops. A stop request
while idle is a no-op rather than a poisoned token for the next compaction.

## 2.3 What is sent to the summarizer

Three input preparations exist, and they form a **ladder** (§2.7). The default is
the *most* expensive one, for a non-obvious reason.

**Stage 1 — verbatim (the default).** Tool calls, tool results, and images are
kept byte-for-byte. Reasoning blocks are stripped only for backends that reject
replayed reasoning. Any trailing assistant turn with unanswered tool calls is
popped so strict backends do not see a dangling call.

The reason verbatim is the default is **prompt caching**: the summarization
request's prefix then byte-matches the live turn's prefix, so the whole
conversation is served from cache and the extra input tokens are nearly free.
The full tool schemas are sent along for the same reason, even when tool choice
is set to `none` — only the `tool_choice` field differs from the live request.
Trading input tokens for a cache hit is the right trade, and it only degrades
when the provider actually rejects the size.

**Stage 2 — verbatim, fitted.** The same shape, shrunk to a budget by dropping
*oldest whole turns*. The leading system item is always kept and its cost
subtracted from the budget first. The start index is then advanced past any
leading tool result so a result never leads the conversation. If nothing fits,
a recovery path keeps the most-recent turn anyway: it pulls the trailing
tool-result run plus its owning assistant turn and splits the remaining budget
evenly across the results (minimum 1 token each). Per-item truncation converts
tokens to bytes at 4:1, reserves 64 bytes for the marker, cuts at a character
boundary, and appends an explicit `[... truncated N bytes to fit the compaction
window ...]`.

**Stage 3 — lossy rewrite.** Three transforms composed:
- Every tool result is **dropped entirely**, and each assistant's tool calls are
  flattened into an appended text annotation `[Called tools: name1, name2]`
  before the call list is cleared. This is the big lossy step.
- All reasoning blocks are dropped — mandatory here, because the text mutation
  above invalidates signed thinking blocks and strict providers 400 on them.
- Every image is replaced with the literal text `[image]`.

An **image budget** is applied to every compaction request regardless of stage:
eviction triggers at 47 MiB of request body and reclaims down to 25 MiB, against
a 50 MiB request ceiling, with the limits reduced by the tool-schema reserve.

There is **no separate system prompt for the compaction call.** The summarization
instruction is appended as the final *user* turn, and the session's own system
prompt rides along verbatim at index 0. That is what keeps the prefix cacheable.

## 2.4 What is preserved

**The recent-turn boundary is semantic, not positional.** It is the index of the
last *real* user turn — where "real" excludes synthetic injections. A user item
is synthetic if, after stripping a fixed list of wrapper tags (user info,
project layout, git status, fork context, system reminder, agent memory,
background context, command name/message/args, rules), the remaining text is
empty, or it is the auto-continue sentinel, or it is the exact auto-continue
prompt text. Injected system-reminder turns therefore do not move the boundary,
which is precisely what prevents an orphaned tool result in the compacted
output.

Everything from that boundary forward is kept **verbatim**, with one
modification: tool-result *bodies* are replaced with the literal
`Tool call omitted...` and their images dropped, while the `tool_call_id` is
retained so pairing still validates.

Preserved out-of-band, rebuilt fresh at fold time into a **system reminder**:

- Files edited this session (the full set).
- Discovered project-instruction files.
- Available skills.
- Running background tasks — with real task IDs, no fabricated prefixes, and
  the tool names needed to poll and kill them (resolved dynamically; if the
  names cannot be resolved the whole section is omitted rather than emitted with
  placeholders).
- The TODO list — pending and in-progress items rendered **verbatim with id and
  status**, completed and cancelled collapsed to counts.
- Running sub-agents, with type, description, and elapsed time.
- Connected MCP servers with tool counts and sanitized, truncated descriptions,
  plus a hint to call the search tool before the call tool.
- A **memory recovery search** keyed on the last user query, top 3 results.
- Plan-mode state, spliced in if plan mode is active.

Note that todos and plan state survive *only* through this reminder — the
summary prompt is never asked to carry them.

**Large tool outputs are handled separately and earlier**, by a non-LLM pruning
tier that runs in the band below the compaction threshold: it walks tool results
newest-first, protects everything within a token budget, and erases the bodies
of everything older, with a protected-tool allowlist that is never counted and
never erased. A session full of tool spam gets cheap relief before it pays for a
summarization.

## 2.5 The summary prompt

The summary is **model-generated**, text-only, never a tool call. It runs
through the session's own sampling client, with an option to point compaction at
a cheaper dedicated model. No special reasoning-effort setting is passed.

The prompt is **structured, not free prose**. Its shape:

- **A framing paragraph.** The successor will see the user's original query plus
  this summary and nothing else. Capture explicit requests, most recent actions,
  key technical details, file paths, commands, configuration, architectural
  decisions. Then, crucially, an *economy* instruction: prefer tight prose and
  short references over long verbatim dumps; do not pad; a focused summary that
  fits is far more useful than an exhaustive one that gets cut off; aim for at
  most a few thousand words. This paragraph is doing real work — without it the
  model produces a summary that itself needs compacting.
- **An optional user-context splice**, for `/compact <instructions>`.
- **A carry-forward clause**, marked CRITICAL: if the earlier turns already
  contain a prior compaction summary — recognisable by its tags or its
  "This session is being continued" preamble — treat it as authoritative for the
  early history and carry its still-relevant content into the new summary. This
  one sentence is the entire defence against generational drift.
- **An output contract.** Think in private reasoning; emit no separate analysis
  block; put the final summary inside a single summary block; include every
  section heading even when empty, writing "None"; respond with *only* that
  block and nothing after its closing tag.
- **Nine numbered sections:**

| § | Demands |
|---|---|
| 1 | Primary request and intent — every explicit request, with nuance, constraints, scope boundaries, stated preferences |
| 2 | Key technical concepts — technologies, languages, frameworks, libraries, tools, patterns |
| 3 | Files and code sections — every file examined, created, or modified; full path, why it matters, and the **actual code**, with the most recent edits in full rather than described |
| 4 | Errors and fixes — every error, failed command, test/build failure; root cause; exact fix; **user-supplied corrections recorded verbatim** |
| 5 | Problem solving — solved problems, plus in-progress diagnosis and hypotheses still open |
| 6 | All user messages — every non-tool-result user message, in order, explicitly excluding the compaction instruction itself ("a system-generated compaction prompt, not a real user message") |
| 7 | Pending tasks — only tasks the user actually asked for; "do not invent tasks the user never requested" |
| 8 | Current work — precisely what was happening immediately before the fold, with recent file names, code, commands, state, specific enough to resume mid-stream |
| 9 | Optional next step — the single step continuing the most recent work, strictly in line with the latest explicit request; if the task was finished, say to confirm with the user instead; when a step exists, include a **direct verbatim quote** from the most recent messages showing where work left off, "so the task is interpreted without drift" |

- **An anti-tool-call guard.** The prompt explicitly names the on-disk segment
  store (§2.10) as an out-of-band channel intended for a *future* agent, and
  forbids the summarizer from reading it or emitting read/grep/list calls
  against it.

## 2.6 Extracting the summary safely

The model's raw output is cleaned in three steps before it becomes the
successor's memory, and each step exists because of a specific failure:

1. **Peel leading scratchpad blocks** in a loop. "Leading" means top-level before
   the summary block, or immediately after the summary open modulo whitespace.
   An analysis tag quoted *mid-body* — which happens constantly, because section
   6 asks the model to list all user messages and one of them may quote the
   instruction — is **not** stripped. An unclosed leading scratchpad drops
   everything up to the next summary open, or to the end. An untagged markdown
   "**Analysis**" header is peeled too, unless the block already starts with a
   numbered section.
2. **Unwrap the summary block** using `find` for the open tag but **`rfind` for
   the close**, so a closing tag echoed inside the body cannot truncate the
   summary.
3. **Neutralize control tokens** echoed in the body by inserting a zero-width
   space after the `<` of every summary/analysis/summary-request open and close
   tag — closers first, so the sentinel never re-matches. They are *defused*,
   not deleted, so the text still reads correctly to a human. This treats the
   compaction prompt's own vocabulary as an injection surface: a summary that
   quotes its instructions cannot prime the successor turn to re-emit a summary
   block.

Then runs of three or more newlines collapse to two, and the result is trimmed.

## 2.7 Failure handling and the input ladder

Three attempts, three seconds apart, with per-attempt classification:

- **Usable, non-degenerate** → win immediately.
- **Empty or whitespace** → transient, retried.
- **Degenerate** — the *cleaned* summary is shorter than **500 characters**.
  Treated exactly like a transient failure and retried. (The constant is
  documented against production data: a degenerate band observed at 75–264
  characters, and the smallest healthy production summary at ~3,242.)
- **Deterministic sampler error** (auth, schema, request build) → short-circuits
  with no retry.
- **Context-length overflow** → forced deterministic *and* flagged separately.
  Detection is substring matching on the lowercased message against a fixed
  list of provider phrasings, because backends sometimes dress an overflow as a
  synthesized 500. HTTP classification: 4xx other than 408/429 is deterministic,
  5xx/408/429 transient, and an overflow message is deterministic regardless of
  status.

The overflow flag drives the **input ladder**, which is the mechanism that keeps
compaction possible on a near-full window:

    Verbatim  ──overflow──▶  VerbatimFitted   budget = window − 32_768 − tool_tokens
    VerbatimFitted ──overflow──▶  Lossy       budget = window × 0.7 − tool_tokens
    Lossy ──overflow──▶  terminal: sticky size suppression

The conversation is **re-fetched live** at each rung, each transition emits a
degradation event naming the from- and to-stage, and the terminal case latches
sticky suppression so the session does not loop on an incompactable state.

**Output too long is not an error.** The prompt asks for economy; if the stream
hits its stop reason the result is flagged truncated but still used.

Two independent clocks bound the operation: a per-chunk **idle timeout**, and a
**wall-clock budget of 300 seconds** checked inside every stream loop, which
fails the compaction with an explicit "runaway generation" message. A
configured budget below 120 seconds logs a warning but is not clamped. The
end-to-end sampling timeout is deliberately *disabled* in favour of these two.

Every attempt is recorded — index, outcome, output length, the rejected text
(bounded to 8,192 characters, head and tail around an elision marker), and the
error — and the whole request is persisted as a JSON artifact next to the
session so the prompt can be iterated offline against real failures. This is
cheap and it is the difference between "compaction sometimes produces garbage"
and a fixable bug.

If every attempt fails, the conversation is left **untouched**. Losing a turn is
recoverable; a bad fold is not.

## 2.8 Rebuilding the conversation

```
[ system message                       ]  original, verbatim
[ user-message prefix        (meta)    ]  user_info / project layout
[ project instructions       (optional)]  re-injected verbatim, deduplicated
[ last real user query, re-wrapped     ]  raw text inside <user_query> tags
[ messages since that query, verbatim  ]  tool-result bodies elided, IDs kept
[ the summary                (meta)    ]  continuation preamble + summary + pointer
[ live-state system reminder (optional)]
```

Two details matter.

**The summary is a user-role message, not a system block and not a new role.**
It is tagged *meta* internally so the UI can render it as a boundary rather than
as something the user typed, but on the wire it is a user turn. This is the
right call: mid-conversation system messages are accepted by some models and
rejected with a 400 by others, so the portable shape is a user turn whose text
announces what it is. The preamble reads "This session is being continued from a
previous conversation that ran out of context. The summary below covers the
earlier portion of the conversation."

**The project-instructions block is re-injected independently of the
summarizer**, not recovered from the summary. Whether the model remembered to
mention `AGENTS.md` is not allowed to matter.

The rebuilt history is then **validated and repaired** against the provider
invariant "every tool result has a *preceding* matching assistant tool-call ID":

1. A read-only validator returns the offending IDs.
2. A sanitizer strips unmatched tool results in a single left-to-right pass,
   collecting assistant tool-call IDs as it goes. The reverse — an assistant
   tool call with no result — is deliberately *not* stripped, since it is a
   legitimate in-flight state.
3. A stricter three-pass repair exists for harder cases: deduplicate duplicate
   results, strip *displaced* results (a result must sit in the contiguous run
   immediately after its declaring assistant, not merely somewhere later), then
   backfill synthetic results for unanswered calls.

**Auto-continue.** After an automatic compaction a synthetic user turn is pushed:
"Continue the conversation from where it left off without asking the user any
further questions. Resume directly — do not acknowledge the summary, do not
recap what was happening, do not preface with 'I'll continue' or similar. Pick
up the last task as if the break never happened." It is explicitly excluded from
real-user classification, so it cannot move the boundary of the *next* fold.

**The user sees all of this.** Distinct notifications fire for started (carrying
tokens used, window, percentage, and a human reason string), completed (tokens
before, tokens after, elapsed ms, optional preview), failed, and
cancelled-by-user. A pre-compaction hook is dispatched with the trigger source
so user hooks can react or inject context.

## 2.9 Iteration and summary-of-summary

Long sessions compact repeatedly. Drift is bounded by three things, none of them
clever:

1. **The carry-forward clause** (§2.5) — the new summary is explicitly told to
   treat a previous summary as authoritative for early history and fold it in.
2. **A summary counter** threaded into the rebuild, so the Nth summary can be
   labelled and the model knows it is not the first.
3. **The transcript pointer** (§2.10) — the summary itself tells the agent where
   the verbatim history lives. Generational drift stops being fatal when
   generation N can still recover generation 1's exact text.

## 2.10 Offloading the pre-compaction transcript

Three modes, each with a different pointer sentence appended to the summary:

- **`summary`** (default) — no pointer. The fold is final.
- **`transcript`** — names the raw append-only session log on disk and tells the
  model to read it for exact snippets, error messages, or content it generated.
- **`segments`** — points at a `compaction/` directory of clean per-segment
  markdown plus an `INDEX.md` table of contents, tells the model to use its own
  read and grep tools to recover specifics, and tells it not to modify the
  files.

The segment store is what converts compaction from lossy into merely *paged*:

- One markdown file per compaction, `segment_NNN.md`, zero-padded, flat.
- Opens with a `# HISTORICAL -- DO NOT EDIT` banner naming the index and detail
  level.
- Then metadata (index, turn count, timestamp).
- Then an **always-present statistics block**, computed in one walk: turn count
  broken down by role; tool-name frequency sorted descending with a name
  tie-break; the unique set of target files touched (read from a fixed list of
  file-shaped argument keys, capped at 8 with an "…and N more" tail); a count of
  tool errors detected by content prefix; an estimate of what a fully verbose
  render would cost in bytes; and a one-line excerpt of the last assistant
  message.
- Then the curated summary.
- Then, unless detail is `none`, the verbatim turns at one of four detail
  levels: `none` (stats and summary only), `minimal` (a one-line tool-call
  signature per turn), `balanced` (full text capped at 2,000 chars, tool args
  and responses capped at 500), `verbose` (everything).
- The verbatim section is capped at **512 KB**, truncated at a whole-turn
  boundary with a notice naming the limit and how many turns were dropped. The
  budget is computed after reserving the preamble and the notice itself.

`INDEX.md` is a five-column table — segment, file, turn count, approximate
bytes, keywords — appended incrementally. Keywords are extracted heuristically
from the summary's "Current Work" section, falling back to the whole summary:
identifier-shaped tokens, minus a stopword list built from the prompt's own
vocabulary, deduplicated, capped at eight. It is a grep hint, not an index in
the database sense, and that is enough.

Reads of these paths are classified and counted, so "how often does the agent
actually page history back in" is a measurable number rather than a hope.

## 2.11 Durable notes before the rollover

The single highest-leverage mechanism in the subsystem: **write knowledge to
durable memory while the evidence is still verbatim in the window.**

A memory flush fires at `threshold% of window − 4,000 tokens` — on a 256k window
that is ~83.4%, comfortably before the 85% fold. It runs at most once per
compaction cycle; the latch is a stored compaction count, and the counter is
incremented *before* the check so the first eligible flush is not suppressed. A
snapshot of the conversation is taken synchronously before compaction can mutate
it, then the flush runs on a spawned task. Auto-compaction is suppressed while
the flush is in flight, so the flush's own model call cannot recurse.

The flush is its own model call with its own system prompt and **no tools
offered**. Its input window is the last 20 messages of the lossy-rewritten
conversation, with the start index walked backward to land on a user boundary.

The prompt asks for a concise markdown summary under `##` headers covering:
decisions and rationale; technical context (architecture, APIs, patterns, tools,
file paths); debugging techniques and tools discovered; problems and solutions.
It excludes environment preferences (OS, shell, editor — "these belong in global
memory") and any ephemeral progress section. And it has a **sentinel**: respond
`NO_REPLY` if nothing genuinely useful was learned, because a routine task that
followed standard patterns is not worth persisting.

Subsequent flushes in the same session use a **delta prompt** that receives the
previous flush's output after a `--- Previous flush content ---` marker and is
told to extract only what is new.

Output is quality-gated: empty or `NO_REPLY` (normalized to lowercase
alphanumerics) is dropped; the text is truncated to 8,000 characters; and it
must contain a markdown header or it is rejected outright. Then it passes an
**embedding-based semantic duplicate check** — embed, kNN the vector index with
limit 3, convert L2 distance to cosine, skip the write if any similarity exceeds
**0.92**. Every failure path in the dedup check fails *open*, so a sick embedder
never blocks a write.

Accepted content is appended to a per-day, per-trigger markdown log under a
project-scoped memory directory, then chunked and embedded into the search
index. It comes back three ways: a one-shot first-turn memory-context reminder
(top 6, snippets capped at 500 chars, skipped if such a block is already present
so the prompt cache is not disturbed), the post-compaction recovery search in
the system reminder (§2.4), and the model's own memory-search tool. A separate
consolidation pass later folds accumulated daily logs into a long-term memory
file and deletes the processed ones.

## 2.12 Prompt-cache interaction

Compaction and prompt caching are in direct tension, and the honest answer is
that the reference harness does **not** try to preserve a cached prefix across a
compaction. It cannot: the rebuilt conversation replaces everything after the
system message, so the prefix is invalidated by construction. What it does
instead is (a) make the *steady state between* compactions cache efficiently,
and (b) make the compaction call itself a cache hit (§2.3).

Cache breakpoints are placed at **three of the four available slots**:

1. The last block of the system prompt. Marking only this is not enough on its
   own — an entry is written at a breakpoint, so a system-only breakpoint leaves
   the entire transcript uncached.
2. The **tip** — the last message that can carry a breakpoint, found by scanning
   backwards and skipping thinking blocks, which the API rejects breakpoints on.
   A plain-text message is promoted to block form to carry one.
3. The **previous user turn**, found by walking back from the tip to the last
   assistant message and then to the user message before *that* — deliberately
   skipping the whole trailing run of user messages, since one turn can append
   several. This covers the case where a turn appends more content than the
   API's block lookback window.

The fourth slot is left free on purpose, so a gateway that enables automatic
caching can take it; five breakpoints are rejected outright.

The consequence for compaction: **the system prompt must be byte-identical
across the fold**, and anything volatile — a timestamp, a turn counter,
working-tree state — must live outside every cached region.

## 2.13 Two-pass and prefire

The latency problem: at the moment compaction fires, the conversation is at its
largest, and summarizing it is the slowest call in the session.

The answer is to start early and speculatively. A **prefire** background pass
begins when usage reaches `threshold − lead`, where the lead defaults to **10
percentage points** — so 75% by default. It runs under a single-slot in-flight
guard claimed by compare-and-swap, so the per-turn check can never spawn two.

The conversation is split by **token weight, not message count**: a split index
is chosen so the prefix carries at least 95% of the estimated weight, then
**snapped to tool-call boundaries** so a call is never separated from its
results. The 5% tail is kept deliberately small, because pass-2 latency is
dominated by tail prefill.

Pass 1 summarizes the prefix into an intermediate note. Pass 2, at compaction
time, runs over `[system] + [note carrier] + [verbatim tail] + [special final
turn]`, producing the successor-visible summary — only pass-2 output is ever
shown.

Details worth copying:

- Pass 1 bails early with a named outcome if the conversation is shorter than 4
  items, or if either side of the split is empty.
- The note is the **last** summary block whose inner text exceeds 1,000
  characters, else the whole raw response; capped at 12,000 characters with an
  explicit truncation marker so pass 2's input budget is bounded.
- The note is embedded **twice** — once in a carrier user turn, once in the
  final instruction — because the final instruction needs it adjacent to the
  demand that it be fully incorporated.
- The **two-pass prompt is a 5-section variant** (primary request, key technical
  concepts, errors and fixes, problem solving, next step). Files/code, all user
  messages, pending tasks, and current work are dropped because they are already
  covered by the pass-1 prefix summary or the verbatim tail.
- The final turn declares the situation explicitly — "you are writing the final
  compaction note that a successor assistant will rely on as their only memory"
  — and demands the entire prior note be incorporated: do not omit sections, do
  not defer with "see prior compaction", do not drop early history just because
  newer turns are in context; merge both into one coherent self-contained
  summary preserving concrete values, file paths, errors, blockers, operational
  how-tos, findings, and pending tasks.
- The cached note is used **only if a fingerprint of the prefix still matches** —
  a hash over item count plus, per item, a variant tag byte and its text. Any
  edit, rewind, or branch changes the fingerprint. It is also invalidated on
  model switch. On mismatch the session silently falls back to single-pass.
- If compaction fires while pass 1 is still running, pass 2 **awaits** it rather
  than discarding it, and folds the wait into the time-to-first-token metric,
  since the user really is blocked.
- If pass-2 output is degenerate, it falls back to single-pass.
- Prefire outcomes are stable telemetry keys (`cached`, `disabled`, `too_small`,
  `empty_split`, `sample_failed`, `empty_note1`) so speculative spend — hit rate
  and wasted input tokens — is measurable before it is scaled up.

Both two-pass and the memory flush ship **disabled by default** in the agent
policy. They are built, instrumented, and dark.

## 2.14 Recap — the adjacent mechanism

Worth naming because it is often confused with compaction and is not compaction.
A **recap** is a one-sentence "where was I" line, produced by an LLM side-call,
display-only, and it **never mutates the conversation**. It fires on an explicit
command or on return-from-away (idle ≥ 3 minutes, at least 3 real turns, and a
turn-count watermark that advanced).

It reuses compaction's budgeting utilities: window capped at 500k, prompt budget
= 85% of that minus 4,000 tokens, and the instruction is *appended* to the
verbatim conversation rather than sent as its own system prompt — again for
cache warmth. Its watermark is **healed after compaction**: when compaction or
rewind shrinks the turn count below the stored watermark, the watermark is reset
rather than left in the future, which would suppress recaps forever.

OSA does not have this, and it is not on the critical path. It is listed here so
the interaction (watermark healing) is not rediscovered later as a bug.

---

# Part 3 — Where OSA stands today

OSA v1.0.90. This subsystem is further along than its reputation. The honest
summary is that OSA has most of the *pieces* and two of the *architectures*.

## 3.1 The denominator is fixed on the decision path — verified, not assumed

The historical 128k-denominator bug is **genuinely fixed where it mattered**.

- `lib/optimal_system_agent/agent/loop/context_window.ex:42-58` — `resolve/1`
  returns `{:ok, tokens} | :unknown`, built on the registry variant that admits
  ignorance, and "never raises, and never falls back to a hardcoded number."
- `lib/optimal_system_agent/agent/compactor.ex:272-280` — `resolve_window/1`
  consults `:max_context_tokens` **only as an explicit operator override with no
  default**, so unset yields `:unknown`, never a fabricated 128k.
- `lib/optimal_system_agent/agent/compactor.ex:236-245` documents the policy:
  when the window is `:unknown` and `:force` is not set, compaction **does
  nothing and returns the messages unchanged**, deferring to the reactive
  overflow path. That is a better answer than the reference's 256k fallback, and
  it is well argued in the source.
- `lib/optimal_system_agent/agent/loop/react_loop.ex:270-284` goes further and
  budgets against the *effective* window rather than the trained one, so a local
  model served at a 32k `num_ctx` ceiling is not budgeted at its 262k advertised
  window.

Four hardcoded 128k sites remain elsewhere, and one of them still reaches prompt
assembly — see §4.1.

## 3.2 Thresholds are reserve-based, not fractional

`lib/optimal_system_agent/agent/loop/compaction_thresholds.ex:20-58`:

    effective  = window − min(configured_reserve, 20_000)   # :122-132
    compact_at = effective − 13_000                         # :34-43
    warn_at    = compact_at − 20_000                        # :48-51
    block_at   = effective − 3_000                          # :55-58

with ratio fallbacks (0.75 / 0.60 / 0.90) when the reserve math would collapse
on a small window. Concretely: 1M → 967k (96.7%); 200k → 167k (83.5%);
128k → 95k (74%); 32k → 24k (75%, ratio path).

`Compactor.severity_for/2` (`compactor.ex:290-300`) maps usage onto
`:none | :background | :aggressive | :emergency` from the same thresholds, and
`compactor.ex:282-285` is explicit that there is no second ratio ladder.

## 3.3 There are two compaction engines, and both run every turn

This is the central structural fact about OSA's implementation.

| | Engine A — pipeline | Engine B — proactive |
|---|---|---|
| Module | `Agent.Compactor` | `Loop.ProactiveCompaction` |
| Entry | `maybe_compact/4` | `should_compact?/2` → `compact/3` |
| Fires | Once per user turn, before the turn (`turn_pipeline.ex:236`), plus `/compact` (`loop.ex:1272-1287`) and the 413 retry (`react_loop.ex:1395-1401`) | Mid-turn, **every ReAct iteration** (`react_loop.ex:286-306`) |
| Shape | Six-step ladder, deterministic before LLM | Full fold to one summary |
| Routed | Yes, via `ContextEngine.Router` (default `Agent.Compactor`, `router.ex:131`) | No — always runs |

**Engine A's pipeline** (`compactor.ex:665-671`) runs each step only while still
over target:

    micro_compact → strip_tool_args → merge_consecutive
      → summarize_warm → compress_cold → emergency_truncate

It has zoning (HOT = a token-budgeted tail, WARM = the 50 messages before it,
COLD = older), importance scoring (`compactor.ex:1155-1180`), a pinned-importance
sentinel at 1000.0 (`compactor.ex:176`) so a summary it just produced is not
destroyed by a later positional step, and tool-boundary-safe splits via
`CompactionSafety.safe_split_index/2` (`compactor.ex:966, 1054, 1119`).

**Engine B** splits at `role: "user"` boundaries keeping the last 4 turns
(`proactive_compaction.ex:57, 471-496`), summarizes the older span with a
nine-section prompt (`:75-108`), and rebuilds as `[summary][restore][recent]`
(`:250`).

## 3.4 What OSA already does well

- **Honest denominators with a deliberate defer-on-unknown policy** (§3.1),
  which is stronger than any fallback constant.
- **Provider-reported token counts drive the decision.**
  `proactive_compaction.ex:622-630` and `compactor.ex:530-534` prefer
  `state.last_input_tokens`, written by `accounting.ex:73-75` as
  `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. That
  sum is deliberate and documented (`accounting.ex:56-70`): reading
  `input_tokens` alone on Anthropic shrinks as caching improves, which would
  silently stop compaction from ever firing. This is a subtle trap OSA has
  already avoided.
- **Large tool results are paged to disk before compaction ever sees them.**
  `agent/loop/tool_result_storage.ex` writes any result over 50 KB (`:36`) or
  2,000 lines (`:38`) to `~/.osa/tool-results/`, replacing it with a
  head-40/tail-20 preview plus a re-read reference (`:74-87, 163-208`), with
  UTF-8-boundary-safe cuts (`:281-282`) and a 7-day orphan sweep (`:125-155`).
  This is the paging idea from §2.10, already shipped, one layer down.
- **A second non-LLM prune tier.** `compactor.ex:846-915`: newest-first walk,
  40,000-token protect budget (`:791`), commits only if it reclaims more than
  20,000 (`:792, 889`), protected-tool allowlist (`:793-803`), idempotent via a
  marker check (`:838-843`). Exposed standalone as `micro_compact/1` (`:308`)
  and used as the deterministic fallback when the summarizer wedges
  (`turn_pipeline.ex:351`).
- **A warning band that runs cheap work before expensive work.**
  `react_loop.ex:308-322` runs microcompaction plus a memory flush between
  `warn_at` and `compact_at`.
- **A memory flush before the fold, with no LLM call.**
  `memory/flush.ex` harvests conclusion-shaped sentences by regex (`:88-121`),
  filters noise (`:126-132`), dedupes against existing memory by keyword Jaccard
  ≥ 0.7 (`:82`), and persists tagged `["pre_compaction", "flush", …]`
  (`:447-453`). Latched once per cycle with atomic `:ets.insert_new`
  (`:198-211`), reset in Engine B's success branch
  (`proactive_compaction.ex:240`) so the latch cannot stay claimed for the rest
  of the session.
- **The nine-section prompt is already ported**, including the analysis
  scratchpad and its stripper (`proactive_compaction.ex:75-108, 325-337`).
- **Summary quality validation with a stricter retry.**
  `proactive_compaction.ex:366-393` rejects and re-prompts with explicit
  instructions before spending a circuit-breaker failure.
- **A circuit breaker with probation.** Three consecutive failures open it
  (`:59, 288-299`); after a 5-minute window one trial is allowed (`:802-812`);
  a failed trial re-stamps the window (`:866-871`). Keyed per session, or per
  calling PID when there is no session id (`:814-820`).
- **Failure leaves history untouched** (`proactive_compaction.ex:301`,
  `compactor.ex:251-257`).
- **Explicit summary-of-summary on Engine A.** The cold-zone summary is
  persisted per session (`compactor.ex:2012-2021`) and fed back as a
  `PREVIOUS SUMMARY` block with a merge instruction (`:1519-1536`) — the
  carry-forward idea of §2.9, already built on one path.
- **Post-compaction restoration.** `compact_restore.ex:16-40` re-injects touched
  files, up to 5 file **bodies** (5k chars each, 50k total, `:68-70`), tasks,
  workspace, and skills.
- **A live-state reminder exists.** `CompactionSafety.build_reminder_message/1`
  (`compaction_safety.ex:194-341`) rebuilds running shells, the live TODO list,
  and running subagents with poll/cancel tool names — the §2.4 reminder, already
  written. (It is only wired on one path; see §4.4.)
- **Auto-continue after the fold.** `proactive_compaction.ex:735-751` builds a
  synthetic user turn marked `synthetic: true, metadata: %{compaction_continue:
  true}`, with an overflow-specific variant (`:708`), injected once at the stall
  boundary (`react_loop.ex:857-872`). This matches §2.8 closely.
- **The pre-compaction transcript is recoverable three ways.**
  `session_persistence.ex:15-25` keeps `<id>.json` (mutable, compaction-pruned)
  alongside `<id>.updates.jsonl` (immutable, append-only, never touched by
  compaction). `Store.SessionTranscript` persists every user and assistant turn
  to SQLite with FTS5 at ingestion, independent of compaction
  (`store/session_transcript.ex:34-62`). Rewind checkpoints snapshot the full
  message list before each user prompt (`agent/loop/checkpoint.ex:406-419`).
- **The prompt-cache flattening bug is fixed.** `context.ex:352-374` emits three
  Anthropic blocks — static base (cached), diffed world state (cached), volatile
  tail (uncached) — and `anthropic.ex:807-836` preserves the block array whenever
  any block carries a breakpoint, collapsing to a string only when none does.
  The moduledoc at `anthropic.ex:790-806` records the exact prior defect: the
  runtime timestamp landed inside the cached region and produced a 0% hit rate.
  `runtime_block/1` now truncates to the second and lives in the uncached block
  (`context.ex:1633-1639`). The non-Anthropic path orders blocks static → world
  → volatile specifically to maximize a local KV-cache prefix (`:367-374`).
- **Bounded summarizer calls.** `Compactor.bounded_chat/2`
  (`compactor.ex:1387-1416`) is a supervised task with a 90-second default and
  `:brutal_kill` on expiry; `TurnPipeline.bounded_compaction/2` wraps the whole
  thing at 120 s and falls back to deterministic `micro_compact`
  (`turn_pipeline.ex:319-348`).
- **Manual `/compact` in both flavours**, bare and with instructions
  (`loop.ex:1272-1314`, `channels/cli/commands.ex:154-215`), plus an HTTP route.
- **Compaction is visible.** Four dual-transport events —
  `compaction_started / progress / completed / failed`
  (`agent/compaction_events.ex`) — parsed by the Rust TUI
  (`priv/rust/tui/src/client/sse.rs:585-588, 1472-1545`) and rendered by the CLI
  (`channels/cli/events.ex:105-137`). Engine B announces **before** the
  summarizer call (`proactive_compaction.ex:229-230`) precisely because
  announcing on completion made the TUI freeze silently.
- **A pre-compact hook** with injected-context support (`compactor.ex:600-627`).

That is a lot of correct, well-reasoned machinery. The gaps below are real, but
they are gaps in a working system.

---

# Part 4 — Gaps and defects

Ordered roughly by severity.

## 4.1 The threshold bands invert for windows between ~66k and ~71k

`compaction_thresholds.ex:34-51`. For `cw ∈ (66_000, 70_667]` the reserve path
wins for `compact_at` (`cw − 33_000`) while `warn_at` falls through to its ratio
fallback (`0.60 × cw`), and `0.60 × cw > cw − 33_000` across that whole range.

Worked example at `cw = 70_000`:

    compact_at = 70_000 − 20_000 − 13_000 = 37_000
    warn_at    = 37_000 − 20_000 = 17_000  →  17_000 < 70_000/4  →  fallback 0.60·cw = 42_000

So `warn_at (42_000) > compact_at (37_000)`. Two consequences, both silent:

- `should_microcompact?/2`'s guard `tokens >= warn_at and tokens < compact_at`
  (`proactive_compaction.ex:150-151`) is **unsatisfiable**. The cheap non-LLM
  band never runs.
- `Memory.Flush.flush_at/1` clamps to
  `min(max(compact_at − 12_000, warn_at), compact_at − 1)` (`flush.ex:154-158`)
  = 36,999 — a band **one token wide**. Pre-compaction durable notes are
  effectively never written.

`severity_for/2`'s ordered `cond` (`compactor.ex:292-297`) masks the inversion
rather than surfacing it. This range is reachable in practice through a
configured local `num_ctx`.

**Severity: high. Silent, and it disables the two mechanisms that exist to make
compaction rarer and less lossy.**

## 4.2 `merge_consecutive` corrupts multimodal content and multiplies tokens

`compactor.ex:1283-1285`:

```elixir
safe_to_string(Map.get(prev_msg, :content)) <>
  "\n" <>
  safe_to_string(Map.get(msg, :content))
```

`Utils.Text.safe_to_string/1` `Jason.encode!`s a list. Two consecutive user
messages whose content is a **block list** — the multimodal shape produced by
`MessageHandler.build_messages/4` — are merged into a JSON *string*. Image
blocks become literal `{"type":"image","source":{"data":"<base64>"…}}` text.

Two failures at once. The image is destroyed as an image. And the base64 that
the estimator deliberately charges a flat 1,600 tokens
(`compactor.ex:135, 422-425`) is now plain text, hit by the `byte_size/4` floor —
tens of thousands of tokens. The step runs *before* `summarize_warm` and
`compress_cold`, so a step whose purpose is to save tokens can multiply them,
and the corrupted content is what reaches the provider and gets persisted.

**Severity: high. Data corruption, not just inefficiency.**

## 4.3 Engine A hoists every system message to the front, destroying chronology

`split_system/1` (`compactor.ex:2028-2032`) pulls out **every** `role: "system"`
message regardless of position, and `run_pipeline` re-emits them all at the head
(`:675`). Mid-conversation system content — Engine B's `[Compact boundary]`
summary, `<system-reminder>` blocks, mid-turn steer notes — is hoisted to the
top of history and its chronology relative to the surrounding turns is lost
**permanently**, since the return value replaces `state.messages`.

This is also how a compaction summary that was correctly placed as a boundary
marker ends up asserted as a standing system instruction.

**Severity: high.**

## 4.4 Engine B never injects the active-work reminder, contradicting its own docs

`CompactionSafety.build_reminder_message/1` is called only from
`compactor.ex:691`. Engine B's success branch (`proactive_compaction.ex:236-277`)
injects only the summary and the restore block. Its own documentation asserts
the opposite, at `proactive_compaction.ex:728-732`:

> "This composes with — does NOT replace — `CompactionSafety.build_reminder_message/1` … When both fire for the same compaction, append the reminder first, then this continuation turn."

Consequence: on the mid-turn path — the one that actually fires during long
unattended runs — running background shells, live TODO items, and running
sub-agents are dropped from the model's awareness at the fold, along with the
`task_resume` / `task_stop` handles needed to reach them.

**Severity: high for long-running sessions, which is the whole point.**

## 4.5 The mid-turn path is unbounded and can blow the wall-clock policy 2.25x

`react_loop.ex:288` calls `ProactiveCompaction.compact/3` **without**
`TurnPipeline.bounded_compaction/2`, unlike `loop.ex:1276` and `loop.ex:1300`
which both wrap at 120 s. Inside, `summarize_with_retries/3` retries on any
`{:error, _}` including `:summarizer_timeout` (`proactive_compaction.ex:522-523`),
so a wedged provider costs 3 × 90 s = **~270 s of blocked turn** against a
documented 120 s policy. `bounded_chat/2`'s own docstring states that timeouts
are not retried (`compactor.ex:1379-1381`) — true for `sample_with_retry`, false
here.

**Severity: high. A user-visible four-and-a-half-minute freeze.**

## 4.6 The threshold does not scale with the window, and nothing is reserved for the summarizer's input

Reserve-based thresholds leave a **fixed 33,000-token headroom** regardless of
window size:

| Window | `compact_at` | Fires at | Headroom |
|---|---|---|---|
| 128k | 95,000 | 74% | 33k |
| 200k | 167,000 | 83.5% | 33k |
| 1M | 967,000 | **96.7%** | 33k |

The problem is not 96.7% itself — it is that at the fold the summarization
request must carry ~967k tokens of conversation *plus* the system prompt *plus*
the tool schemas, and produce output, inside a 1M window. OSA reserves nothing.
The reference reserves 32,768 tokens explicitly when sizing summarization input
and fires at a *fraction*, so headroom grows with the window (150k on 1M).

There is also **no input ladder** (§2.7). When the summarization request
overflows, OSA has nowhere to go.

**Severity: high. This will present as "compaction just fails on big-window
models" with no obvious cause.**

## 4.7 Anti-thrash is asymmetric, and there is no undershoot margin

Three separate problems that compound:

**(a) No token refresh on the mid-turn path.** `react_loop.ex:288` compacts and
replaces `state.messages` at `:304`, but never rewrites `last_input_tokens` —
which `should_compact?/2` reads (`proactive_compaction.ex:623-626`) and which is
otherwise only written by `accounting.ex:120` after a *successful* round-trip
with non-zero usage. `TurnPipeline` explicitly fixes this for Engine A
(`turn_pipeline.ex:280-286`, comment "finding #8"); Engine B has no equivalent.
If the post-compaction LLM call errors, is cancelled, or returns no usage, the
next iteration sees the identical stale count and fires a second full summarizer
round-trip on already-compacted history.

**(b) Zero undershoot margin.** `target_tokens` is `warn_at`
(`compactor.ex:744-749, 761`) — the same line that declares `:background`
severity. The pipeline stops exactly at the threshold it must get below.

**(c) No cooldown, no minimum-turn guard.** Neither engine has one. The only
floor is `proactive_compaction.ex:214` (skip if the compactable older span is
under 400 tokens) and Engine A's 20k-reclaimable gate inside micro-compact
(`compactor.ex:889`).

**(d) No suppression latch.** The circuit breaker counts consecutive summarizer
*failures* only. There is no state for "we compacted successfully and are still
over the line". And Engine A has **no breaker at all** — a persistently failing
summarizer there burns an LLM call every turn.

**Severity: high in aggregate.**

## 4.8 Four residual hardcoded 128k denominators, one of which reaches prompt assembly

- `agent/context.ex:85` — `defp max_tokens` with a 128k default, consumed by
  `token_budget/1` (`:211, 226-247`). The reporter and the builder disagree:
  `build/1` correctly uses `Registry.effective_context_window/2` (`:114-118`).
- `agent/loop/accounting.ex:614` — telemetry utilization percentage, wrong on
  every non-128k model.
- `channels/cli/commands.ex:487` — the `/context` bar and percentage.
- `providers/registry.ex:1510-1511` — `default_context_window`, reached by
  `Registry.context_window/1` at `:1413, 1417` for unknown models. **This is the
  fabricating variant the compaction path deliberately avoids** — but
  `Context.build/1` routes through `effective_context_window/2`, so **prompt
  assembly still budgets an unknown model at 128k while compaction correctly
  defers.** The two subsystems disagree about the same model.

**Severity: medium-high. The registry site is the one that matters.**

## 4.9 The summary is absorbed into the Anthropic system block, uncached

Engine B places the boundary message at the **head** of the list as
`role: "system"` (`proactive_compaction.ex:242-250`), and `Context.build/1`
prepends the real system prompt (`context.ex:194`). On Anthropic,
`split_system/2` (`anthropic.ex:807-820`) takes leading system messages and
absorbs them into the **system-prompt block array** — *after* the two cache
breakpoints.

So a multi-thousand-token summary plus up to 50,000 characters of re-injected
file bodies are re-sent **uncached on every subsequent request** until the next
compaction. On a busy session that is the single largest recurring cost in the
turn.

This also means the earlier belief that OSA's summary reaches the wire demoted
to a user turn is only true for a summary that is *not* leading. Engine B's
always is.

## 4.10 No conversation-tail cache breakpoints at all

`context.ex:352-374` places `cache_control` on the static base and the world
state — both system blocks — and nowhere else. No other module sets it
(`providers/cache_attribution.ex` only reads it). The conversation is therefore
**never cached**: every turn re-pays full input price for the entire transcript.

The reference's three-breakpoint scheme (§2.12) is the fix, and OSA's
`split_system/2` already preserves block structure, so the plumbing exists.

**Severity: high as a cost bug.**

## 4.11 Two summarizers with incompatible output budgets and three different prompts

- `proactive_compaction.ex:405` — `max_tokens: summary_max_tokens()`, default
  **8,192** (`:30`).
- `compactor.ex:1442` — warm-group summaries at `max_tokens: 400`.
- `compactor.ex:1548` — the **cold-zone key-facts summary** at
  `max_tokens: 1024`.
- `compactor.ex:1715` — chunk summaries at `max_tokens: 600`.

The cold-zone summary "is replacing the cold zone wholesale" by its own comment
(`compactor.ex:1543-1547`). Replacing a span that may be hundreds of thousands of
tokens with at most 1,024 output tokens is not compaction, it is deletion with a
receipt.

There are also **three distinct summary contracts**: the nine-section prompt
(`proactive_compaction.ex:75-108`), an eight-section structured compression
template (`compactor.ex:1467-1507`), and a bullet-point chunk prompt
(`:1588-1598`). They disagree about what a summary is.

The degenerate floors disagree too: 200 characters on Engine B
(`proactive_compaction.ex:62`), 500 for cold-zone
(`compaction_safety.ex:54`), 80 for warm and chunk
(`compactor.ex:1459, 1732`).

**Severity: high for fidelity.**

## 4.12 Summary validation checks three sections out of nine, by substring

`proactive_compaction.ex:68`:

```elixir
@required_summary_sections ["Primary Request", "Pending Tasks", "Current Work"]
```

`valid_summary?/1` (`:366-371`) requires a 200-character floor plus
`String.contains?/2` on those three phrases. A summary that mentions "Primary
Request" inside prose, or that emits three headers with nothing under them,
passes. Sections 3 (files and code), 6 (all user messages), and 9 (next step
with a verbatim quote) — the three that actually carry continuity — are not
checked at all.

## 4.13 `last_step` is reported even when the step did nothing

`apply_step/5` returns its own name unconditionally on every branch — e.g.
`{annotated, system_msgs, :micro_compact}` at `compactor.ex:913` when nothing was
pruned, `:compress_cold` at `:1092` after a validation failure and at `:1100`
after an LLM failure. `run_pipeline` then keys the reminder injection off
`last_step in [:summarize_warm, :compress_cold, :emergency_truncate]` (`:690`)
and the step metrics off the same value (`:703`). A compaction whose cold-zone
summary was *rejected* is recorded as a successful `:compress_cold`.

## 4.14 The restore clamp counts graphemes against a byte-based estimator

`proactive_compaction.ex:449-452`:

```elixir
approx_chars = max_tokens * 4
content |> String.slice(0, approx_chars)
```

`String.slice/3` counts **graphemes**; the estimator's floor is `byte_size/4`. On
CJK (3 bytes/char) or emoji (4) the clamped block is 3–4× the intended token
budget. This is the same class of defect `Utils.Text.utf8_head/2` was written to
fix and which `tool_result_storage.ex:281` correctly uses.

## 4.15 Every automatic compaction is reported as manual

`proactive_compaction.ex:230`:

```elixir
CompactionEvents.started(session_id, :manual, older_tokens)
```

`compact/3` is the shared body for `/compact` and for the automatic
`react_loop.ex:288` path; the trigger is hardcoded. Every automatic compaction
shows up on the SSE stream and in the TUI as user-initiated, which makes "how
often does compaction fire, and at what occupancy" unanswerable. Engine A gets
this right (`compactor.ex:650` passes `:auto`).

## 4.16 Smaller items

- **No carry-forward clause on Engine B.** `proactive_compaction.ex:75-108`
  never tells the model that an earlier summary in the history is authoritative.
  On Engine B the folded `[Compact boundary]` message simply lands inside
  `older` on the next pass and gets re-summarized blind (§2.9). Engine A does
  have this (`compactor.ex:1519-1536`) — on the wrong path.
- **No drift bound anywhere.** No compaction counter, no generation-depth cap,
  no re-anchor pass. `memory/flush.ex:8-21` says outright that the summary chain
  degrades and positions durable memory as the escape hatch — which is correct,
  but it is not a bound.
- **No orphaned-tool-result sanitizer on Engine B's rebuilt history.**
  `proactive_compaction.ex:250` concatenates and relies on `split_turns/2`
  cutting at user-role boundaries (`:473-479`). That holds for well-formed
  histories; it is not a validated invariant, and an orphan is a hard 400.
  Engine A snaps boundaries; Engine B does not.
- **The recent boundary is positional.** `keep_turns: 4` counts `role: "user"`
  messages (`:477`), including synthetic injections. §2.4's semantic boundary is
  more robust.
- **The pre-compact hook's injected context never reaches Engine B.**
  `react_loop.ex:288` calls `compact/2`, so the `instructions` argument is
  always `nil` on the automatic path; Engine A threads it through the process
  dictionary (`compactor.ex:629-633`).
- **Engine A's LLM pipeline can begin at `warn_at`.** `run_pipeline` is entered
  for `:background` severity too (`compactor.ex:550-561`), so Engine A may spend
  an LLM call 20k tokens below the advertised trigger — while Engine B treats
  the same band as explicitly LLM-free. The two engines disagree about what
  `warn_at` means.
- **Engine A appends the restore block unclamped** (`compactor.ex:678-682`);
  Engine B clamps it (`proactive_compaction.ex:244-248`).
- **No per-attempt request artifact.** A degenerate summary is logged at debug
  (`compaction_safety.ex:423-426`) and discarded. There is nothing to iterate the
  prompt against.
- **Silent error swallowing.** Broad `rescue _ ->` with no logging at
  `proactive_compaction.ex:155-157, 645-647, 833-835, 853-856, 873-876, 882-885`
  (all breaker ETS operations — a missing table silently disarms the breaker
  entirely), `compactor.ex:313-315, 2006-2008, 2018-2020` (a failed summary store
  silently ends the iterative-merge chain), and `compact_restore.ex:36-39`. Worst
  of these: `bounded_chat/2`'s rescue at `compactor.ex:1410-1415` falls back to an
  **unbounded inline** provider call, reintroducing the exact hang the function
  exists to prevent whenever the task-supervisor lookup raises.
- **`/compact` reports `0 → 0 (0% reduction)`.**
  `channels/cli/commands.ex:193, 199` read `state[:tokens_used] ||
  state[:estimated_tokens]`; neither key exists in loop state (the field is
  `:last_input_tokens`).
- **The token estimator has no tokenizer.** `Utils.Tokens.estimate/1` is
  `max(round(words * 1.3 + punct * 0.5), div(byte_size + 3, 4))`, plus 4 framing
  tokens per message (`compactor.ex:360-386`) and a flat 1,600 per image
  (`:135`). System prompt and tool schemas are not in the message estimate at
  all; `do_maybe_compact` compensates with
  `overhead = max(decision_tokens − estimated, 0)` (`compactor.ex:544, 758-759`)
  — but only when a provider count exists. On the heuristic-only path overhead
  is 0 and the pipeline systematically under-compacts.

---

# Part 5 — Target design for OSA

The target is not "replace what OSA has". The reserve-based thresholds, the
warning band, the prune tier, tool-result paging, the restore block, the memory
flush, auto-continue, and the three-way transcript persistence are good and they
stay. The target is a **single compaction architecture** with the reference's
trigger discipline, continuity contract, and paging story bolted onto OSA's
existing machinery.

**T1 — Monotonic bands, proven.** Redefine the thresholds so
`warn_at < flush_at < compact_at < block_at < window` holds for **every**
positive window, and property-test that invariant across the full integer range.
The cleanest form keeps the reserve math as a ceiling and the ratios as a floor,
applied consistently rather than per-threshold:

    compact_at = clamp(window − reserve − 13_000,  0.60·window,  0.85·window)
    warn_at    = min(compact_at − 20_000,  0.75·compact_at)
    flush_at   = between warn_at and compact_at, never equal to either
    block_at   = max(compact_at + 1, window − reserve − 3_000)

The upper clamp at `0.85·window` is also §4.6's fix: it makes the fire point
scale with the window instead of leaving a fixed 33k.

**T2 — One engine.** Engine B's fold becomes the only LLM-summarizing path.
Engine A keeps its deterministic tiers — `micro_compact`, `strip_tool_args`,
`emergency_truncate` — as the pre-fold and post-overflow ladder, and loses
`summarize_warm`, `compress_cold`, and their prompts. One prompt, one output
budget (8,192), one degenerate floor (500 characters).

`merge_consecutive` is either deleted or rewritten to merge **block lists as
block lists**, never through a string encoder (§4.2).

**T3 — An explicit summarizer input reserve and an input ladder.** Size the
summarization request against `window − 32_768 − tool_schema_tokens`. On
overflow, degrade the input shape rather than failing:
verbatim → verbatim-fitted → tool-args-stripped → tool-results-dropped. Re-fetch
the conversation at each rung. Emit a degradation event per transition.

**T4 — A suppression latch** with the five states of §2.2, replacing the
failure-only circuit breaker and covering both engines. `sticky` is the
important one: a deterministic size failure must not be retried every turn, and
must clear only on a successful compaction, a rewind, or a model switch.

Alongside it, an **undershoot margin**: compaction targets
`warn_at − margin`, not `warn_at`, so the next check has room.

**T5 — Refresh the token count after every compaction, on every path.** Lift
`turn_pipeline.ex:270-292`'s `compact_and_refresh_tokens/1` into a shared helper
and call it from `react_loop.ex:288` too.

**T6 — Bound the mid-turn path.** Wrap `react_loop.ex:288` in
`TurnPipeline.bounded_compaction/2`, and stop retrying `:summarizer_timeout` in
`summarize_with_retries/3` — a timeout is not a transient error, it is the
budget being spent.

**T7 — A semantic recent boundary.** Replace `keep_turns: 4` with "everything
since the last *real* user turn", where synthetic injections do not count, using
the tag-stripping classifier of §2.4. Keep a positional cap as a backstop for a
pathologically long single turn.

**T8 — Sanitize and validate the rebuilt history** for the orphaned-tool-result
invariant on both engines, using §2.8's algorithm: collect assistant tool-call
IDs left-to-right, strip unmatched results, do not strip unmatched calls, then
re-validate and log survivors.

**T9 — Stop hoisting mid-conversation system messages.** `split_system/1` must
lift only the *leading* run. Everything else stays where it is, in order.

**T10 — Make the summary a user turn.** Emit the boundary message as
`role: "user"` with a metadata marker rather than `role: "system"`, so it stops
being absorbed into the Anthropic system block (§4.9) and starts sitting where a
conversation-tail cache breakpoint can cover it.

**T11 — Wire the active-work reminder on both paths**, honouring the ordering
Engine B's own documentation already specifies: reminder first, then the
continuation turn.

**T12 — The carry-forward clause and a real validator.** Add the "treat a prior
summary as authoritative and fold it forward" sentence to the unified prompt.
Validate all nine section headings structurally — anchored at line start,
numbered — and require section 9 to be non-empty or to explicitly state the task
is complete. Raise the floor to 500 characters everywhere.

**T13 — Safe extraction.** Adopt §2.6 wholesale: peel only *leading* scratchpad
blocks, unwrap with `rfind` on the closing tag, and neutralize echoed control
tokens with a zero-width space rather than deleting them.

**T14 — A segment store.** `~/.osa/sessions/<id>/compaction/segment_NNN.md` plus
`INDEX.md`, with the structure of §2.10, four detail levels, a 512 KB
whole-turn-boundary cap, and keyword extraction from section 8. Then append the
pointer sentence to the summary. OSA already has the read and grep tools this
depends on, and already pages large tool results to disk — this is the same idea
one level up.

**T15 — Conversation cache breakpoints.** Extend the Anthropic request build with
the three-slot scheme of §2.12 — system tail (already done), tip, and the user
turn two assistant-messages back — leaving the fourth slot free.

**T16 — Per-attempt artifacts**, bounded head-and-tail at 8,192 characters.

**T17 — Two-pass with prefire.** Only after everything above is stable.

---

# Part 6 — Implementation plan

Ordered. Each step is independently shippable and independently revertible.
**Risky steps are marked and explained** — for this subsystem "risky" means "can
silently destroy a user's conversation", which is a different bar than usual.

### Phase 0 — Stop the bleeding (pure bug fixes, no design change)

**1. Fix the band inversion (§4.1).** Add the monotonicity invariant as a
property test *first*, watch it fail across `cw ∈ (66_000, 70_667]`, then fix
`warn_at`/`flush_at` so it passes for every positive window.
*Risk: low. Confined to one module with pure functions. The test is the
deliverable as much as the fix.*

**2. Fix `merge_consecutive` (§4.2).** Merge block lists as block lists; never
route list content through `safe_to_string/1`.
⚠️ **Risky.** This step touches the shape of messages that go to the provider.
Get it wrong and every multimodal turn 400s. Add a test that a merged pair of
block-list user messages produces a block list whose image blocks are still
image blocks, and check the estimator's output does not jump.

**3. Bound the mid-turn path and stop retrying timeouts (§4.5, T6).**
`react_loop.ex:288` and `proactive_compaction.ex:522-523`.
*Risk: low. Worst case a wedged compaction is abandoned sooner, which is the
intent.*

**4. Refresh `last_input_tokens` after Engine B compacts (§4.7a, T5).**
*Risk: low. Add a test asserting a second `should_compact?/2` in the same
iteration returns false.*

**5. Fix the trigger label (§4.15).** Thread the real trigger through
`compact/3`.
*Risk: none. But existing compaction telemetry becomes non-comparable across the
change; note the version in the dashboards.*

**6. Fix the restore clamp to use `Utils.Text.utf8_head/2` (§4.14)** and fix
`/compact`'s zero-zero stats (§4.16).
*Risk: none.*

**7. Report `last_step` honestly (§4.13)** — return the step name only when the
step actually mutated. This also fixes reminder injection and step metrics.
*Risk: low. Metrics change meaning; note it.*

**8. Add logging to the swallowed rescues, and remove the unbounded fallback in
`bounded_chat/2` (§4.16).** A supervisor lookup failure must fail the
compaction, not hang the turn.
*Risk: low, and it converts a hang into an error, which is strictly better.*

### Phase 1 — Denominator and cost honesty

**9. Route the residual 128k defaults (§4.8).** Start with
`providers/registry.ex:1510-1511`, which is the one that reaches prompt
assembly. Where the window is genuinely unknown, these are *display and budget*
paths, not destructive ones, so an explicit conservative fallback is acceptable
here — unlike in the compaction decision.
⚠️ **Risky.** `context.ex:85` feeds `dynamic_budget`. Raising it from 128k to a
real 1M window suddenly admits ~8x more dynamic context into every prompt,
changing cost, latency, and possibly model behaviour on every session. Gate it
behind a flag, ship it dark, and measure prompt size before and after on a real
session.

**10. Conversation cache breakpoints (T15).**
⚠️ **Risky in a subtle way.** A wrong breakpoint placement does not error — it
silently produces a 0% cache hit rate, which is exactly the failure OSA already
survived once (`anthropic.ex:790-806`). Verify with
`providers/cache_attribution.ex`, which exists precisely to attribute cache
misses, and assert a non-zero `cache_read_input_tokens` on the second turn of a
real session before calling it done.

**11. Move the summary out of the system block (T10, §4.9)** and stop hoisting
mid-conversation system messages (T9, §4.3).
⚠️ **Risky.** Changing a message's role changes how every provider adapter
handles it, and `split_system/1`'s hoisting is load-bearing for the task brief
contract (`agent/task_brief.ex:19` cites it). Do these two together, because
fixing one without the other moves the problem rather than solving it, and
verify the task brief still survives a compaction.

### Phase 2 — Trigger discipline

**12. Monotonic bands with the fractional ceiling (T1, §4.6).**
⚠️ **Risky.** The `0.85·window` clamp changes when compaction fires for every
user. On large-window models it fires *much* earlier — which is the point, but
it means more folds per session and therefore more fidelity loss per session
until step 17 lands. Ship it with the fraction configurable and defaulted to a
value that is a no-op on the windows OSA users actually run, then raise it with
telemetry in hand.

**13. Summarizer input reserve and input ladder (T3).**
*Risk: low. Worst case a fold degrades its input unnecessarily.*

**14. Suppression latch and undershoot margin (T4).**
*Risk: medium. The failure taxonomy has to be right, or a transient error gets
latched sticky and compaction stops for the session. Start by mapping only
size/schema errors to sticky and leaving everything else on the existing
per-turn behaviour; widen from there with evidence.*

### Phase 3 — Fidelity

**15. Prompt, extraction, and validator (T12, T13).**
*Risk: low. The stricter validator will reject summaries that previously passed;
the existing stricter-retry path (`proactive_compaction.ex:388-393`) handles
that, but watch the circuit-breaker open rate for a week.*

**16. Semantic recent boundary (T7) + rebuilt-history sanitizer (T8) + wire the
active-work reminder on both paths (T11).**
⚠️ **Risky.** This is the step that can produce a provider 400 in production, and
the failure mode is "every turn after a compaction fails". Build the sanitizer
and the validator first, run the validator in **warn-only mode** across a week
of real sessions, and only then let the sanitizer mutate. Property-test it: for
any history, the output must satisfy "every tool result has a preceding matching
tool call".

**17. Collapse to one engine (T2).**
⚠️ **Risky and large.** `summarize_warm` and `compress_cold` are the paths with
the 400- and 1024-token caps (§4.11), so removing them is a fidelity
*improvement* — but `Agent.Compactor` is the engine behind `ContextEngine.Router`,
is called from `turn_pipeline.ex:275`, and carries a substantial test surface. Do
it as a sequence: first make `compress_cold` delegate to the unified summarizer
and keep its previous-summary carry-forward, verify, then delete the dead
templates.

### Phase 4 — Paging

**18. The transcript pointer, alone, first (T14 step 1).** One sentence appended
to the summary naming `<id>.updates.jsonl`, guarded on file existence. No new
storage. Measure whether the agent actually follows it.
*Risk: low, purely additive. The only real hazard is pointing the model at a
path that does not exist.*

**19. The curated segment store (T14 step 2)**, if and only if step 18 shows the
agent uses the pointer.
*Risk: low. Disk-bounded by the 512 KB cap.*

**20. Per-attempt request artifacts (T16).**
*Risk: none beyond disk.*

### Phase 5 — Latency

**21. Two-pass with prefire (T17).**
⚠️ **Risky.** Speculative background work that mutates nothing is safe; the
hazard is the prefix fingerprint. Get it wrong and pass 2 applies a note
summarizing a conversation prefix that no longer exists, producing a confidently
wrong summary with **no error anywhere**. Implement the fingerprint and its
invalidation (edit, rewind, branch, model switch) with tests *before* wiring
pass 1, and ship with prefire disabled by default behind a flag until the hit
rate and the wasted-token cost are both measured. The reference ships this dark
for the same reason.

---

# Appendix — the numbers, in one place

| Quantity | Reference | OSA today | OSA target |
|---|---|---|---|
| Trigger | 85% of the real window | `window − reserve − 13k`, unclamped | `clamp(reserve math, 0.60w, 0.85w)` |
| Denominator (compaction) | Real per-model window | Real per-model window | unchanged |
| Denominator (prompt assembly) | Real | **128k for unknown models** | Real |
| Unknown window | 256k fallback in two structural cases | **Defer, do nothing** | Keep OSA's — it is better |
| Band ordering | monotonic by construction | **inverts for 66k–71k windows** | property-tested monotonic |
| Prefire lead | threshold − 10 points | — | threshold − 10 points |
| Two-pass split | 95% by token weight, tool-boundary snapped | — | same |
| Summary input reserve | 32,768 tokens | none | 32,768 |
| Input ladder | verbatim → fitted → lossy | none | 4 rungs |
| Summary output cap | "a few thousand words" | 8,192 / 1,024 / 600 / 400 | 8,192 everywhere |
| Degenerate floor | 500 chars | 200 / 500 / 80 | 500 |
| Retries | 3, 3s apart | 2 + stricter re-prompt | 3 + input ladder |
| Wall-clock budget | 300 s (warn below 120 s) | 120 s policy, **270 s actual mid-turn** | 120 s enforced |
| Summarizer timeout retried? | No | **Yes** | No |
| Memory flush headroom | 4,000 tokens below threshold | 12,000, clamped into the warn band | 12,000, in a provably non-empty band |
| Flush dedup | embeddings, cosine ≥ 0.92 | keyword Jaccard ≥ 0.7 | keep OSA's, revisit later |
| Recent boundary | last **real** user turn | last 4 `role: "user"` messages | last real user turn + cap |
| Tool-result paging | segment store (post-fold) | **50 KB / 2,000 lines to disk (pre-fold)** | both |
| Segment cap | 512 KB, whole-turn boundary | — | same |
| Index keywords | ≤ 8, from section 8 | — | same |
| Cache breakpoints | 3 of 4 (system tail, tip, prev user turn) | 2, both in system | 3 of 4 |
| Summary role on the wire | user | **system → absorbed into the system block** | user |
| Carry-forward clause | in the prompt | Engine A only | unified prompt |
| Per-attempt artifacts | persisted JSON | debug log, discarded | persisted JSON |
