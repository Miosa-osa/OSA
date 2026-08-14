# Post-turn tool-output pruning, and why the cache decides it

**Date** 2026-08-14 · **Repo state** `e20e7e20` + this branch ·
**Brief** proposal P9 of `docs/research/competitor-techniques.md` — prune stale
tool output in place to attack the 102–162:1 input:output ratio against the
field's 56–85:1.

Every number below is labelled **[measured]**, **[derived]** (arithmetic over
measured inputs and the repo's own constants), or **[inferred]** (read from
source, not exercised against a live provider). That labelling is not ceremony:
two of the numbers this workstream was launched on were artifacts of reading
the wrong field, and both were plausible and unflattering.

---

## 0. Summary

1. **The mechanism already exists.** `Compactor.apply_step(:micro_compact, …)`
   (`compactor.ex:964-1033`) is a faithful port of opencode's `prune` tier —
   `PRUNE_PROTECT` 40,000 tokens, `PRUNE_MINIMUM` 20,000, a protected-tool list,
   newest-first walk, in-place erasure to a marker. Nothing needed building.
2. **It already runs only at a compaction boundary**, which is the answer the
   brief anticipated. Every reachable call site is inside or immediately before
   a pass that rewrites history wholesale.
3. **The per-turn variant P9 actually proposes must not be shipped**, on the
   OpenRouter route, at any threshold. It costs roughly 12.5x the history
   segment per turn. **[derived]**
4. **Whether pruning is free is a property of the ROUTE, not of the prune.**
   Native Anthropic places no cache breakpoint inside history; OpenRouter places
   a rolling one on the last history message. **[measured, by test]**
5. **The two obvious wins are in tension.** Extending prompt caching to history
   on the native route — an acknowledged, larger win — is exactly what would
   make pruning expensive there too.

**Shipped:** the invariant test that makes (4) enforceable, and this document.
**Deferred:** per-turn pruning, staleness-driven pruning. Reasons below.

---

## 1. What already exists

`docs/research/competitor-techniques.md` §4 and P9 describe opencode's
`session/compaction.ts` prune tier as a thing OSA lacks. It does not lack it.

| opencode | OSA | site |
|---|---|---|
| `PRUNE_PROTECT = 40_000` | `@compaction_prune_protect_tokens_default 40_000` | `compactor.ex:909` |
| `PRUNE_MINIMUM = 20_000` | `@compaction_prune_minimum_tokens_default 20_000` | `compactor.ex:910` |
| `PRUNE_PROTECTED_TOOLS` | 9 skill/plan/task tool names | `compactor.ex:911-921` |
| blank to `"[Old tool result content cleared]"` | `"[<tool> output pruned to reclaim context — ~N tokens erased. Re-run the tool if the original output is needed again.]"` | `compactor.ex:1018-1020` |
| walk backwards, newest first | `Enum.reverse` then `Enum.reduce` | `compactor.ex:969-1005` |

OSA's version is the better of the two on one point: `pruned_marker?/1`
(`compactor.ex:956-961`) makes a second pass idempotent, so an already-pruned
message is neither re-counted against the protect budget nor re-credited as
savings. opencode has no equivalent.

**So the deliverable was never "build P9". It was "decide whether to run it more
often, and prove the cache arithmetic either way."**

### 1.1 Where it fires today

Every reachable call site **[measured]** — `grep -rn micro_compact lib`:

| site | when |
|---|---|
| `compactor.ex:688-694` | step 1 of the full compaction pipeline |
| `react_loop.ex:313-327` | pre-request, **only** inside the warning band |
| `turn_pipeline.ex:394-398` | deterministic fallback when the summarizer wedges |

The warning band is `[warn_at, compact_at)`, guarded at
`proactive_compaction.ex:146-157`. Evaluated against the real thresholds
**[measured]**, `mix run`:

```
cw=200000   operative=200000 effective=180000 warn_at=147000 compact_at=167000 band=20000
cw=1000000  operative=200000 effective=180000 warn_at=147000 compact_at=167000 band=20000
```

The band is 20,000 tokens wide and sits immediately below the compaction
threshold — and it is the same band for a 1M-context model, because
`operative_window/1` clamps to `@context_ceiling 200_000`.

**There is no mid-history prune anywhere in OSA that is not within 20,000
tokens of a compaction.** That is the placement the brief said would be the
honest answer if the cache arithmetic went badly. It does. It already is.

---

## 2. The cache measurement

### 2.1 Where the breakpoints are — the fact everything rests on

Anthropic caches the prefix ending at the last `cache_control` marker. So the
only question that matters is: **does any cached segment extend into message
history?** If not, rewriting a message cannot invalidate anything.

**Native Anthropic — no. [measured, by test]**

Markers are placed in exactly two places, and both precede all history:

- system blocks — `context.ex:393-441` (static base, world state; the volatile
  tail is deliberately left unmarked)
- the last tool definition — `anthropic.ex:1414`, gated on
  `@min_cacheable_tools_bytes 4_000`

`grep -n cache_control lib/optimal_system_agent/providers/anthropic.ex` returns
no site that touches `chat_msgs`. The body is assembled at `anthropic.ex:80-92`
as `%{messages: chat_msgs} |> maybe_add_system(…) |> maybe_add_tools(…)`;
messages pass through untouched.

**OpenRouter → Anthropic — yes. [measured, by test]**

`PromptCache.do_restructure/1` (`prompt_cache.ex:120-152`) rolls a breakpoint
onto the **last history message**:

```elixir
marked_history = List.update_at(history, -1, &mark_last_part/1)
[put_content(first, keep) | marked_history] ++ [trailing]
```

The cached segment therefore spans the entire history. Its own in-file note
records the only live cache measurement in this repo **[measured, OpenRouter,
2026-08-14]**: with the breakpoint on a trailing separator the cached prefix
stayed pinned at 26,213 tokens for six turns; moved onto the last history
message it grew 26,213 → 28,297 and the session got 21% cheaper.

Both facts are now pinned by
`test/optimal_system_agent/providers/history_cache_breakpoint_test.exs`
(5 tests). If either flips, the conclusions below invert and the only other
symptom would be the bill.

### 2.2 The arithmetic, on the route where history is cached

Anthropic-style multipliers off the input rate, from the repo's own constants
(`agent/pricing.ex:36-37`) **[measured]**: cache **write** 1.25x, cache **read**
0.1x.

Let `H` = tokens in the cached history segment, `S` = tokens a prune erases,
`N` = turns the prefix survives afterwards. In input-rate-equivalent tokens:

```
no prune :  0.1·H·N
prune    :  1.25·(H−S)  +  0.1·(H−S)·(N−1)
```

The prune stops the stored segment being a prefix of the next request, so it is
lost and re-written once, then read at the smaller size. Difference:

```
Δ = 1.15·(H−S) − 0.1·N·S
N* = 11.5 · (H−S) / S            ← turns to break even
```

Plugging the real gate. The prune can only fire in `[147k, 167k)`; the static
prefix is 29.8k **[measured, `reference_harness_flow_comparison`]**, so
`H ≈ 117,200 … 137,200`. The gate requires `S > 20,000` (`compactor.ex:1007`).

| H | S | N* **[derived]** |
|---:|---:|---:|
| 117,200 | 20,000 | **56 turns** |
| 137,200 | 20,000 | **67 turns** |
| 117,200 | 40,000 | 22 turns |

Now the other side. How long does the prefix actually survive after a prune?
The band is 20,000 tokens wide, and on `schemelike` context grew from ~0 to
201,112 over 277 turns ≈ 725 tokens/turn **[derived from measured]**. So the
agent crosses the band in roughly **27 turns** before compaction fires and
resets the prefix regardless.

**27 < 56.** On the OpenRouter route an in-place prune never repays its own
cache break on its own terms. It is defensible only because it sits adjacent to
a compaction that was about to reset the prefix anyway — which is precisely the
placement `compactor.ex:614-616` already documents:

> compaction rewrites history wholesale, so the prompt prefix is reset by this
> pass regardless and there is no additional cache breakage to pay for.

### 2.3 What P9 as written would cost

P9 proposes running the prune **forked after every turn**. On the OpenRouter
route every turn that mutates history pays `1.25·(H−S)` where it would have
paid `0.1·H` — a ratio of **12.5x on the history segment**. At `H ≈ 117,200`
that is ~146,500 input-equivalent tokens per turn against ~11,700, an extra
~134,800 per turn. Over the 277 turns of `schemelike` that is **~37M extra
input-equivalent tokens — more than the entire 32,486,024 input tokens the run
actually consumed** **[derived]**.

P9 would roughly double the bill it was proposed to halve. This is the
"measure this before building" outcome the brief asked for, and the answer is
that the feature as specified is a large net loss on a route we ship.

### 2.4 The tension nobody has priced

On the **native** route history is uncached, so per-turn pruning there is
cache-free and saves `S` tokens at full input rate every subsequent turn. That
looks like a green light.

It is not, because leaving history uncached on the native route is itself the
larger defect. `prompt_cache.ex:98-108` says so explicitly: the native path
"is just leaving the conversation segment uncached, the same ~16 points this
module recovers here."

So the two available wins are in direct tension:

- Extend caching to history on native → recovers ~16 points **[inferred]**, and
  makes native behave like OpenRouter, where §2.2 says pruning cannot pay.
- Build out pruning on native on the assumption history stays uncached → bets
  against the larger fix.

**Extending native caching should land first.** Any pruning work that assumes
an uncached history is building on a foundation we intend to remove.

### 2.5 What was NOT measured, and why

**No live cache-hit-rate A/B was run.** `.env`'s `ANTHROPIC_API_KEY` is empty on
this machine and the configured provider is Ollama, which reports no cache
tokens at all. So §2.2–§2.4 are **[derived]** from the repo's own pricing
constants and from breakpoint placement that is **[measured, by test]** — not
from two arms against a live Anthropic endpoint.

This is stated plainly because the alternative is the failure this workstream
exists to correct. The break-even direction is robust: it survives any `H` in
the band and any `S` above the gate, and 1.25/0.1 is a published contractual
ratio, not an estimate. The *magnitude* of §2.3 depends on the schemelike
context-growth rate and should be re-derived against a live run before it is
quoted anywhere.

---

## 3. Design questions the brief asked, answered

### 3.1 What is safe to prune?

The brief's strongest argument was that a stale `file_read` is not merely
redundant but **wrong** after an edit, so pruning it improves correctness.

**That reasoning is sound but the premise is already handled, and pruning is
the wrong instrument for it.** OSA carries `FileState` + `DriftGuard`
(`file_edit/handler.ex:104-109`) and `FileState.record_write/2` drops every
recorded range on write (`file_state.ex:193`), which disarms the redundant-read
suppressor for that path — deliberately, because the file changed. The staleness
is detected at the *tool* layer, before the model can act on it, and the model
is forced to re-read. Erasing the old result from history would be a second,
weaker guard against a hazard the first one already blocks.

It would also be strictly more dangerous, because erasure is unconditional
while `DriftGuard` is checked at the moment of use.

### 3.2 What must never be pruned?

The existing protected list (`compactor.ex:911-921`) covers skills and
plan/task tracking. Two gaps worth noting for whoever revisits this, **neither
fixed here** because neither is measured:

- **`ask_user` results.** A user's answer is not re-derivable by re-running the
  tool, which is what the prune marker instructs. Erasing it loses a decision
  irrecoverably. It is not on the protected list.
- **The 40,000-token protect budget is counted in tokens, not turns.** A single
  large tool result can consume the whole budget and expose everything older,
  including results from the current turn.

### 3.3 Interaction with prompt caching

§2. Route-dependent; net loss on OpenRouter outside a compaction boundary;
free on native today but only because of a defect we intend to fix.

### 3.4 Relationship to existing compaction

Pruning **is** a compaction step (`compactor.ex:688-694`, step 1 of 6) and
should stay one. Extending it beats adding a parallel system, and the brief's
own preference for that ordering is the right call.

---

## 4. Shipped vs deferred

**Shipped**

- `test/optimal_system_agent/providers/history_cache_breakpoint_test.exs` — 5
  tests pinning the per-route breakpoint placement that §2.1 rests on.
- This document.

**Deferred, with reasons**

| item | why not |
|---|---|
| per-turn / post-turn pruning (P9 as written) | ~12.5x the history segment per turn on OpenRouter (§2.3) |
| staleness-driven pruning of edited `file_read`s | `DriftGuard` already blocks the hazard at the point of use, more tightly (§3.1) |
| protecting `ask_user` results | correct-looking, but unmeasured; a wrongly-scoped protect list is the same class of guess this document exists to stop |
| turn-aware protect floor | same |
| extending prompt caching to history on native Anthropic | the larger win and the right next step, but it is a message-shape change on the primary provider with no key on this machine to verify it (§2.4) |

---

## 5. Caveats

- No live provider A/B. See §2.5.
- `N* ≈ 56` assumes the whole history is inside the cached segment on the
  OpenRouter route. It is — the breakpoint is on the last history message — but
  it also assumes the prune target sits before that breakpoint, which is true
  for every message except the newest.
- The 27-turns-in-band figure derives from one task's context growth rate
  (`schemelike`, n=1) and will differ per workload. The conclusion does not
  depend on it being exact; it depends on it being well under 56.
- `operative_window/1` clamping to 200,000 means a 1M-context model gets the
  same 20,000-token band. That is out of scope here but is worth someone's
  attention: it makes the prune fire at 16.7% of a 1M window.
