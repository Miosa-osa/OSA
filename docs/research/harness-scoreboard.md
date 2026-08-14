# The harness scoreboard

Every published number about an **agent harness** that can be honestly quoted,
grouped so that only valid comparisons sit next to each other — and OSA's
position in it.

Companions. `what-harnesses-benchmark.md` establishes *which* benchmarks the
field publishes on. `benchmark-models.md` establishes *which model* is behind
each number. `bench/report/METHODOLOGY.md` establishes what a defensible number
contains. This document does not re-derive any of them. It **does** correct them
where a primary source disagrees — see §10.

Retrieved 2026-08-15 from machine-readable payloads (Next.js RSC flight data,
JS chunk literals, repo data files, system-card PDFs), not from rendered pages
or marketing copy. Leaderboards move; every row carries its date.

---

## 0. The answer, before the detail

1. **The single richest same-model harness comparison in public is not cline's
   dataset. It is the Terminal-Bench 2.0 board**, which we had never pulled in
   full. It has **142 rows**, exact API model-ID strings, and **28 distinct
   models on which two or more harnesses are measured** — including a
   nine-harness set on `gpt-5.3-codex` and an eight-harness set on
   `claude-opus-4-6`. §3.1.

2. **And it is the board OSA's in-flight run is on.** 89 tasks, same dataset,
   same denominator. That makes TB 2.0 the one place where an OSA number can be
   laid beside dozens of competitors' numbers on a named model.

3. **The catch, and it is severe: TB 2.0 publishes no reasoning effort, no cost,
   and no per-row trial count.** All 142 rows are therefore *unquotable for
   effort*. Since Anthropic measured 10.3 pp of movement from effort alone on
   one model under one harness, the entire board's harness deltas are
   confounded by an undisclosed variable that is larger than most of them.

4. **Harbor-Index is the best-controlled harness experiment published anywhere**
   — nine models, each run under both its own vendor CLI and Terminus-2, same 82
   tasks. It also refutes the "native harness wins" story: native beats
   Terminus-2 on the three frontier models and **loses on three of the four
   open-weight ones**, GLM-5.2 included. §3.4.

5. **Terminal-Bench 3.0 contains zero same-model harness comparisons.** Every
   one of its ten rows uses a different model. It is a model board wearing a
   harness board's schema, and no harness claim can be made from it.

6. **The largest harness effect ever published is 12.6 points, and it was
   disclosed by Google about OpenAI.** Gemini 3.1 Pro's benchmark table pins
   GPT-5.3-Codex at **64.7% under Terminus-2 and 77.3% under Codex CLI**, same
   89 tasks, same stated effort. That is 1.75× Anthropic's 7.2 pp. **OpenAI
   itself never says which harness produced 77.3%** — its system cards contain
   zero coding-benchmark scores of any kind. §3.8(a).

7. **Nobody has ever run Claude Code and Codex CLI head-to-head on one model on
   a current board.** On TB 2.1 they never share a model. On TB 2.0 they never
   share a model either. The only vendor-run cross-harness measurement of a
   competitor's product is Anthropic's Fig 2.5.A, and it compares Codex CLI to
   *Terminus-2*, not to Claude Code. **This is why no true ranking of the two
   flagship CLIs exists.** §6.

8. **Both of the field's model-pinned harness datasets are effort-scrambled, and
   in opposite directions.** goose ran **pi and itself with reasoning off**
   (`thinking: "off"`, `GOOSE_THINKING_EFFORT: "off"`) while opencode got the
   provider default. cline ran everything at medium and published a reasoning-off
   arm separately. **That is why the two datasets disagree about pi — 47.2% vs
   57.3% — and it is the same defect we have in our own head-to-head.** §4, §5.

9. **OSA's position is one honest, underpowered, internally-valid datapoint**
   (6 tasks, model pinned, every pairwise test "not distinguishable") plus a
   full-89 run in flight whose figure does not exist yet. Both are described
   with their handicaps in §7 — including that the head-to-head arm ran with
   OSA's reasoning **disabled by a defect** while every competitor's client had
   it on.

---

## 1. The organising principle

A harness score is a property of

```
(harness × harness version × model × reasoning effort × benchmark version ×
 denominator × attempt policy × trial count × budget × serving path)
```

and only the first term is the subject of this document. **A comparison is valid
only inside a fixed cell of that tuple.** Everything else is a cross-study
anecdote wearing a percentage sign.

That is not a stylistic preference. It is measured:

| Variable moved, everything else held | Effect | Source |
|---|---|---|
| Harness (Terminus-2 → Codex CLI), GPT-5.2-Codex, TB 2.0, 890 trials | **7.2 pp** | Anthropic Opus 4.6 SC, Fig 2.5.A |
| **Reasoning effort** (low → max), Opus 4.6, Terminus-2, TB 2.0 | **10.3 pp** | same figure |
| Reasoning on → off, GLM-5.2, cline CLI, TB 2.0, 89 | **11.2 pp** | cline benchmark-results |
| Harness, model fixed, SWE-bench-like | 12.5 pp (GLM-5.1) / 27.4 pp (Qwen3.6-flash) | Claw-SWE-Bench, arXiv 2606.12344 |
| Scaffold, SWE-bench Verified | 11–20 pp | Epoch AI |

**Effort is a bigger lever than the harness delta Anthropic measured.** Any
table that ranks harnesses without pinning effort is reporting effort noise and
calling it engineering.

### The admission rule

A row is **quotable** only if it carries all of:

1. harness name **and** version
2. benchmark name, version **and** denominator
3. **exact model string and reasoning effort**
4. score, with trial count or a stated attempt policy
5. date and a **primary** source — leaderboard payload, repo data file, paper,
   or system-card PDF

Missing (3) ⇒ **unquotable**, no exceptions, and the field is marked per-row
below rather than quietly dropped. Missing (5) ⇒ §9, "claimed, unverifiable".
Missing the denominator in (2) ⇒ the number is not a rate at all.

Applying this rule honestly costs a lot: **no Terminal-Bench 2.0 row, no
Terminal-Bench 1.0 row, and no Harbor-Index cell states its reasoning effort.**
Those are the three boards with the most harnesses on them.

---

## 2. The universe of harnesses

### 2.1 What Harbor can actually install

The authoritative list of harnesses that can be run head-to-head is not a
market survey, it is the adapter directory of the installed Harbor 0.21.0
(`bench/terminalbench/.venv/.../harbor/agents/`). Thirty-two installed
adapters plus five built-ins:

```
installed/  aider  antigravity_cli  antigravity_sdk  claude_code  cline  codex
            copilot_cli  cortex_code  cursor_cli  deerflow  devin  eve
            gemini_cli  goose  grok_build  hermes  kimi_cli  kimi_code
            langgraph  mimo  mini_swe_agent  nemo_agent  openclaw  opencode
            openhands  openhands_sdk  pi  qwen_code  rovodev_cli  swe_agent
            trae_agent  vibe
built-in    terminus_2  computer_1  dspy_rlm  factory  oracle  nop
```

Anything on that list is a possible arm. Anything not on it needs an adapter
written before it can ever appear in a controlled comparison — which is the
real reason the published harness universe is smaller than the product universe.

### 2.2 Who publishes a number about themselves

Carried forward from `what-harnesses-benchmark.md` §1 and unchanged by this
research: **opencode, gemini-cli, Amp and the `openai/codex` repo publish zero
benchmark numbers about themselves.** The projects doing genuine model-pinned
harness measurement are **goose** and **cline**. Everyone else's number is
either a leaderboard submission (where the board, not the project, controls the
schema) or a *(model × scaffold)* pair sold as a model result.

---

## 3. The scoreboard, cell by cell

### 3.1 Terminal-Bench 2.0 — 89 tasks — the deepest same-model board

Source: `tbench.ai/leaderboard/terminal-bench/2.0`, Next.js RSC payload.
**142 rows.** Schema: `agent, agentVersion, model, modelNames,
modelOrganization, agentOrganization, date, accuracy, stderr, integrationMethod,
verified, agentUrl`.

**What this board does and does not carry.**

| Field | Present? |
|---|---|
| exact API model-ID strings | **yes** — the only current board that has them |
| reasoning effort | **NO** — every row unquotable on effort |
| cost | **NO** |
| per-row trial count | **NO** — accuracies are exact rationals over multiples of 89, which confirms the denominator but not the repetitions |
| stderr | yes, except 8 rows where it is `null` |
| `verified` flag | yes — **89 of 142 are `verified: false`**, including all of the top three |

That last row matters more than it looks. **The top of this board is
self-reported by parties with an interest in the result, and the benchmark
authors did not check it.** `Codex CLI 0.121.0 + gpt-5.5 at 82.25%` is the
highest *verified* row, at rank 4.

**The same-model sets.** These are the comparisons this board exists to make.
Every one is confounded by unpublished effort; that caveat applies to all of
them and is not repeated per line.

| Exact model string | n | Harnesses, best → worst (%) |
|---|---:|---|
| `gpt-5.3-codex` | 9 | SageAgent 78.43 · Droid 77.30 · CodeBrain-1.5 75.84 · Codelia 75.73 · Simple Codex 75.06 · Mux 74.61 · spoox-o-m 71.46 · IndusAGI 69.14 · **Terminus 2 64.72** |
| `claude-opus-4-6` | 8 | Meta-Harness 76.40 · Capy 75.28 · Terminus-KIRA 74.72 · Droid 69.89 · Crux 66.87 · Mux 66.52 · **Terminus 2 62.92** · **Claude Code 2.1.34 57.98** |
| `claude-opus-4-5[-20251101]` | 8 | Droid 63.15 · Letta Code 59.10 · Mux 58.43 · **Terminus 2 57.75** · Goose 54.33 · **Claude Code 2.0.72 52.13** · OpenHands 51.91 · OpenCode 51.69 |
| `gemini-3-pro-preview` | 7 | Ante 69.43 · SageAgent 65.17 · CodeBrain-1.5 62.25 · II-Agent 61.80 · Droid 61.12 · **Terminus 2 56.85** · Letta Code 55.96 |
| `gpt-5-nano` | 5 | spoox-o-m 21.80 · **Codex CLI 11.46** · OpenHands 9.89 · **Terminus 2 7.87** · Mini-SWE-Agent 6.97 |
| `gpt-5-mini` | 5 | spoox-o-m 34.83 · **Codex CLI 31.85** · OpenHands 29.21 · **Terminus 2 24.04** · Mini-SWE-Agent 22.25 |
| `claude-sonnet-4-5-20250929` | 4 | **Terminus 2 42.81** · OpenHands 42.58 · Mini-SWE-Agent 42.53 · **Claude Code 2.0.31 40.06** |
| `gpt-5` | 4 | **Codex CLI 49.61** · OpenHands 43.82 · **Terminus 2 35.17** · Mini-SWE-Agent 33.93 |
| `claude-opus-4-1-20250805` | 4 | **Terminus 2 37.98** · OpenHands 36.85 · Mini-SWE-Agent 35.06 · **Claude Code 34.83** |
| `claude-haiku-4-5-20251001` | 4 | Mini-SWE-Agent 29.83 · **Terminus 2 28.31** · **Claude Code 27.53** · OpenHands 13.93 |
| `gpt-5.2` | 4 | Droid 64.94 · **Codex CLI 0.73.0 62.92** · Mux 60.67 · **Terminus 2 54.04** |
| `gemini-2.5-pro` | 4 | **Terminus 2 32.64** · Mini-SWE-Agent 26.07 · **Gemini CLI 19.55** · OpenHands 16.40 |
| `gemini-2.5-flash` | 4 | Mini-SWE-Agent 17.08 · **Terminus 2 16.85** · OpenHands 16.40 · **Gemini CLI 15.45** |
| `gemini-3.1-pro-preview` | 4 | TongAgents 80.22 · Terminus-KIRA 74.83 · **Gemini CLI 0.35.0 61.42** · **Gemini CLI 0.34.0 59.36** |
| `gpt-5.5` | 4 | NexAU-AHE 84.72 · Capy 83.15 · **Codex CLI 0.121.0 82.25** · clnkr 66.07 |
| `gpt-5-codex` | 3 | **Codex CLI 44.33** · **Terminus 2 43.43** · Mini-SWE-Agent 41.35 |
| `gpt-5.1-codex` | 3 | Crux 57.75 · Letta Code 53.48 · **Terminus 2 36.85** |
| `gemini-3-flash-preview` | 3 | Junie CLI 64.27 · **Terminus 2 51.69** · **Gemini CLI 47.42** |
| `grok-4-0709` | 3 | OpenHands 27.19 · Mini-SWE-Agent 25.39 · **Terminus 2 23.15** |
| `Qwen3-Coder-480B-A35B-Instruct-FP8` | 3 | Dakou Agent 27.19 · OpenHands 25.39 · **Terminus 2 23.90** |
| `moonshotai/Kimi-K2-Instruct-0905` | 2 | **Terminus 2 27.79** · OpenHands 26.74 |
| `openai/gpt-oss-120b` | 2 | **Terminus 2 18.69** · Mini-SWE-Agent 14.16 |
| `openai/gpt-oss-20b` | 2 | Mini-SWE-Agent 3.37 · **Terminus 2 3.07** |
| `grok-code-fast-1` | 2 | Mini-SWE-Agent 25.84 · **Terminus 2 14.16** |
| `minimax-m2.1` | 2 | Crux 36.63 · **Terminus 2 29.21** |
| `minimax-m2.5` | 2 | cchuter 42.70 · **Terminus 2 42.25** |
| `glm-4.7` | 2 | **Terminus 2 33.39** · Crux 33.26 |
| `claude-sonnet-4-5` (loose ID) | 2 | CAMEL-AI 46.52 · Goose 43.15 |

**The one clean instrument on this board.** Six models carry the *same five
harnesses* — Terminus 2, Mini-SWE-Agent, OpenHands, Claude Code, Codex CLI —
all dated 2025-10-31 to 2025-11-04, all `verified: true`. That is one
coordinated baseline sweep by the benchmark authors, and it is the closest thing
to a controlled harness ladder anyone has published:

| Model | Terminus 2 | Mini-SWE-Agent | OpenHands | Claude Code | Codex CLI | spread |
|---|---:|---:|---:|---:|---:|---:|
| `gpt-5` | 35.17 | 33.93 | 43.82 | — | **49.61** | 15.7 pp |
| `gpt-5-mini` | 24.04 | 22.25 | 29.21 | — | **31.85** | 9.6 pp |
| `gpt-5-nano` | 7.87 | 6.97 | 9.89 | — | **11.46** | 4.5 pp |
| `claude-sonnet-4-5-20250929` | **42.81** | 42.53 | 42.58 | 40.06 | — | 2.8 pp |
| `claude-opus-4-1-20250805` | **37.98** | 35.06 | 36.85 | 34.83 | — | 3.2 pp |
| `claude-haiku-4-5-20251001` | 28.31 | **29.83** | 13.93 | 27.53 | — | 15.9 pp |

Three things fall out of that table and none of them are comfortable.

- **Codex CLI wins every GPT row, and Claude Code loses every Claude row.**
  Claude Code is last or second-to-last on all three Anthropic models, behind
  the benchmark authors' own Terminus-2 and behind a 190-line bash loop.
- **Mini-SWE-Agent is within 2.8 pp of the best harness on Sonnet 4.5 and wins
  outright on Haiku 4.5.** The scaffold-control keeps earning its reputation.
- **The harness spread is model-dependent and not small.** 2.8 pp on Sonnet 4.5,
  15.9 pp on Haiku 4.5. Whatever a harness contributes, it is not a constant.

### 3.2 Terminal-Bench 2.1 — 89 tasks, 445 trials — the only board with effort

Source: `tbench.ai/leaderboard/terminal-bench/2.1`, RSC payload. **17 rows,
complete — there is nothing below rank 17.** Richest schema of any board:
`reasoning_effort`, `n_trials`, `total_cost_usd`, `accuracy_stderr`, `pass@5`,
`reward_hacks`, token counts, avg trial duration, and a submission PR link at
`github.com/harbor-framework/terminal-bench-2-1/pull/<N>`.

Every row is **445 trials = 89 × 5**, except rank 12 which is 447.

| # | Agent | Model | Effort | Acc % | ± | Date | Cost | Hack % | pass@5 | PR |
|---:|---|---|---|---:|---:|---|---:|---:|---:|---|
| 1 | Claude Code | Fable 5 | xhigh | **83.82** | 1.16 | 2026-06-07 | $552.67 | 0.22 | 0.933 | #75 |
| 2 | Codex | GPT-5.5 | xhigh | 83.15 | 1.13 | 2026-05-01 | $2,059.19 | 0.22 | 0.944 | #45 |
| 3 | Terminus 2 | Fable 5 | high | 80.45 | 1.16 | 2026-06-05 | $438.64 | 0.00 | 0.921 | #78 |
| 4 | Cursor CLI | Grok 4.5 | high | 79.33 | 1.46 | 2026-07-09 | $134.09 | **8.99** | 0.955 | #86 |
| 5 | Claude Code | Opus 4.8 | high | 78.88 | 1.31 | 2026-07-09 | $286.94 | 0.00 | 0.944 | #92 |
| 6 | Codex | GPT-5.6 Terra | max | 78.43 | 1.25 | 2026-07-11 | $421.15 | 0.22 | 0.899 | #115 |
| 7 | Terminus 2 | GPT-5.5 | xhigh | 77.98 | 1.22 | 2026-05-01 | $493.85 | 0.22 | 0.876 | #47 |
| 8 | mini-SWE-agent | Muse Spark 1.1 | xhigh | 76.18 | 1.23 | 2026-07-09 | $198.05 | 0.00 | 0.910 | #94 |
| 9 | Codex | GPT-5.6 Luna | max | 75.73 | 1.32 | 2026-07-11 | $241.45 | 0.90 | 0.888 | #112 |
| 10 | Claude Code | Sonnet 5 | high | 74.61 | 1.64 | 2026-07-09 | $288.18 | 0.67 | 0.921 | #98 |
| 11 | Terminus 2 | Gemini 3 Pro | high | 73.93 | 1.29 | 2026-05-01 | $224.44 | 0.45 | 0.876 | #48 |
| 12 | Claude Code | Opus 4.7 | max | 68.90 | 1.41 | 2026-05-01 | $599.52 | 0.45 | 0.841 | #44 |
| 13 | Terminus 2 | Opus 4.7 | max | 66.07 | 1.37 | 2026-05-01 | $582.26 | 0.00 | 0.832 | #46 |
| 14= | Gemini CLI | Gemini 3 Pro | high | 65.84 | 1.38 | 2026-05-01 | $247.76 | 0.45 | 0.820 | #66 |
| 14= | Gemini CLI | Gemini 3.1 Pro | high | 65.84 | 1.67 | 2026-05-05 | $236.49 | 0.22 | 0.876 | #68 |
| 16 | Terminus 2 | Gemini 3.1 Pro | high | 65.62 | 1.65 | 2026-05-05 | $229.99 | 0.45 | 0.865 | #69 |
| 17 | Claude Code | GLM-5.1 | max | 58.65 | 1.24 | 2026-05-01 | $277.14 | 0.00 | 0.730 | #67 |

**The valid harness deltas on this board** — model *and* effort both held:

| Model | Effort | A | B | Δ |
|---|---|---|---|---:|
| GPT-5.5 | xhigh | **Codex 83.15** | Terminus 2 77.98 | +5.17 |
| Opus 4.7 | max | **Claude Code 68.90** | Terminus 2 66.07 | +2.83 |
| Gemini 3 Pro | high | **Terminus 2 73.93** | Gemini CLI 65.84 | +8.09 |
| Gemini 3.1 Pro | high | Gemini CLI 65.84 | Terminus 2 65.62 | +0.22 (tie) |

**Do not quote the Fable 5 pair as a harness delta.** Claude Code ran it at
`xhigh` and Terminus 2 at `high`. The 3.37 pp gap is effort *and* harness
mixed, and given Anthropic's own 10.3 pp effort ladder the effort term could be
the whole of it.

**Two things this board reveals that no other does.**

- **Reward hacking is measured and it is not zero.** `Cursor CLI + Grok 4.5`
  hacked **8.99%** of trials — forty times the next-highest rate — while
  ranking 4th. Its 79.33% is not a number about solving tasks.
- **Cost per point is not monotone in score.** Codex + GPT-5.5 spent
  **$2,059** to score 83.15%; Claude Code + Fable 5 spent **$553** to score
  higher. Cursor CLI + Grok 4.5 spent $134 for 79.33%. A 15× cost spread inside
  5 points of score.

> **A retrieval discrepancy, recorded rather than smoothed.** Two independent
> passes over `tbench.ai` on 2026-08-15 disagreed: one extracted the 17 rows
> above from the RSC payload with `n_trials`, `reasoning_effort`, cost and a
> submission PR number per row; the other reported the TB 2.1 board as having
> **zero rows**. The 17-row extraction carries corroborating detail that could
> not be fabricated — PR numbers resolving under
> `github.com/harbor-framework/terminal-bench-2-1` — so it is the one reported
> here. But **anyone re-deriving this table should expect the board to render
> empty on some paths**, and should not treat a zero-row fetch as evidence the
> data is gone.

**Also: TB 2.1 community submissions are closed** (maintainer-run only), and the
board protocol is **5 trials per task**. Our number can be compared against this
board and can never be added to it, and a single-trial run is not the same
measurement as a 445-trial one.

### 3.3 Terminal-Bench 3.0 — 74 tasks, 370 trials — no harness comparison exists

Source: `frontierbench.ai`, RSC payload. Officially **"Terminal-Bench 3.0
(formerly Frontier-Bench)"**; `tbench.ai/leaderboard/terminal-bench/3` is a 404.
All 10 rows, each **370 trials = 74 × 5**:

| # | Agent | Model | Effort | Acc % | ± | Submitted | Cost | Tokens |
|---:|---|---|---|---:|---:|---|---:|---:|
| 1 | mini-SWE-agent | Opus 5 | max | **42.70** | 1.58 | 2026-07-24 | $5,818 | 7.3B |
| 2 | Codex | GPT-5.6 Sol | max | 34.59 | 1.58 | 2026-07-13 | $3,951 | 5.8B |
| 3 | Claude Code | Fable 5 | max | 34.05 | 1.71 | 2026-07-13 | $6,481 | 3.6B |
| 4 | Grok Build | Grok 4.6 | high | 26.49 | 1.49 | 2026-08-12 | $2,095 | 2.9B |
| 5 | Claude Code | Opus 4.8 | max | 21.08 | 1.55 | 2026-07-12 | $5,214 | 5.2B |
| 6 | Codex | GPT-5.6 Terra | max | 20.81 | 1.40 | 2026-07-12 | $2,485 | 7.0B |
| 7 | Cursor CLI | Grok 4.5 | xhigh | 15.68 | 1.47 | 2026-07-15 | $766 | 1.2B |
| 8 | Claude Code | Sonnet 5 | max | 14.59 | 1.50 | 2026-07-12 | $6,891 | 17.9B |
| 9 | Codex | GPT-5.6 Luna | max | 14.32 | 1.25 | 2026-07-12 | $1,598 | 11.9B |
| 10 | Claude Code | GLM 5.2 | max | **4.59** | 0.97 | 2026-07-19 | $3,402 | 3.3B |

**Every model appears exactly once. This board contains zero same-model
harness comparisons and supports no harness claim whatsoever.** It is a model
board with an agent column.

What it *does* establish, cleanly, is the GLM-5.2 ceiling under a pinned
harness at pinned effort: Claude Code at `max` carries Fable 5 to 34.05%,
Opus 4.8 to 21.08%, Sonnet 5 to 14.59% and **GLM 5.2 to 4.59%**. And it cost
$3,402 to score 4.59% — failure is expensive.

Note also that the best score on the hardest board belongs to **mini-SWE-agent**,
beating Claude Code + Fable 5 by 8.7 pp — though on a *different model*, so
that is not a harness result either.

### 3.4 Harbor-Index 1.0 — 82 tasks published / 80 on disk — the best-controlled harness experiment anywhere

Source: the literal `pc` data array inside
`harbor-index.org/_next/static/chunks/94933e4a60a22aaa.js`. The rendered page is
a client-side Recharts scatter with no server-rendered rows; the Harbor Hub
dataset page's Leaderboard tab serves empty. **This matrix has not, as far as we
can tell, been published as a table anywhere — including by its authors.**

Nine models, each under **its own vendor CLI and under Terminus 2**, same tasks:

| Model | Native CLI | Native % | Native $ | Terminus 2 % | T2 $ | Native − T2 |
|---|---|---:|---:|---:|---:|---:|
| GPT 5.5 | Codex CLI | **28.1** | $178 | 19.7 | $155 | **+8.4** |
| Claude Opus 4.8 | Claude Code | **20.7** | $269 | 15.8 | $293 | **+4.9** |
| Gemini 3.1 Pro | Gemini CLI | **13.4** | $74 | 10.7 | $89 | **+2.7** |
| GLM 5.2 | Claude Code | 8.5 | $205 | **9.8** | $52 | **−1.3** |
| Kimi K2.6 | Claude Code | 6.1 | $191 | **8.5** | $33 | **−2.4** |
| MiniMax M3 | Claude Code | 3.7 | $66 | **6.1** | $18 | **−2.4** |
| DeepSeek V4 Pro | Claude Code | **4.9** | $177 | 3.7 | $35 | +1.2 |
| Qwen3.7 Max | Claude Code | 4.9 | $201 | 4.9 | $36 | 0.0 |
| MiMo V2.5 Pro | Claude Code | 2.4 | $49 | 2.4 | $4 | 0.0 |

**This is the finding the site's own summary buries.** Harbor-Index's prose says
*"each model's own native CLI reaches its result far more economically than the
cross-vendor terminus-2 harness"* — but the table says the native CLI wins
**only where the CLI and the model come from the same vendor**. Where a
third-party model is driven through Claude Code, Terminus-2 wins three times and
ties twice, and does it at **a quarter to a sixth of the cost**. GLM-5.2 through
Claude Code costs $205 to score 8.5%; through Terminus-2 it costs $52 to score
9.8%.

That is directly on-thesis for us: **OSA's model is one where the elaborate
vendor CLI is a liability, not an asset.**

Caveats, all of them: **no dates, no reasoning effort, no per-cell trial count**
for any of the 18 cells (only "runs" 1–5 on the three frontier rows), and model
strings are display labels, not API IDs. The whole matrix is unquotable on
effort. Construction is documented: 6,627 → 1,311 → 307 → 100 → **82** tasks,
filtered by pass rate < 34% across `Claude Opus 4.6 / GPT-5.4 / Gemini 3.1 Pro`
× 2 harnesses × 3 runs.

**And note a live discrepancy: the site says 82 tasks; the Harbor Hub download
lands 80, and upstream's own README says 80.** Released tags run
`harbor-index-1.1` … `1.4`. Our `datasets.py` records 80, counted from disk.
Anyone quoting "82" including the site is quoting a stale figure.

### 3.5 Terminal-Bench 1.0 — 80 tasks — historical, deepest harness diversity

Source: `tbench.ai/leaderboard/terminal-bench/1.0`, still live, 62 rows,
`terminal-bench-core==0.1.1`. No effort, no cost, no trial counts, and — a
confound the other boards do not have — **`integrationMethod` mixes `Install`
and `API` within the same model group**, which is a different experiment, not a
different harness.

Same-model sets, for the record:

| Model | Harnesses (%) |
|---|---|
| `claude-sonnet-4` | Ante 54.75 · Chaterm 49.25 · Engine Labs 44.75 · Letta 42.50 · OpenHands 41.25 · Goose 41.25 · Orchestrator 36.96 · **Terminus 2 36.40** · **Claude Code 35.50** · Goose 34.25 · **Mini SWE-Agent 12.80** |
| `claude-sonnet-4-5` | Apex2 64.50 · Chaterm 63.75 · Ante 60.25 · Droid 57.50 · **Terminus 2 51.00** · DeepAgent 50.50 · Alpha 38.25 |
| `gpt-5` | Droid 52.50 · Apex2 49.25 · **Terminus 2 41.25** · **Terminus 1 30.00** |
| `claude-opus-4-1` | Droid 58.80 · **Terminus 2 43.75** · Orchestrator 40.50 |
| `claude-opus-4` | Goose 45.25 · **Claude Code 43.20** · Goose 42.00 · **Terminus 2 39.00** |
| `o4-mini` | Goose 27.50 · **Codex CLI 20.00** · **Terminus 1 18.54** |
| `gpt-4.1` | CAMEL 35.00 · **Terminus 1 30.28** · **Codex CLI 8.29** |
| `claude-3-7-sonnet` | **Claude Code 35.18** · **Terminus 1 30.59** |
| `Qwen3-Coder-480B` | iFlow CLI 39.00 · Orchestrator 19.70 |

The `claude-sonnet-4` row is the widest same-model harness spread ever
published: **12.80% to 54.75%, 41.9 points**, with Mini-SWE-Agent at the bottom
— the opposite of its TB 2.0 showing. On a benchmark generation where the
scaffold had to do more, the minimal scaffold collapsed. That is a real result
about what harnesses are for, and it should temper the "mini-SWE-agent is all
you need" reading of §3.1.


### 3.6 SWE-bench — six boards, and the harness is mostly invisible

Source: `raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json`
(7.27 MB, fetched 2026-08-15). Per-row fields: `agent, agent_org, name,
model_display, model_org, reasoning_effort, resolved, date, instance_cost,
instance_calls, checked, os_system, os_model, tags, warning`.

**The six boards are `bash-only` (47), `Multilingual` (13), `Test` (24),
`Verified` (180), `Lite` (84), `Multimodal` (22).** The sixth is **`Test`
(n=2294)**, not "full". Denominators: Lite 300, Verified 500, Multilingual 300,
Test 2294; `bash-only` runs the Verified 500.

**Submission policy, verbatim from `SWE-bench/experiments/README.md`:**
*"[11/18/2025] SWE-bench Verified and Multilingual now only accepts submissions
from academic teams and research institutions with open source methods and
peer-reviewed publications."* Named as no longer eligible: **Augment Code,
Solver AI, Honeycomb.sh**. Still eligible: OpenHands, SWE-RL, FrogBoss,
AutoCodeRover. **Scope correction to our prior note: the policy covers Verified
and Multilingual only. Lite is not named and Multimodal is explicitly still
open.**

#### The disclosure problem, quantified

On the **Verified** board, 180 rows:

| Model disclosure | Rows | Share |
|---|---:|---:|
| specific model named | 134 | 74.4% |
| `"Multiple"` — a model mix | 22 | 12.2% |
| `"Undisclosed"` | 24 | 13.3% |
| **unquotable under our rule** | **46** | **25.6%** |

And `checked`: **True 60 · False 97 · null 17 · "false (see README)" 6.**
**Only 33% of Verified rows have been verified by the benchmark maintainers.**
51 of 180 rows do not even name an `agent_org`.

Every commercial harness we went looking for is present, and almost all of them
are unquotable: Refact.ai (74.4%, 70.4% — both `Multiple`), Augment Agent
(70.4%, 65.4% — both `Undisclosed`), Factory Code Droid (37.0% — `Undisclosed`),
Blackbox AI (62.8% — `Undisclosed`), Amazon Q Developer (65.4/55.0/38.8/25.6% —
all four `Undisclosed`), Gru, Emergent, Zencoder, devlo, Solver, Honeycomb,
Bracket.sh, Isoform, Bytedance MarsCode — `Undisclosed` or `Multiple` in every
case. **TRAE is the exception worth naming: its top row is 78.8% on
`Doubao-Seed-Code`, a disclosed model.**

#### Verified board, top of the table

| # | Harness | Org | Model | Effort | % | Date | checked |
|---:|---|---|---|---|---:|---|---|
| 1= | **live-SWE-agent** | UIUC | Claude 4.5 Opus | medium | **79.2** | 2025-12-15 | False |
| 1= | **Sonar Foundation Agent** | Sonar | Claude 4.5 Opus | — | **79.2** | 2025-12-05 | False |
| 3 | TRAE | ByteDance | Doubao-Seed-Code | — | 78.8 | 2025-09-28 | False |
| 4 | live-SWE-agent | UIUC | Gemini 3 Pro Preview | — | 77.4 | 2025-11-20 | false* |
| 5 | Atlassian Rovo Dev | Atlassian | **Multiple** ⚠ | — | 76.8 | 2025-09-02 | False |
| 6 | EPAM AI/Run Dev Agent | EPAM | Claude 4 Sonnet | — | 76.8 | 2025-08-04 | False |
| 7 | **mini-SWE-agent 2.0.0** | SWE-agent | **Claude 4.5 Opus** | **high** | **76.8** | 2026-02-17 | null |
| 8 | ACoder | ACoder | **Multiple** ⚠ | — | 76.4 | 2025-08-19 | False |
| 11 | Warp | Warp | **Multiple** ⚠ | — | 75.6 | 2025-09-01 | False |
| 13 | TRAE | TRAE | **Multiple** ⚠ | — | 75.2 | 2025-06-12 | False |
| 18 | Refact.ai Agent | Refact.ai | **Multiple** ⚠ | — | 74.4 | 2025-06-03 | False |
| 23 | Tools | *(none)* | Claude 4 Opus | — | 73.2 | 2025-05-22 | False |
| 29 | **OpenHands** | OpenHands | **GPT-5** | — | 71.8 | 2025-08-07 | **True** |
| 42 | OpenHands | OpenHands | Claude 4 Sonnet | — | 70.4 | 2025-05-24 | **True** |
| 53 | SWE-agent | — | Claude 4 Sonnet | — | 66.6 | 2025-05-22 | **True** |

Our prior fact is confirmed: the top is a tie at **79.2%** between
`live-SWE-agent + Claude 4.5 Opus (medium)` and `Sonar Foundation Agent +
Claude 4.5 Opus`, both `checked: False`.

#### Bash Only — 47 rows, harness pinned to mini-SWE-agent, denominator 500

This is the field's model ladder, and the only board where the scaffold is a
constant by construction. **Our prior 12-row extract was a fragment of 47 and
contained one outright error.**

| Model | Effort | % | $/inst | calls/inst | Date | mini ver |
|---|---|---:|---:|---:|---|---|
| Claude 4.5 Opus | high | **76.8** | 0.754 | 32.90 | 2026-02-17 | 2.0.0 |
| Gemini 3 Flash | high | 75.8 | 0.356 | 56.13 | 2026-02-17 | 2.0.0 |
| MiniMax M2.5 | high | 75.8 | 0.073 | 60.45 | 2026-02-17 | 2.0.0 |
| Claude 4.6 Opus | — | 75.6 | 0.552 | 28.93 | 2026-02-17 | 2.0.0 |
| Claude 4.5 Opus | medium | 74.4 | 0.721 | 38.04 | 2025-11-24 | 1.16.0 |
| Gemini 3 Pro Preview | — | 74.2 | 0.460 | 40.33 | 2025-11-18 | 1.15.0 |
| GPT 5.2 Codex | — | 72.8 | 0.449 | 28.07 | 2026-02-19 | 2.0.0 |
| **GLM 5** | high | 72.8 | 0.534 | 76.18 | 2026-02-17 | 2.0.0 |
| GPT 5.2 | high | 72.8 | 0.474 | 35.05 | 2026-02-17 | 2.0.0 |
| Claude 4.5 Sonnet | high | 71.4 | 0.658 | 48.30 | 2026-02-17 | 2.0.0 |
| Kimi K2.5 | high | 70.8 | 0.147 | 51.18 | 2026-02-17 | 2.0.0 |
| DeepSeek V3.2 | high | 70.0 | 0.448 | 88.51 | 2026-02-17 | 2.0.0 |
| **Gemini 3 Pro** | high | **69.6** | **0.960** | 51.28 | 2026-02-26 | 2.0.0 |
| Claude 4.5 Haiku | high | 66.6 | 0.331 | 66.15 | 2026-02-17 | 2.0.0 |
| GLM 4.6 (T=1) | — | 55.4 | 0.097 | 49.35 | 2025-12-01 | 1.17.1 |
| GLM 4.5 | — | 54.2 | 0.297 | 40.22 | 2025-08-22 | 1.9.1 |
| gpt-oss-120b | — | 26.0 | 0.057 | 27.60 | 2025-08-07 | 1.7.0 |

> **CORRECTION, and it was ours.** `benchmark-models.md` §1 states
> **"Gemini 3 Pro 0.0% at $0.960"** and builds a paragraph on it about
> unannotated infrastructure failures on public leaderboards. **There is no 0.0%
> row on any of the six boards.** Gemini 3 Pro appears twice — 74.2% (Preview,
> 2025-11-18) and **69.6% (2026-02-26, high, $0.960/instance)**. The $0.960 was
> read off the right row and the score off nothing. Strike the claim.

Also note the **mini-SWE-agent version moves across this board** (0.0.0 → 1.x →
2.0.0). Rows from different versions are not a fixed scaffold, which slightly
undercuts the board's whole purpose. `Claude 4.5 Opus` at `high` on 2.0.0 is
76.8%; at `medium` on 1.16.0 it is 74.4% — effort *and* scaffold version moved
together.

#### Multilingual — 13 rows, n=300, mini-SWE-agent on every row

**100% of rows name a model. No commercial harness has ever appeared** — the
academic-only policy binds here. Top: Gemini 3 Flash 72.7%, Claude 4.6 Opus
72.0%, Claude 4.5 Opus 70.7%, **GLM 5 69.7%**, Gemini 3 Pro 68.7%.

### 3.7 SWE-bench Pro — the harness is a footnote, and it encodes a budget

`scale.com/leaderboard/swe_bench_pro_public` redirects to `labs.scale.com`.
There is no harness column. There is an **asterisk**:

> *"Run with mini-swe-agent harness"* — and, separately —
> *"Models and results that are grayed out were run with a capped cost limit and
> turn limit of 50. All other Models on this page were run with an uncapped cost
> and with a turn limit of 250."*

Unstarred rows use the **SWE-agent** scaffold. **So the asterisk changes the
harness *and* the turn budget from 250 to 50 at the same time, and starred and
unstarred rows are not comparable to each other.** Public split, 731 instances /
41 repos:

| Model | Harness + budget | Score ± CI |
|---|---|---|
| Muse Spark 1.1 * | mini-swe-agent, 50 turns | 61.50 ± 3.10 |
| gpt-5.4 (xHigh) * | mini-swe-agent, 50 turns | 59.10 ± 3.56 |
| Muse Spark * | mini-swe-agent, 50 turns | 55.00 ± 3.60 |
| claude-opus-4-6 (thinking) * | mini-swe-agent, 50 turns | 51.90 ± 3.61 |
| gemini-3.1-pro (thinking) * | mini-swe-agent, 50 turns | 46.10 ± 3.60 |
| claude-opus-4-5-20251101 | SWE-agent, 250 turns | 45.89 ± 3.60 |
| claude-4-5-Sonnet | SWE-agent, 250 turns | 43.60 ± 3.60 |
| gpt-5.2-codex | SWE-agent, 250 turns | 41.04 ± 3.57 |
| glm-4.6 | SWE-agent, 250 turns | 9.67 ± 2.15 |

No dates on any row. Rank is "Rank (UB)": 1 + the number of models whose lower
CI bound exceeds this model's upper bound — an honest ranking convention that
the Terminal-Bench boards do not use.

**And a cross-check that matters:** xAI claims Grok 4.5 at 64.7% on SWE-bench
Pro and Z.ai claims GLM-5.2 at 62.1%. Both would top this board. **Neither model
appears on it, and neither vendor names a harness.** §9.

### 3.8 Vendor system cards — where the cleanest harness deltas actually live

Three vendors have published a same-model, same-benchmark, two-harness
measurement. All three are worth more than any leaderboard row.

#### (a) Google's Gemini 3.1 Pro table — the largest harness effect ever published

`deepmind.google/models/gemini/pro/`, with methodology at
`deepmind.google/models/evals-methodology/gemini-3-1-pro/` (a PDF). Every column
header carries the thinking level. Two Terminal-Bench 2.0 rows:

| Row | Gemini 3.1 Pro (High) | Gemini 3 Pro (High) | Opus 4.6 (Max) | GPT-5.2 (xhigh) | GPT-5.3-Codex (xhigh) |
|---|---:|---:|---:|---:|---:|
| TB 2.0, **Terminus-2 harness** | **68.5%** | 56.9% | 65.4% | 54.0% | **64.7%** |
| TB 2.0, **other best self-reported harness** | — | — | — | 62.2% (Codex) | **77.3% (Codex)** |

> **GPT-5.3-Codex: 64.7% under Terminus-2, 77.3% under Codex CLI. Same model,
> same 89 tasks, same stated effort. +12.6 points of pure harness.**

That is **1.75× the 7.2 pp** Anthropic measured, it is the largest published
harness effect we have found, and **it was disclosed by a third party, not by
the harness vendor.** OpenAI itself never states which harness produced 77.3%.

Google's methodology text is the most complete disclosure of any vendor:
*"Terminal-Bench 2.0 results are reported for the default agent harness
(Terminus 2) and for other best self-reported harnesses where applicable…
Averaged over 10x runs for SWE-Bench Verified and 5x runs for SWE-Bench Pro."*
It also discloses a benchmark defect nobody else does: three SWE-bench Verified
instances (`astropy__astropy-7606`, `sphinx-doc__sphinx-8595`,
`sphinx-doc__sphinx-9711`) that **cannot be passed by any solution** on the
official harness, worth +0.6% once fixed.

#### (b) Anthropic Opus 4.6 system card, Figure 2.5.A — verified from the PDF

All five prior claims **confirmed verbatim**, with one location correction:
**this is §2.5, not §2.4.** §2.4 is SWE-bench and contains no Terminal-Bench
content.

| Model | Harness | Effort | Score | Trials | n |
|---|---|---|---:|---:|---:|
| Claude Opus 4.6 | Harbor + **Terminus-2**, default parser | adaptive, **max** | **65.4%** | **1,335** (89×15) | 89 |
| Claude Opus 4.6 | Terminus-2 | medium | 61.1% (−23% output tok) | — | 89 |
| Claude Opus 4.6 | Terminus-2 | low | 55.1% (−40% output tok) | — | 89 |
| **GPT-5.2-Codex** | **Terminus-2** (Anthropic repro) | not stated | **57.5%** | 890 joint | 89 |
| **GPT-5.2-Codex** | **OpenAI Codex CLI** | not stated | **64.7%** | 890 joint | 89 |
| Gemini 3 Pro | Terminus-2 (repro) | not stated | 56.2% | 445 joint | 89 |
| Gemini 3 Flash | Terminus-2 (repro) | not stated | 50.3% | 445 joint | 89 |

**A structural finding the prior docs missed.** Anthropic's *summary* table
(2.3.A) carries GPT-5.2's **own-harness 64.7%**, not the harness-matched 57.5%.
**Only Figure 2.5.A is harness-matched; the headline comparison table is not.**
The table also calls the system "GPT-5.2" where the figure calls it
"GPT-5.2-Codex".

SWE-bench Verified 80.84% is confirmed as a **25-trial average**, rising to
81.4% with the disclosed prompt modification (*"You should use tools as much as
possible, ideally more than 100 times…"*).

#### (c) Anthropic Claude Opus 5 system card — Terminal-Bench is retired

**Seven Anthropic cards now postdate Opus 4.6** (Sonnet 4.6, Opus 4.7, Opus 4.8,
Mythos Preview, Fable 5 & Mythos 5, Sonnet 5, Opus 5). The Opus 5 card is the
newest and **contains zero Terminal-Bench numbers**. §8.5, verbatim:
*"FrontierBench v0.1 is a successor to Terminal-Bench 2.1 developed by the same
team. It's a refreshed set of 74 harder tasks."*

It preserves the harness-vs-harness structure, and adds **two more same-model
harness pairs** — the only ones published since Fig 2.5.A:

| Model | Harness | Effort | Score | Trials | n |
|---|---|---|---:|---:|---:|
| **Claude Opus 5** | **Harbor** | max | **43.3%** | 5 | 74 |
| **Claude Opus 5** | **mini-swe-agent / GKE** | **xhigh** | **44.4%** | **370** (74×5) | 74 |
| Claude Opus 5 | mini-swe-agent / GKE | max | ~43% ("within noise") | — | 74 |
| Claude Opus 5 | mini-swe-agent / GKE | high | 39% (−19% output tok) | — | 74 |
| Claude Opus 5 | mini-swe-agent / GKE | low | 25% (−64% output tok) | — | 74 |
| **GPT-5.6 Sol** | **Codex** | not stated | **34.4%** | — | 74 |
| **GPT-5.6 Sol** | **mini-swe-agent / same GKE setup** | max | **37.5%** | — | 74 |
| Claude Fable 5 | Harbor | — | 33.8% | — | 74 |
| Claude Fable 5 | mini-swe-agent / GKE | max | 33.7% | — | 74 |
| Claude Opus 4.8 | Harbor | — | 21.1% | — | 74 |
| Claude Opus 4.8 | mini-swe-agent / GKE | — | 18.7% | — | 74 |

Read those pairs carefully, because they cut against the received wisdom:

- **Opus 5 does 1.1 pp *better* under mini-swe-agent than under Harbor.**
- **GPT-5.6 Sol does 3.1 pp *better* under mini-swe-agent than under its own
  Codex harness** — the opposite sign to the 12.6 pp Codex advantage Google
  measured on GPT-5.3-Codex.
- The effort ladder is again enormous: **25% → 44.4%, 19.4 pp from effort
  alone**, dwarfing every harness delta on this page.

> **And a disclosure with no parallel anywhere in the field**, §8.5 verbatim:
> *"Opus 5 safety classifiers flagged and refused 5% of the API calls, in 4% of
> the total trials, falling back to Opus 4.8. Fable safety classifiers flagged
> 42% API calls on 26% of trials, also falling back to Opus 4.8."* and
> *"GPT-5.6 Sol never triggers safety classifiers in this eval, and thus no
> fallback model was configured or needed."*
>
> **Fable 5's FrontierBench score is partly a different model's work, on 26% of
> trials.** No leaderboard row anywhere carries this information, and there is
> no way to detect it from outside.

Opus 5's SWE-bench Verified is **96.0%**, 5 trials, **harness not disclosed** —
and it appears only in §8.2 prose, not in the results table.

#### (d) OpenAI — no coding numbers in any system card

Verified by text extraction of the GPT-5.3-Codex system card
(`deploymentsafety.openai.com/gpt-5-3-codex/gpt-5-3-codex.pdf`, 2026-02-05):
**`"SWE-bench"` = 0 occurrences, `"Terminal-Bench"` = 0, `"Terminus"` = 0.**
OpenAI's system cards carry no coding-benchmark scores at all. Every OpenAI
coding number is blog-only, with the harness undisclosed.

> **CORRECTION, and it is ours.** `what-harnesses-benchmark.md` §4 presents
> *"Codex CLI, `xhigh`, web search on, `--dangerously-bypass-approvals-and-sandbox`,
> up to 1,000 turns, compaction every 100K tokens, `resume --last` on abort"* as
> "the best-disclosed configuration anywhere", implicitly behind OpenAI's coding
> numbers. **The string is real and verbatim in the card — but its scope is
> Irregular's cyber-range evaluation (Preparedness / Cybersecurity), not
> SWE-bench and not Terminal-Bench.** The `resume --last` denominator-inflation
> criticism stands as a criticism of that cyber eval. It must not be attached to
> a coding score.

OpenAI's blog-only coding numbers, harness undisclosed on every row:
GPT-5.3-Codex TB 2.0 **77.3%** / SWE-bench Pro 56.8% / **SWE-bench Verified not
reported**; GPT-5.5 TB 2.0 82.7%; GPT-5.1-Codex-Max SWE-bench Verified 77.9%
(n=500 stated — the only denominator OpenAI states anywhere).

**GPT-5.6 is the newest OpenAI model, with three variants — Sol, Terra, Luna —
and an `ultra` effort tier that runs four agents in parallel.** It reports
**Terminal-Bench 2.1 at 88.8% (91.9% Ultra)** with **no harness named**, and
**drops SWE-bench Verified entirely.**

---

## 4. cline's published dataset — the only place a third harness meets GLM-5.2

`github.com/cline/benchmark-results`, branch `main` @ `61c1e5a0`, created and last
pushed **2026-06-26**. Fetched as raw file bytes.

**The repo contains exactly one dataset.** 107 paths, all under
`terminal-bench/2026-06-open-weights/`. **Not present:** any TB 2.1 run, any
Kimi K3 run, any `diffEditSuccess` statistic (that is a telemetry field in
`cline/cline`, never published), any `cline-bench` scores. Our prior doc's
mention of "Kimi K3 (2.1 post)" refers to a **blog post**, not to this repo —
see §9.

Fixed across every cell: **TB 2.0, 89 tasks, pass@1, one trial per task**,
OpenRouter routes, Modal, `--timeout-multiplier 2.0`, n=20 concurrency,
2026-06-24/25, cline CLI 3.0.29 / opencode 1.17.9 / pi 0.73.1
(`@mariozechner/pi-coding-agent`).

**The complete matrix.** All four of our secondhand figures verified exactly.

| Model (OpenRouter route) | cline, medium | opencode, medium | pi, medium | cline, reasoning **off** |
|---|---:|---:|---:|---:|
| `z-ai/glm-5.2` | **68.5%** (61/89) | 59.6% (53/89) | 57.3% (51/89) | 57.3% (51/89) |
| `moonshotai/kimi-k2.7-code` | **61.8%** (55/89) | 59.6% (53/89) | **61.8%** (55/89) | n/a¹ |
| `minimax/minimax-m3` | **61.8%** (55/89) | 49.4% (44/89) | 47.2% (42/89) | 46.1% (41/89) |
| `xiaomi/mimo-v2.5-pro` | **60.7%** (54/89) | 44.9% (40/89) | 48.3% (43/89) | 47.2% (42/89) |

¹ omitted — the OpenRouter Kimi endpoint requires reasoning.

**This is the single most useful table in the document for us**, because it is
the only published cross-harness data on our exact model. Read it carefully:

- **cline wins all four models**, by 8.9 / 0.0 / 12.4 / 12.4 pp over the next
  harness. That is a larger and more consistent harness effect than anything on
  any leaderboard.
- **Reasoning off costs 11.2 pp on GLM-5.2, 15.7 pp on MiniMax M3, 13.5 pp on
  MiMo.** Effort, again, dominates.
- **But on `kimi-k2.7-code` the harness spread collapses to 2.2 pp.** The size of
  the harness effect is a property of the model, not of the harnesses.

**Caveats cline states itself, verbatim:** *"OpenCode and Pi-Code were installed
from their then-current npm `latest` packages at run time. **These are not
official benchmark numbers from OpenCode or Pi-Code.**"* And: `unscored` cells
exist where a trial's `result.json` exposed no 0.0/1.0 reward, so `failed +
passed ≠ 89` on several rows. **cline also did not use one frozen binary** — two
runs used tarball `3.0.29-main-218db385`, the other five
`3.0.29-main-14a28b055`.

**And the statistics.** n=1 trial per task, no stderr published. At 89 tasks a
1σ is roughly 5 pp, so **the cline-vs-opencode GLM-5.2 gap of 8.9 pp is about
1.3σ.** It is suggestive; it is not significant.

---

## 5. goose's Harbor table — the only model-pinned harness table with economics

`raw.githubusercontent.com/block/goose/main/evals/harbor/README.md`.
**Answer to the open question: yes, it publishes pass rates**, plus a full
pass/fail/error/timeout split, tokens, cost, turns and compute-hours. Config:
`terminal-bench/terminal-bench-2`, **89 tasks**, `n_attempts: 1`,
`n_concurrent_trials: 4`, max 100 turns, model pinned to
`anthropic/claude-sonnet-4-6` on nine of ten rows. **Undated.**

| Job | Harness | Rate | Pass/89 | Fail | Err | **Timeout** | In tok | Out tok | Turns | Cost |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `goose-sonnet46-full-code-mode` | goose + codemode | **57.3%** | 51 | 20 | 2 | 16 | 63.3M | 1.1M | 3k | $206.43 |
| `sonnet46-sum_codem` | goose + codemode + summon | **57.3%** | 51 | 23 | 2 | 13 | 78.1M | 1.4M | 3k | $254.53 |
| `claude-sonnet46-full` | **harbor vanilla `Goose`** (curl-installed) | 55.1% | 49 | 23 | 1 | 16 | 102.3M | 1.2M | 3k | **$42.83** |
| `sonnet46-summon-full` | goose + summon | 55.1% | 49 | 19 | 3 | 18 | 67.2M | 1.0M | 3k | $217.28 |
| `opencode-sonnet46-full` | **opencode** | 52.8% | 47 | 23 | 0 | 19 | 111.5M | 1.6M | 3k | $70.30 |
| `sonnet46-full` | **stock goose** (`developer,todo`) | 50.6% | 45 | 21 | 3 | 20 | 62.4M | — | 3k | — |
| `goose-1.30-sonnet46-full` | goose 1.30 | 50.6% | 45 | 24 | 2 | 18 | 2.4M² | — | 3k | — |
| `sonnet46-dev-only` | goose, `developer` only | 48.3% | 43 | 25 | 2 | 19 | 70.6M | 1.2M | 3k | $229.19 |
| `pi-sonnet46-full` | **pi** | 47.2% | 42 | 25 | 1 | 21 | 114.4M | 1.8M | 3k | $74.82 |
| `nemotron-full` | goose | **1.1%** | 1 | 64 | 2 | 22 | 9.5M | 2.2M | **1k** | — |

² 2.4M against siblings' 62–114M: the token accounting is not uniform across
rows. Treat per-row token figures as indicative.

> **Two findings that change how this table may be cited, and neither was in our
> prior docs.**
>
> 1. **goose ran pi with reasoning OFF.** README, verbatim: *"For pi
>    specifically you can lift the existing config we used: `kwargs: thinking:
>    "off"`"*. So "pi 47.2%, last place" is **pi handicapped**. cline ran the same
>    harness at `thinking=medium` and got 57.3% on a *weaker* model. The two
>    published datasets disagree about pi, and the disagreement is a
>    configuration difference, not a measurement.
> 2. **goose ran itself with reasoning off too.** `evals/harbor/config_template.yaml`
>    sets `GOOSE_THINKING_EFFORT: "off"` for every `GooseBinaryAgent` run. The
>    opencode YAML sets no reasoning option at all, so opencode got the provider
>    default. **This table is model-pinned and effort-scrambled.**
>
> The correct reading is therefore narrower than the table's shape suggests: it
> compares *goose's own configurations* to each other cleanly, and compares goose
> to opencode and pi only under settings goose chose for them.
>
> **It also happens to be the exact defect we have in our own head-to-head** —
> OSA's arm ran `think:false` while its competitors' clients had reasoning on.
> We made goose's mistake in the opposite direction.

**What does survive, and it is the most useful thing in the table: timeouts.**
Every row loses **13–22 of 89 tasks to timeout**, 15–25% of the benchmark, at
goose's default budget. cline ran at `--timeout-multiplier 2.0`. **That alone
plausibly accounts for most of the gap between cline's 55–68% band and goose's
47–57% band, and it means the two datasets cannot be laid side by side even
though they share a task set.**

The `nemotron-3-nano-30b-a3b` row is the documented too-weak-model failure mode:
**1.1% (1/89)**, and note its turn count is **1k against everyone else's 3k** —
goose's own commentary is that the small model *"gives up or loses tool-call
structure earlier, so it doesn't even reach the 100-turn cap on most trials."*

**Nothing else in `block/goose/evals/` contains run data** — the rest is harbor
tooling. goose's other published numbers are a 2025 "Vibe Check" (models through
goose, LLM-judged, 8 tasks) and third-party leaderboard rows.

---

## 5A. Everyone else — the full sweep

Thirty-odd projects checked against their own repos, papers and leaderboard
submissions. The summary is short: **almost nobody publishes a quotable number
about their own harness.**

### 5A.1 Publishes nothing at all about itself

**Amp** (~130 posts scanned; stated position: *"evals are primarily useful as
unit tests and regression tests"*), **Cursor CLI** (internal "Cursor Bench", no
numbers), **opencode** (a DB-backed internal leaderboard page with no committed
results), **grok-build** (3,757 files; only Rust micro-benchmarks for PTY and
render latency), **gemini-cli** (`evals/README.md`: *"They are also distinct
from broad industry benchmarks (like SWE-bench)"* — CI gates only),
**Roo Code** (`Roo-Code-Evals` is an Aider-Polyglot clone with zero results
files; `roocode.com/evals` now redirects and publishes nothing), **Continue**
(`eval/` contains only `.gitignore`), **Void**, **Melty**, **Copilot CLI /
coding agent**, **Charm Crush**, **Sculptor/Imbue**, **JetBrains Junie**
(site claims *"Top performer on SWE-Rebench"* with no score, no model, no date),
**aider as a harness** (aider publishes a *model* leaderboard; zero numbers
about the aider harness itself).

**Zed** publishes agent metrics — 826.3K sessions, 7M turns/30d, p50 turn 12.8 s
— and **no capability score at all**. **Codebuff** publishes *"higher quality
and 100+ seconds faster than Claude Code"* with no percentage, no model, no
date. **pi**'s author ran TB 2.0 on Claude Opus 4.5 at 5 trials/task and the
score exists **only inside a screenshot**.

### 5A.2 Publishes something quotable

| Project | Benchmark | n | Score | Model + effort | Source class |
|---|---|---:|---:|---|---|
| **Kimi K3 model card** | Terminal-Bench 2.1 | not stated | **88.3** | Kimi K3, **max effort**, temp 1.0 — *"evaluated with the **Kimi Code harness**"* | **primary** (repo README) |
| **Kimi K3** | DeepSWE v1.1 | not stated | **67.5 Kimi Code / 67.3 mini-SWE-agent** | Kimi K3, max ✅ | **primary — a same-model harness pair** |
| **Kimi K3** | Kimi Code Bench 2.0 | 80 | **72.9 Kimi Code / 73.7 Claude Code** | Kimi K3, max ✅ | **primary — a second same-model pair, and Kimi's own harness loses** |
| **Kimi K2.5 model card** | Terminal-Bench 2.0 | 89 | 50.8 | K2.5, **non-thinking** ✅ — harness is **Terminus-2, not Kimi CLI** | primary, avg of 5 runs |
| **Kilo Code** | TB 2.0, *"through Kilo's harness — not a generic scaffold"* | 89/trial | GPT-5.6 Sol 76.2 · Kimi K3 72.8 · Opus 5 71.5 · Fable 5 71.0 · Sonnet 5 59.6 · **GLM 5.2 53.0** · Grok Build 0.1 50.6 · … (34 entries) | display names only, **no effort, no date, no trial count** | vendor leaderboard — under-specified |
| **Trae** | SWE-bench Verified | 500 | 75.2% | 4 named models, ensembled (`attempts: 2+`) | **primary** (arXiv 2507.23370) |
| **OpenHands SDK** | SWE-bench Verified | 500 | V1 **72.8%** (Sonnet 4.5 extended thinking) · best **76.6%** (Opus 4.5) | models named, effort mostly not | **primary** (arXiv 2511.03690) |
| **SWE-agent** | SWE-bench **full** | 2,294 | 12.47% | GPT-4 Turbo | **primary** (arXiv 2405.15793) |
| **AutoCodeRover** | SWE-bench Lite | 300 | 19% | `gpt-4-0125-preview`, temp 0.2 | **primary** (arXiv 2404.05427) |
| **Agentless** | SWE-bench Lite | 300 | 32.0% (96/300) | `gpt-4o-2024-05-13` | **primary** (arXiv 2407.01489) |
| **Refact.ai** | Aider Polyglot | 225 | **93.3% thinking on / 92.9% off** | **Claude 3.7 Sonnet, thinking mode stated** ✅ | blog — but it is one of only ~5 sources in the field that pins effort |
| **Warp** | Terminal-Bench 1.0 | 80 | 52% | `claude-sonnet-4` + `claude-opus-4` planning, ~2% fallback | blog + leaderboard row |
| **Qwen Code** | SWE-bench Verified | 500 frozen manifest | **376/492 = 76.4% — QUARANTINED by its own gate, not published** | `qwen3.7-max`, effort not stated | **primary** (release payload) |

**Qwen Code deserves a note of respect.** It has the most rigorous published
pipeline in this entire sweep — a frozen 500-instance manifest, an automated
quality gate, and a release artefact per run — and **every 500-instance run is
`QUARANTINED` by that gate.** The only `SUCCEEDED` run has n=1. A project that
refuses to publish its own number because its own gate says no is doing exactly
what `bench/report`'s gate does for us.

**Three attribution traps to avoid.** "Grok CLI" on the Terminal-Bench boards is
**Superagent's `superagent-ai/grok-cli`**, not xAI's grok-build. Gemini model
cards attribute their Terminal-Bench numbers to **Terminus-2**, never to
gemini-cli. Kimi K2.5's numbers are Terminus-2 and an unnamed internal
framework; only **K3** is a genuine own-harness model-card claim.

---

## 6. The head-to-head map: who has ever been measured against whom

A cell is filled only where **two or more harnesses ran the same model on the
same task set**. This is the whole document in one view.

| Comparison | Where it exists | Effort pinned? |
|---|---|---|
| **Terminus-2 vs everyone** | TB 2.0 (40+ rows), TB 2.1 (4 pairs), TB 1.0, Harbor-Index (9 pairs), Anthropic Fig 2.5.A, Google's table | only on TB 2.1 |
| **Codex CLI vs Terminus-2** | TB 2.1 (GPT-5.5, xhigh, +5.17) · Anthropic Fig 2.5.A (GPT-5.2-Codex, +7.2) · Google (GPT-5.3-Codex, +12.6) · Harbor-Index (GPT 5.5, +8.4) | TB 2.1 and Google yes |
| **Claude Code vs Terminus-2** | TB 2.1 (Opus 4.7, max, +2.83) · TB 2.0 (Opus 4.6, 4.5, Sonnet 4.5, Opus 4.1, Haiku 4.5 — Claude Code **loses all five**) · Harbor-Index (Opus 4.8, +4.9; and **loses on 3 open models**) | TB 2.1 only |
| **Gemini CLI vs Terminus-2** | TB 2.1 (Gemini 3 Pro high, −8.09; Gemini 3.1 Pro high, +0.22) · TB 2.0 (2.5-pro, 2.5-flash, 3-flash — **Gemini CLI loses all three**) · Harbor-Index (+2.7) | TB 2.1 only |
| **mini-SWE-agent vs Terminus-2** | TB 2.0 (6 models) · TB 1.0 (`claude-sonnet-4`) · **Anthropic Opus 5 card (Opus 5, Fable 5, Opus 4.8)** | Opus 5 card only |
| **mini-SWE-agent vs Codex CLI** | TB 2.0 (`gpt-5`, `gpt-5-mini`, `gpt-5-nano`, `gpt-5-codex`) · **Anthropic Opus 5 card (GPT-5.6 Sol: 37.5 vs 34.4)** | Opus 5 card only |
| **mini-SWE-agent vs SWE-agent** | SWE-bench Pro — but the turn budget changes with the harness (50 vs 250), so it is **not a clean pair** | no |
| **OpenHands vs Terminus-2 vs Claude Code** | TB 2.0, six models, one coordinated sweep, all `verified: true` | no |
| **Kimi Code vs mini-SWE-agent** | Kimi K3 model card, DeepSWE v1.1 (67.5 vs 67.3) | yes — max |
| **Kimi Code vs Claude Code** | Kimi K3 model card, Kimi Code Bench 2.0, n=80 (**72.9 vs 73.7** — Kimi's own harness loses on its own benchmark) | yes — max |
| **goose vs opencode vs pi vs harbor-vanilla** | goose's Harbor table, `claude-sonnet-4-6`, 89 tasks | **no — and goose ran pi *and itself* with reasoning off** |
| **cline vs opencode vs pi** | cline's dataset, GLM-5.2 + 3 open models, 89 tasks | **yes — all at medium**, plus a reasoning-off arm |
| **OSA vs codex vs opencode vs goose vs mini-swe-agent** | `bench/headtohead/runs/h2h-1`, `glm-5.2:cloud`, **n=6** | no — and OSA's arm had reasoning off |

### 6.1 The comparisons that do not exist

These are as important as the entries. Every one of them is a question the field
cannot currently answer.

1. **Claude Code vs Codex CLI on one model. Anywhere.** They never share a model
   on TB 2.0, never on TB 2.1, never on TB 1.0, never on TB 3.0, and never in
   Harbor-Index (each is paired with its own vendor's model). Anthropic compared
   Codex CLI to *Terminus-2*. Google compared Codex CLI to *Terminus-2*.
   **The two flagship CLIs of the field have never been placed on the same
   model, and that is why no ranking of them exists.** The closest available
   inference is transitive through Terminus-2, and transitive inference across
   different models, dates and effort settings is not a measurement.
2. **GLM-5.2 appears on no leaderboard row at all.** Not on TB 2.0, not on
   TB 2.1, not on any SWE-bench board. Its only *board* appearances are TB 3.0
   (Claude Code, max, 4.59%) and the Harbor-Index pair (Claude Code 8.5% /
   Terminus-2 9.8%). Everything else on our model is off-board: **cline's
   dataset (cline 68.5 / opencode 59.6 / pi 57.3, all medium, TB 2.0, 89)** and
   **Kilo Code's own vendor leaderboard (53.0%, effort and date unstated)**.
   Those two sources plus our own runs are the entire universe of GLM-5.2
   harness data, and cline's is the only one that meets the admission rule.
3. **Cursor CLI, Amp, Devin, Windsurf, Roo, Kilo, Warp, Factory Droid, Trae,
   Augment, Refact against anything, on a disclosed model.** Cursor CLI appears
   on TB 2.1 and TB 3.0 but only ever on Grok, so it has no same-model partner.
   Factory Droid, Warp, Trae, Refact, Augment, Zencoder, Blackbox and Amazon Q
   all have SWE-bench rows and all of them say `Undisclosed` or `Multiple`.
   **Amp, Windsurf, Roo and Kilo publish nothing on any board at all.**
4. **Any harness comparison at all on Terminal-Bench 3.0.** Ten rows, ten
   distinct models.
5. **Any two harnesses on the same model with effort pinned on a board with
   more than 17 rows.** TB 2.1 is the only effort-carrying board, and it has
   exactly four valid pairs.
6. **Any harness's *own* number on a *current* board.** TB 2.1 has closed
   community submissions; SWE-bench Verified and Multilingual are academic-only
   since 2025-11-18. **A new harness in 2026 has no route onto any board the
   field reads.** That is OSA's structural position, and it is not specific to
   OSA.

---

## 7. OSA's position

Every caveat is attached. Nothing here is offered as a ranking.

### 7.1 What we have actually measured: `h2h-1`

`bench/headtohead/runs/h2h-1/` — the only model-pinned, same-task,
same-limit comparison we own.

| Field | Value |
|---|---|
| Benchmark | Terminal-Bench **2.0** via Harbor **0.21.0** |
| Denominator | **6 tasks** — `regex-log`, `sparql-university`, `cancel-async-tasks`, `configure-git-webserver`, `largest-eigenval`, `schemelike-metacircular-eval` |
| Selection | declared curated set `default6`, seed 20260814 — **not a random sample of the 89** and must never be described as one |
| Model | `glm-5.2:cloud`, one Ollama daemon, identical for every arm |
| Effort | **not pinned**; OSA's arm ran with **reasoning disabled** (see 7.2) |
| Attempts | 1 per task per arm, best-of-1, no reranking, no test-time compute |
| Limits | `task.toml agent.timeout_sec × 1.0`; **no turn cap** on any arm |
| Graded by | each task's own `tests/test.sh` on final container state |
| Date | 2026-08-14 |

| Arm | Solved | 95% CI | Harness faults | Model faults | Ambiguous |
|---|---:|---|---:|---:|---:|
| `codex` | **6/6** | 61–100% | 0 | 0 | 0 |
| `mini-swe-agent` | **6/6** | 61–100% | 0 | 0 | 0 |
| **`osa`** | **4/6** | 30–90% | **0** | 2 | 0 |
| `opencode` | 3/6 | 19–81% | 0 | 2 | 1 |
| `goose` | 3/6 | 19–81% | **3** | 0 | 0 |

**Read the intervals, not the order.** Every interval contains most of the other
arms. All ten pairwise exact-McNemar tests returned **"not distinguishable"**;
the largest discordant count was 3, and **6 discordant pairs are needed before a
two-sided exact test can reach p<0.05**. Only 4 of the 6 tasks separated the arms
at all. Ordering these arms is describing this sample, not ranking the harnesses.

Two arm-level details that are results in their own right:

- **goose lost 3 of 6 to `agent_never_reached_model`** — a harness fault, not a
  model fault. Its 3/6 understates it by that much.
- **OSA's 2 losses were both `completed_but_wrong`** — the harness worked and
  the answer was wrong. **Harness-fault rate 0.0%.**

**Declared asymmetries, none hidden.** All arms hit one daemon and one model but
over three wire protocols: OSA `/api/chat` (Ollama-native), codex and opencode
`/v1/responses`, goose and mini-swe-agent `/v1/chat/completions`. The OSA
artefact was **stale** — it predates two commits (`6291d16a` verification gate,
`e27bdba5` doctor/subagent model). The run was **under contention** — one other
benchmark process and two foreign containers on the same host, drawing on the
same provider account.

**Six arms could not be run at all, and their absence is not a result about
them**: `claude-code` (speaks `/v1/messages`; Ollama does not serve it),
`gemini-cli` (Google API only, no key), `cursor-cli` and `copilot-cli`
(subscription, server-side model selection), `grok-build` (no `XAI_API_KEY`),
`devin` (hosted).

### 7.2 The handicap that makes 4/6 a floor, not a measurement

**OSA sent `think:false`.** codex, opencode and mini-swe-agent called the *same*
`glm-5.2:cloud` through their own clients and received `reasoning_content` on
nearly every step — **82.8% of codex's emitted characters on `schemelike`**.
Commit `337e2405` retracts the derived "162:1 input:output ratio" finding on
exactly this basis: it was dividing OSA's non-reasoning output into its input and
setting it against reasoning-inclusive output.

Corrected, one runaway task excluded: **OSA 69:1, codex 75:1, opencode 76.5:1** —
already inside the field's published 56–85:1 band. The apparent deficiency was
an artefact of the reasoning-disabled condition.

Three paired `regex-log` runs, one per condition — all n=1, confounded by
differing artefacts, direction not subtle:

| Condition | Turns | Input tok | Output tok |
|---|---:|---:|---:|
| think **false**, old artefact | 25 | 759,548 | 13,957 |
| think **true**, old artefact | 9 | 184,057 | 15,878 |
| think **true**, artefact `f6981b61` | **3** | **54,237** | 16,469 |

**14× less input at constant output.** So the 4/6 is a number produced by a
handicapped arm against unhandicapped competitors, and **it understates OSA by
an unknown amount.** It is not a ceiling and must not be quoted as one.

### 7.3 The full-89 run — in flight, no figure

`bench/terminalbench/runs/osa-tb20-full89-f6981b61/config.json`:

| Field | Value |
|---|---|
| Benchmark | Terminal-Bench **2.0**, 89 tasks, status `superseded` |
| Model | `ollama/glm-5.2:cloud` |
| Effort | **`medium`**, `ollama_think: "true"` — reasoning **on** |
| Timeout multiplier | **2.0** — deliberately matching cline's published runs |
| Concurrency | 4 · Harbor 0.21.0 · attempts 1 |
| Artefact | built from `f6981b61`, lib clean at launch |
| Started | 2026-08-14T19:04:49Z |

> **RESULT: PENDING.** ⟨placeholder — fill with the final figure, its Wilson
> interval, the count of tasks excluded for oracle failure, and the count
> re-run after the timeout fix. Do not fill this from a partial run.⟩

**Known handicaps on this specific run.**

1. **The timeout multiplier never reached the agent.**
   `driver/osa_headless.py:49` reads
   `RUN_TIMEOUT = int(os.environ.get("OSA_BENCH_RUN_TIMEOUT", "1800"))` — a
   hardcoded 1800 s deadline independent of every Harbor multiplier. Effective
   budget was `min(Harbor 3600 s, ours 1800 s) = 1800 s` while `config.json`
   truthfully recorded `timeout_multiplier: 2.0`, i.e. it **claimed a parity it
   did not have.** Measured live: `make-mips-interpreter` died at 1875 s wall
   with `osa_error: "agent exceeded 1800s"` — our string, not Harbor's. 1 of the
   first 28 trials hit the wall. Fixed host-side in `ab67bf70` (the driver is
   *not* edited, because it uploads per-trial and editing it mid-run would give
   later trials a different budget from earlier ones). **The fix cannot affect
   the run in flight.** The remedy is to let it finish, re-run only the
   timed-out tasks, and name them.
2. **Seven of the 89 tasks fail their own reference solution on this machine.**
   Measured, not assumed: `bench/terminalbench/runs/_controls/tb2.0/controls.json`
   records **oracle 82/89 = 92.1%**, `nop` 0/89. The misses are
   `build-cython-ext`, `build-pmars`, `caffe-cifar-10`, `make-doom-for-mips`,
   `mcmc-sampling-stan`, `protein-assembly`, `rstan-to-pystan`.
   **The achievable ceiling on this run is 92.1%, not 100%**, and both
   denominators must be printed.
3. **The task set is superseded.** 26 tasks were modified in TB 2.1 upstream;
   27 differ byte-for-byte on disk (`datasets.DIFF_TB20_TB21`). A failure on one
   of those 27 is not evidence about OSA until reproduced on 2.1. **And TB 2.1
   is measurably healthier here: oracle 86/88 observed = 97.7%, misses only
   `build-cython-ext` and `mcmc-sampling-stan`.** Switching datasets buys 5.6 pp
   of achievable ceiling.

### 7.4 What OSA's numbers may be laid beside

| OSA number | Comparable to | Why / why not |
|---|---|---|
| `h2h-1` 4/6 | **only itself** | Model pinned across arms, so internally valid. n=6 gives ±35 pp and every pairwise test is null. Handicapped by `think:false`. |
| A completed full-89 TB 2.0 run | **cline's GLM-5.2 rows — and the effort matches** | Same task set (89), same denominator, same `--timeout-multiplier 2.0`, same pass@1, same single trial, **and cline's arms all ran `reasoning=medium`, which is exactly what our run config pins.** The remaining differences are the serving path (`ollama/glm-5.2:cloud` vs `openrouter:z-ai/glm-5.2`), 7 weeks of drift, and our 1800 s driver deadline on the tasks that hit it. **This is a real, joinable cell.** |
| The same run vs **goose's 89-task table** | **no** | Different model (`claude-sonnet-4-6`), and goose ran its arms with reasoning off. Nothing joins. |
| The same run vs the **TB 2.0 board's 142 rows** | **no** | Not one of those 142 rows is on GLM-5.2, and none of them state reasoning effort. There is no cell to join on. |
| Any TB 2.1 / TB 3.0 / Harbor-Index row | **no** | Different task set, different model, 5 trials per task with error bars, effort tiers we do not pin. TB 2.1 submissions are closed to us regardless. |
| Any SWE-bench Verified figure | **no** | Different model, and the boards are academic/lab-submission-only since 2025-11-18. |

---

## 8. What OSA would have to run to be legitimately comparable to each harness

Ordered by how achievable it is. "Comparable" means: a cell exists that both
sides occupy.

| Target harness | What it would take | Feasible here? |
|---|---|---|
| **cline CLI 3.0.29** | The run already in flight: TB 2.0, 89, `glm-5.2`, pass@1, `--timeout-multiplier 2.0`, **effort medium — which already matches cline's arms exactly.** Then re-run the tasks that hit the 1800 s driver deadline, and state that the serving path differs (Ollama vs OpenRouter). | **Yes — in flight, and the cell is genuinely joinable.** |
| **opencode 1.17.9**, **pi 0.73.1** | Same run. Both are in cline's published GLM-5.2 matrix at the same effort. | **Yes — same run.** |
| **goose** | Their table is `claude-sonnet-4-6` and their arms ran **reasoning off**, so joining it would require both a Sonnet key *and* reproducing a handicap. **Do not try to join it.** Re-run goose ourselves on `glm-5.2` instead — already working at n=6. | **Yes, locally.** Extend the head-to-head to 89. |
| **mini-SWE-agent** | Already a working local arm on the shared model. Extend it to the full 89 alongside OSA. **This is the highest-value single action in this table** — the field treats mini-SWE-agent as the scaffold control, and "a 190-line bash loop matches OSA" is a publishable finding whichever way it lands. | **Yes.** Only cost. |
| **Codex CLI** | Already a working local arm (`/v1/responses`, `reasoning_effort=null`). Extend to 89. To join the *published* Codex numbers instead would need GPT-5.5/5.6 at a stated effort. | **Locally yes. Publicly no.** |
| **Terminus 2** | Not currently an arm, but it is a Harbor built-in and needs no credential beyond the shared model. **It is the single most-compared harness in existence** — 40+ rows on TB 2.0 alone, and one half of all nine Harbor-Index pairs. Adding it as an arm gives every OSA number a universal reference point. | **Yes, cheaply. Do this.** |
| **Claude Code** | Blocked twice over: it speaks `/v1/messages`, which Ollama does not serve, and there is no `ANTHROPIC_API_KEY` here. An Anthropic-Messages→OpenAI translating proxy would unblock it but inserts a translation layer into one arm only — a confound that would have to be declared. Joining its *published* rows needs a frontier Anthropic model at a stated effort. | **No, without a key.** |
| **Gemini CLI** | Google API only; no OpenAI-compatible path in the adapter, no key. | **No.** |
| **Cursor CLI**, **Copilot CLI** | Server-side model selection through a subscription backend. Even with a subscription the model would not be held fixed, so the comparison would measure their model, not their harness. | **Impossible in principle.** |
| **Grok Build** | Needs `XAI_API_KEY` and an xAI-hosted model. Same model-fixing problem. | **No.** |
| **Devin** | Hosted on Cognition's infrastructure with their model. Nothing preserves a fixed model. | **Impossible in principle.** |
| **Any TB 2.1 / TB 3.0 board row** | A frontier model, that model's exact effort tier, and **5 trials per task**. TB 2.1 has also **closed community submissions**, so even a perfect run could be compared to the board but never added to it. | **No, without a frontier key and 5× the budget.** |

**The three things that would move OSA from "one internal datapoint" to
"comparable":**

1. **Finish the 89 with reasoning on and the timeout fix applied to the
   affected tasks**, report both denominators (of 89, and of the 82 the oracle
   can actually pass), with a Wilson interval.
2. **Add Terminus 2 as a local arm on the shared model.** It costs almost
   nothing and it is the universal joint across every board in §3.
3. **Get one frontier credential.** Not because GLM-5.2 hides harness effects at
   TB 2.0 difficulty — it does not, the published spread there is 11.2 pp — but
   because every board we might be measured against is on frontier models, and
   because the prompt-cache defect cannot be exercised through Ollama at all.

---

## 9. Claimed, unverifiable — quarantine

Nothing in this section may be used to support a conclusion. Each entry fails
the admission rule on a stated field.

| Claim | Claimant | Fails on |
|---|---|---|
| **cline, Terminal-Bench 2.1 = 88.8% (79/89)** with Kimi K3 | cline blog, 2026-07-24 | **The highest harness number published anywhere, on the weakest evidence in this document.** One blog post. Single confirmation run, and cline states **"two confirmation runs got invalidated"**. No `results.json`, no leaderboard entry, and **absent from cline's own transparency repo**, which has not been touched since 2026-06-26. Final reasoning setting unstated. |
| **Augment (Auggie CLI), TB 2.0 = 67.4%**, Opus 4.7 | Augment blog, 2026-05-15 | Blog only; **not on the TB leaderboard**. Effort unstated. And it is **5 attempts per task** — a best-of-5 policy that cannot be laid beside any pass@1 row. Same post's SWE-bench Pro 61.8% is 3 attempts, benchmark version unstated. |
| **Kilo Code's own leaderboard**, 34 entries incl. GLM 5.2 53.0% | `kilo.ai/kilobench` | Vendor-run through its own harness — legitimate in principle, and the only third GLM-5.2 harness datapoint in existence. But: **display model names only, no effort, no trial count, and no date on the page.** Cite as a claim. |
| **GLM-5.2, Terminal-Bench 2.1 = 82.7%, "Best Reported Harness"** | Z.ai, HF README | **No harness named.** The same table shows Opus 4.8 *dropping* 85.0 → 78.9 between the Terminus-2 row and this one, so the column is a mixed-harness cherry-pick, not a measurement. |
| GLM-5.2, TB 2.1 (Terminus-2) = 81.0% | Z.ai, HF README + `zai-org/GLM-5` | Vendor self-report; **not on the official board**, which has no GLM-5.2 row at all. No trial count. The GitHub prose says GLM-5.1 = 62.0 where the HF table says 63.5 — the vendor disagrees with itself. Cite as a claim. |
| GLM-5.2 SWE-bench Verified, any figure | in circulation | **Unsourced.** Z.ai never published one — SWE-bench Verified is absent from their entire document. OpenHands' run request `openhands-index-results#1224` is still open with zero results. |
| Grok 4.5 SWE-bench Pro 64.7%; Grok 4.5 TB 2.1 83.3% | xAI blog | **xAI publishes no model card at all.** Harness undisclosed, effort undisclosed, trial count undisclosed. And the TB 2.1 83.3% would place 1st on a board it does not appear on. |
| Grok 4.6 TB "v3.0" 26% vs Grok 4.5 15.7% | xAI blog | The **benchmark version silently changed** between the two posts — Grok 4.5 reads 83.3% (TB 2.1) in one and 15.7% (TB 3.0) in the other. Non-comparable, and the competitor columns are "best of self-reported or publicly available", i.e. cross-harness cherry-picks. |
| GPT-5.6 Sol Terminal-Bench 2.1 **88.8%** (91.9% "Ultra") | OpenAI blog | **No harness named anywhere on the page.** Not in any system card. "Ultra" runs **four agents in parallel** — a test-time-compute policy, not a single-attempt score, and not comparable to any pass@1 row. |
| GPT-5.3-Codex TB 2.0 77.3% | OpenAI blog | Harness undisclosed **by OpenAI**. Quotable only because *Google* independently attributes it to Codex CLI at xhigh. Cite Google, not OpenAI. |
| GPT-5.5 TB 2.0 82.7% | OpenAI blog | Harness undisclosed, effort undisclosed, no trials, no denominator. |
| Cursor's CursorBench 3.x | Cursor | Private task corpus, private LLM graders, evaluated inside Cursor's own harness. **Unreproducible in principle.** |
| Amp's 102-task internal eval | Sourcegraph | Unnamed benchmark, no public task set. |
| Devin 13.86% SWE-bench (2024) | Cognition | 79 of 570 instances, Devin unassisted vs assisted baselines. Cognition themselves: *"we stopped reporting SWE-Bench numbers in 2024."* |
| Any Verified-board row reading `Undisclosed` or `Multiple` | 46 of 180 rows | **Model not stated.** Includes Refact.ai, Augment, Factory Droid, Blackbox, Amazon Q, Gru, Emergent, Zencoder, Solver, Honeycomb, Isoform, Bytedance MarsCode. |
| SWE-bench Pro starred vs unstarred rows compared to each other | Scale | The asterisk changes **harness and turn budget together** (mini-swe-agent/50 vs SWE-agent/250). Two variables, one flag. |
| Harbor-Index "82 tasks" | harbor-index.org | The Hub download lands **80**, and upstream's own README says 80. The site figure is stale; released tags run 1.1–1.4. |
| Our own "5–6 of 8" and "4/6" as absolute performance | us | Non-standard denominators shared with nothing published; n=6 gives ±35 pp. Internally valid only. |

---

## 10. Corrections to our own prior documents

Everything here is a primary source overruling something we wrote.

| Prior claim | Where | Correction |
|---|---|---|
| **"Gemini 3 Pro scores 0.0% on 500 instances at $0.96 each"**, used to argue leaderboards carry unannotated infrastructure failures | `benchmark-models.md` §1 | **No 0.0% row exists on any SWE-bench board.** Gemini 3 Pro is 74.2% (Preview) and **69.6%** (2026-02-26, high, $0.960). The price was right, the score was invented. **Strike the claim and the paragraph built on it.** |
| The Codex CLI 1,000-turn / 100K-compaction / `resume --last` config is "the best-disclosed configuration anywhere", implicitly behind OpenAI's coding numbers | `what-harnesses-benchmark.md` §4 | The string is **verbatim correct** but its scope is **Irregular's cyber-range evaluation**, not SWE-bench and not Terminal-Bench. OpenAI's system cards contain **zero** coding-benchmark scores. Do not attach it to a coding number. |
| SWE-bench has six boards, the sixth being "full" | both docs | The six are `bash-only` (47), `Multilingual` (13), **`Test` (24, n=2294)**, `Verified` (180), `Lite` (84), `Multimodal` (22). |
| The academic-only submission policy covers "the Verified and Multilingual boards" | `what-harnesses-benchmark.md` §2 | Correct as far as it goes — but **Lite is not named and Multimodal is explicitly still open** to anyone. |
| Anthropic Fig 2.5.A is in §2.4/§2.5 | `benchmark-models.md` §5 | **§2.5 only.** §2.4 is SWE-bench and contains no Terminal-Bench content. |
| Anthropic's headline comparison is harness-matched | implied throughout | **It is not.** Table 2.3.A carries GPT-5.2's own-harness 64.7%; only Fig 2.5.A carries the matched 57.5%. |
| "Terminal-Bench 3 top score 43.5% (Claude Opus 5)" | `what-harnesses-benchmark.md` §3.5 | **42.70%, `mini-SWE-agent` + Opus 5, max effort, 370 trials.** Already corrected in `benchmark-models.md`; restated here because the board is now also named **Terminal-Bench 3.0**, not Frontier-Bench, and Anthropic's own card calls it **FrontierBench v0.1**. Three names, one task set. |
| Harbor-Index is 82 tasks | `what-harnesses-benchmark.md` §3.1 | **80 on disk and in upstream's README**; 82 is the site's stale figure. Also **16 of the 80 need an Anthropic key to grade at all** (`hle-*`, `omnimath-*`, `gaia2-*`, `widesearch-*`, judged by `claude-opus-5` voting 3×), so the gradeable denominator here is **64**. |
| Terminal-Bench 2.1 "fixed 28 tasks" | `what-harnesses-benchmark.md` §0 | Upstream says **26**; a byte comparison finds **27** (`datasets.DIFF_TB20_TB21`). Not 28. |
| "Everything we want to run is one `--dataset` flag away" | `what-harnesses-benchmark.md` §3.6 | TB 2.1, TB 3 and Harbor-Index are **not in the legacy registry** the installed Harbor's `dataset list` reads. They resolve only through the Hub (`harbor download org/name`). |
| GLM-5.3 exists, so 5.2 is superseded | `benchmark-models.md` §7.1 | **GLM-5.3 does not exist.** `huggingface.co/zai-org/GLM-5.3` → 401, `z.ai/blog/glm-5.3` empty, the `zai-org/GLM-5` README stops at 5.2. **GLM-5.2 is Z.ai's current model.** |
| goose's `$0.48/task` row is Claude Code | already corrected in `benchmark-models.md` §6 | Restated: it is **harbor's vanilla `Goose` harness**. There is no Claude Code row in that table. |
| cline "reports GLM-5.2 (open-weights post), **Kimi K3 (2.1 post)**" | `benchmark-models.md` §6 | The Kimi K3 / TB 2.1 88.8% figure is a **blog post only**. `cline/benchmark-results` contains exactly one dataset, has not been touched since 2026-06-26, and has no TB 2.1 run and no Kimi K3 run in it. Quarantined in §9. |
| goose's table is a clean model-pinned harness comparison | `what-harnesses-benchmark.md` §5, `benchmark-models.md` §7.2 | It is model-pinned and **effort-scrambled**: `thinking: "off"` for pi, `GOOSE_THINKING_EFFORT: "off"` for every goose row, provider default for opencode. The cost *structure* finding survives; the pass-rate ordering across projects does not. |
| pi scores 47.2% (goose) and 57.3% (cline) — treat as two measurements | implied | **One number is pi with reasoning off and the other is pi at medium.** They are not two measurements of the same thing. |
| Our oracle control loses "6 of 89" tasks | working assumption | **7 of 89.** `controls.json` records oracle **82/89 = 92.1%**: `build-cython-ext`, `build-pmars`, `caffe-cifar-10`, `make-doom-for-mips`, `mcmc-sampling-stan`, `protein-assembly`, `rstan-to-pystan`. On **TB 2.1 the same control is 86/88 = 97.7%.** |

### 10.1 One thing the prior docs got right and should keep saying

`what-harnesses-benchmark.md` §0.1 says Terminal-Bench is the harness field's
real leaderboard because its submission key is `<agent>__<model>`. **This
research confirms it and strengthens it.** The TB 2.0 board alone contains more
same-model harness comparisons than every other public source combined, and the
three cleanest harness deltas ever published (Google's +12.6, Harbor-Index's
nine pairs, Anthropic's +7.2) are all on Terminal-Bench task sets.

---

## Sources

Retrieved 2026-08-15. Machine-readable payloads preferred throughout; where a
figure exists only in a rendered chart or a vendor table, it is marked
unquotable in the body and quarantined in §9.

**Leaderboards**
- Terminal-Bench 2.0, 2.1, 1.0 — `tbench.ai/leaderboard/terminal-bench/{2.0,2.1,1.0}`, Next.js RSC flight payload. There is **no public REST API**: `tbench.ai/api/leaderboard/terminal-bench/2.0` → 404
- Terminal-Bench 3.0 (formerly Frontier-Bench) — `frontierbench.ai`, RSC payload. `tbench.ai/leaderboard/terminal-bench/3` → 404
- TB 2.1 submissions — pull requests at `github.com/harbor-framework/terminal-bench-2-1`
- Harbor-Index 1.0 — data array in `harbor-index.org/_next/static/chunks/94933e4a60a22aaa.js`. The rendered page is a client-side scatter; the Hub dataset page's Leaderboard tab serves empty
- SWE-bench, all six boards — `raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json`
- SWE-bench submission policy — `raw.githubusercontent.com/SWE-bench/experiments/main/README.md`
- SWE-bench Pro — `labs.scale.com/leaderboard/swe_bench_pro_{public,private}`; scaffold per `github.com/scaleapi/SWE-bench_Pro-os`
- `github.com/laude-institute/terminal-bench` has **no** leaderboard/results/submissions directory

**Vendor primary sources**
- Anthropic Claude Opus 4.6 system card — `www-cdn.anthropic.com/0dd865075ad3132672ee0ab40b05a53f14cf5288.pdf` (§2.4, §2.5, Fig 2.5.A, Table 2.3.A)
- Anthropic Claude Opus 5 system card — `www-cdn.anthropic.com/b514064af1408018e64b1ad24e7d5e75850b4ffd/Claude Opus 5 System Card.pdf` (§8.1, §8.2, §8.5). Not yet listed on `/transparency`; `anthropic.com/transparency/model-reports` returns HTTP 500
- OpenAI GPT-5.3-Codex system card — `deploymentsafety.openai.com/gpt-5-3-codex/gpt-5-3-codex.pdf`. Zero occurrences of "SWE-bench" or "Terminal-Bench"
- OpenAI GPT-5.6 — `openai.com/index/gpt-5-6/` (blog); variants Sol / Terra / Luna, `ultra` = 4 parallel agents
- Google Gemini 3.1 Pro — `deepmind.google/models/gemini/pro/` and the methodology PDF at `deepmind.google/models/evals-methodology/gemini-3-1-pro/`
- xAI — `x.ai/news/grok-4-5`, `x.ai/news/grok-4-6`. **No model card exists**; no card repo in the xai-org GitHub org
- Z.ai GLM-5.2 — `huggingface.co/zai-org/GLM-5.2`, `github.com/zai-org/GLM-5`. GLM-5.3 does not exist

**Harness projects**
- goose Harbor evals — `raw.githubusercontent.com/block/goose/main/evals/harbor/README.md`
- cline benchmark results — `github.com/cline/benchmark-results`

**Our own artefacts**
- `bench/headtohead/runs/h2h-1/{config.json,report.md}`
- `bench/terminalbench/runs/osa-tb20-full89-f6981b61/config.json`
- `bench/terminalbench/runs/_controls/{tb2.0,tb2.1,tb3,harbor-index}/controls.json`
- `bench/terminalbench/datasets.py`, `bench/terminalbench/README.md`
- commits `337e2405` (reasoning-disabled retraction), `b820ca82` + `ab67bf70` (the 1800 s driver deadline)
