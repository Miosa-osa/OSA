# Which model is behind each published benchmark number

Companion to `what-harnesses-benchmark.md`, which establishes *which* benchmarks
the harness field publishes on. This document answers the next question: **for
every number we have been quoting, which exact model produced it** — and whether
our own numbers, all run on `ollama/glm-5.2:cloud`, are comparable to any of them.

Evidence rule: leaderboard payloads, repository data files, and system-card PDFs
beat blog posts. Where a figure exists only in a rendered chart or a vendor
table, it is marked **unquotable** and not used to support a conclusion.

Retrieved 2026-08-15. Leaderboards move; every row carries its date.

---

## 0. The answer, before the detail

1. **No published number we have been quoting was produced on GLM-5.2, and only
   one published number anywhere was.** Every headline figure in our comparison
   set — SWE-bench Verified 76.8%, Terminal-Bench 2.1's board, Terminal-Bench 3's
   42.7%, Harbor-Index 28.1%, goose's $0.48/task — runs on Claude Opus/Sonnet-class,
   GPT-5-class, or Fable-class models. The sole exception is the Terminal-Bench 3
   board, which carries exactly one GLM-5.2 row, and it is last.

2. **GLM-5.2 is two different models depending on task difficulty, and this is
   the finding that matters.** On Terminal-Bench 2 (the 89-task set we run) it is
   competitive with Sonnet-class: cline measured **68.5%** with it. On
   Terminal-Bench 3 (74 harder tasks) under the *identical* Claude Code harness it
   scores **4.59%**, against Sonnet 5's 14.59% and Opus 4.8's 21.08%. On
   Harbor-Index it is below every frontier pair. It does not degrade gracefully —
   it falls off a cliff.

3. **Therefore we have *not* been tuning against an invisible ceiling — on the
   benchmark we actually run.** cline's published data shows GLM-5.2 moving
   **11.2 points** across three real harnesses (cline 68.5%, opencode 59.6%, pi
   57.3%) on the same 89 tasks. That is a live harness signal, larger than the
   harness spread Anthropic measured on GPT-5.2-Codex (7.2 pp). Harness changes on
   Terminal-Bench 2 with GLM-5.2 are measurable, not noise.

4. **But our absolute numbers are comparable to nothing published.** Our probe
   sets (8 tasks, 6 tasks) share no denominator with anything. Even a completed
   full-89 run would be comparable only to cline's GLM-5.2 rows, and only after
   matching their `--timeout-multiplier 2.0`. It would not be comparable to any
   leaderboard: those are Terminal-Bench 2.1/3, multi-trial with error bars, on
   frontier models.

5. **The prior document mislabels the row it built its cost finding on.** The
   `$0.48/task, ~100% cache-hit` row in `what-harnesses-benchmark.md` §5 is
   labelled "Claude Code". goose's README says it is **harbor's vanilla `Goose`
   harness, curl-installed**. There is no Claude Code row in that table. The
   structural finding survives; the attribution does not. See §6.

6. **Anthropic's Figure 2.5.A is Terminal-Bench 2.0, not 2.1 or "Terminal-Bench"
   generically.** Verified from the PDF. The 7.2 pp GPT-5.2-Codex harness delta is
   real and correctly quoted; the task set was not.

---

## 1. The master table: model behind each published figure

| Figure we quote | Exact model + version | Harness | Task set / denominator | Trials | Date | Variable being compared |
|---|---|---|---|---|---|---|
| **SWE-bench Verified 76.8%** (Bash Only) | **Claude 4.5 Opus (high)**, Anthropic, `20251124` | mini-SWE-agent **v2.0.0** | SWE-bench Verified, **500** instances | 1 (pass@1) | 2026-02-17 | **Model** — scaffold pinned by design |
| SWE-bench Verified, main board top | Claude 4.5 Opus (medium), `20251101` | live-SWE-agent | Verified, 500 | not stated | 2025-12-15 | **Pair** |
| SWE-bench Verified, main board tied top | Claude 4.5 Opus | Sonar Foundation Agent | Verified, 500 | not stated | 2025-12-05 | **Pair** |
| **Terminal-Bench 2.1 top, 83.82%** | **Fable 5** (Anthropic), effort `xhigh` | **Claude Code** | TB 2.1 | multi, ±1.2% | Jun 7 2026 | **Pair** (board is keyed `agent × model`) |
| **Terminal-Bench 3 top, 42.7%** | **Opus 5** (Anthropic), effort `max` | **mini-SWE-agent** | TB 3.0, 74 tasks | not stated | Jul 24 2026 | **Pair** |
| **Harbor-Index top, 28.1%** | **GPT-5.5** (OpenAI) | **Codex CLI** | Harbor-Index 1.0, **82** tasks | 1,476 rollouts total | Jul 2026 | **Pair** |
| Harbor-Index #2, 20.7% | Claude Opus 4.8 | Claude Code | same | same | same | **Pair** |
| **goose Harbor table, $0.48/task** | **`claude-sonnet-4-6`** — pinned on 9 of 10 rows | **harbor vanilla `Goose`** (NOT Claude Code) | `terminal-bench/terminal-bench-2`, **89** | `n_attempts: 1` | **undated** | **Harness** (model pinned) |
| **cline TB numbers** | `openrouter:z-ai/glm-5.2`, `minimax/minimax-m3`, `xiaomi/mimo-v2.5-pro`, `moonshotai/kimi-k2.7-code` | cline CLI 3.0.29, opencode 1.17.9, pi 0.73.1 | **TB 2.0**, 89, pass@1 | 1 per task | **Jun 24–25 2026** | **Harness** (model pinned) — open-weights only |
| **Opus 4.6 SC Fig 2.5.A** | **GPT-5.2-Codex** | Terminus-2 **57.5%** vs Codex CLI **64.7%** | **Terminal-Bench 2.0**, 89 | **890 trials** | Feb 2026 | **Harness** — cleanest published |
| Opus 4.6 SC §2.5 headline | Claude Opus 4.6, adaptive thinking, max effort | Terminus-2 in Harbor | TB **2.0**, 89 | **1,335** (89 × 15) | Feb 2026 | Model |
| Opus 4.6 SC §2.4 headline | Claude Opus 4.6, adaptive thinking, max effort | not named | SWE-bench Verified, 500 | **25-trial average** | Feb 2026 | Model |

### Notes that change how these can be used

**SWE-bench Verified 76.8% is `mini-SWE-agent v2.0.0 + Claude 4.5 Opus (high)`,
2026-02-17, and the leaderboard payload gives its economics too:** $0.754 per
instance, $376.95 total, **32.9 API calls per instance**. That last number is the
one to hold against our own turn counts — a 190-line bash loop resolves 76.8% of
SWE-bench Verified in ~33 model calls per task.

**The Bash Only board is the field's cleanest model ladder**, because the
scaffold is fixed. Selected rows, all `mini-SWE-agent`, all 500 instances:

| Model | Score | $/instance | Date | Open weights |
|---|---:|---:|---|---|
| Claude 4.5 Opus (high) | **76.8%** | $0.754 | 2026-02-17 | no |
| MiniMax M2.5 (high) | 75.8% | $0.073 | 2026-02-17 | **yes** |
| Gemini 3 Flash (high) | 75.8% | $0.356 | 2026-02-17 | no |
| Claude 4.6 Opus | 75.6% | $0.552 | 2026-02-17 | no |
| GPT 5.2 Codex | 72.8% | $0.449 | 2026-02-19 | no |
| **GLM 5 (high)** | **72.8%** | $0.534 | 2026-02-17 | **yes** |
| Claude 4.5 Sonnet (high) | 71.4% | $0.658 | 2026-02-17 | no |
| Kimi K2.5 (high) | 70.8% | $0.147 | 2026-02-17 | **yes** |
| GLM 4.6 (T=1) | 55.4% | $0.097 | 2025-12-01 | **yes** |
| GLM 4.5 | 54.2% | $0.297 | 2025-08-22 | **yes** |
| gpt-oss-120b | 26.0% | $0.057 | 2025-08-07 | **yes** |
| Gemini 3 Pro | **0.0%** | $0.960 | 2026-02-26 | no |

Two things to take from this. **GLM 5 is 4.0 points behind Claude 4.5 Opus on
SWE-bench Verified under a fixed scaffold** — the GLM line is not far off frontier
on single-repo patch work. And **`Gemini 3 Pro` scores 0.0% on 500 instances at
$0.96 each**, which is an infrastructure failure sitting unannotated on a public
leaderboard. Treat leaderboard rows as data with a defect rate, not as truth.

**There is no GLM-5.2 row on any SWE-bench board.** Z.ai never published a
SWE-bench Verified number for it (they report SWE-bench *Pro* 62.1% instead), and
OpenHands' request to run it (`OpenHands/openhands-index-results#1224`, opened
2026-06-19) is still open with zero results. **Any "GLM-5.2 SWE-bench Verified"
figure in circulation is unsourced.**

---

## 2. Terminal-Bench 2.1 — the full board, and what it says about GLM

All 17 entries, extracted from the leaderboard payload at
`tbench.ai/leaderboard/terminal-bench/2.1`:

| Agent | Model | Effort | Accuracy |
|---|---|---|---:|
| Claude Code | Fable 5 | xhigh | **83.82%** |
| Codex | GPT-5.5 | xhigh | 83.15% |
| Terminus 2 | Fable 5 | high | 80.45% |
| Cursor CLI | Grok 4.5 | high | 79.33% |
| Claude Code | Opus 4.8 | high | 78.88% |
| Codex | GPT-5.6 Terra | max | 78.43% |
| Terminus 2 | GPT-5.5 | xhigh | 77.98% |
| mini-SWE-agent | Muse Spark 1.1 | xhigh | 76.18% |
| Codex | GPT-5.6 Luna | max | 75.73% |
| Claude Code | Sonnet 5 | high | 74.61% |
| Terminus 2 | Gemini 3 Pro | high | 73.93% |
| Claude Code | Opus 4.7 | max | 68.90% |
| Terminus 2 | Opus 4.7 | max | 66.07% |
| Gemini CLI | Gemini 3 Pro | high | 65.84% |
| Gemini CLI | Gemini 3.1 Pro | high | 65.84% |
| Terminus 2 | Gemini 3.1 Pro | high | 65.62% |
| **Claude Code** | **GLM-5.1** | max | **58.65%** |

**Same harness, model-only reads:** Claude Code carries Fable 5 to 83.82%,
Opus 4.8 to 78.88%, Sonnet 5 to 74.61%, Opus 4.7 to 68.90% and **GLM-5.1 to
58.65%**. GLM-5.1 is **16.0 points below Sonnet 5** and 25.2 below Fable 5 under
an identical scaffold at the same effort tier.

**Harness-only reads:** Fable 5 gains 3.4 pp moving from Terminus 2 to Claude
Code; Opus 4.7 gains 2.8 pp; GPT-5.5 gains 5.2 pp moving from Terminus 2 to
Codex; Gemini 3 Pro *loses* 8.1 pp moving from Terminus 2 to Gemini CLI. Harness
deltas here run 3–8 pp. Model deltas run 16–25 pp. **On this board the model is
roughly 3× the lever the harness is.**

**GLM-5.2 is not on this board.** Z.ai's own README claims **81.0** on TB 2.1
via Terminus-2, and a second row of **82.7** under an unnamed "Best Reported
Harness". Both are vendor self-report; neither appears on the official
leaderboard; the unnamed-harness row is **unquotable** on its face. Note also
that the vendor's own two rows disagree about whether GLM-5.2 beats Opus 4.8 —
which is itself a demonstration of scaffold selection effects.

---

## 3. Terminal-Bench 3 — where GLM-5.2 actually appears, and collapses

The TB3 board lives at `frontierbench.ai`, not `tbench.ai`
(`tbench.ai/leaderboard/terminal-bench/3` is a 404; `.../terminal-bench-3/1.0`
reports "under construction, 0 entries"). Complete board, all 10 entries,
extracted from the page payload:

| Agent | Model | Effort | Model released | Resolution rate | Run cost |
|---|---|---|---|---:|---:|
| **mini-SWE-agent** | **Opus 5** | max | Jul 24 2026 | **42.70%** | $5.8k |
| Codex | GPT-5.6 Sol | max | Jul 9 2026 | 34.59% | $4.0k |
| Claude Code | Fable 5 | max | Jun 9 2026 | 34.05% | $6.5k |
| Grok Build | Grok 4.6 | high | Aug 12 2026 | 26.49% | $2.1k |
| Claude Code | Opus 4.8 | max | May 28 2026 | 21.08% | $5.2k |
| Codex | GPT-5.6 Terra | max | Jul 9 2026 | 20.81% | $2.5k |
| Cursor CLI | Grok 4.5 | xhigh | Jul 8 2026 | 15.68% | $766 |
| Claude Code | Sonnet 5 | max | Jun 30 2026 | 14.59% | $6.9k |
| Codex | GPT-5.6 Luna | max | Jul 9 2026 | 14.32% | $1.6k |
| **Claude Code** | **GLM 5.2** | max | Jun 13 2026 | **4.59%** | $3.4k |

This is the single most important table in this document.

- **Correction: the top score is 42.70% by `mini-SWE-agent + Opus 5`, not
  "43.5% (Claude Opus 5)".** The prior doc's figure is either stale or was read
  off a different rendering. Quote 42.70%, with the agent named.
- **The best score on the hardest board belongs to a 190-line bash loop.**
  mini-SWE-agent + Opus 5 beats Claude Code + Fable 5 by 8.7 pp and Codex +
  GPT-5.6 Sol by 8.1 pp. On frontier-difficulty work, elaborate scaffolding is
  not buying what its authors hope.
- **Claude Code + GLM 5.2 = 4.59%.** Under the same harness, at the same `max`
  effort: Sonnet 5 = 14.59% (3.2×), Opus 4.8 = 21.08% (4.6×), Fable 5 = 34.05%
  (7.4×). This is a clean, same-harness, published model comparison including
  our exact model family and version.
- **And it cost $3.4k to score 4.59%.** GLM-5.2 being cheap per token did not
  make the run cheap; failure is expensive.

---

## 4. Harbor-Index — GLM-5.2 tested, score not extractable

Harbor-Index 1.0: **82 tasks** distilled from 6,627 candidates across 54
benchmarks; **1,476 rollouts**; published mid-2026 (the hub page dates the
dataset 2026-06-29, the write-up 2026-07-07).

Verbatim from the source: *"GPT-5.5 on the Codex CLI leads at 28.1%, followed by
Claude Opus 4.8 with Claude Code at 20.7%"*, and *"No agent-model pair we tested
gets above 30% on Harbor-Index."*

**GLM 5.2 is one of the nine models evaluated, paired with Claude Code**, but its
score is rendered only inside an interactive chart and is **not extractable as
text. Do not quote a numeric Harbor-Index score for GLM-5.2.** What is quotable
is the surrounding prose, which is directly on point:

- *"The open-weight models time out three to four times as often (30 to 43%)"*
- *"An Invalid-JSON rejection hits 7.3% of open-model terminus rollouts."*
- *"Running open models through Claude Code on OpenRouter produces a low
  cache-hit rate, which inflates their cost."*

Those three sentences describe our exact operating regime: an open-weight model,
long-horizon tasks, timeouts, malformed tool calls, and no prompt cache.

---

## 5. Anthropic Opus 4.6 system card, Figure 2.5.A — verified from the PDF

Quoted from §2.5 and the Figure 2.5.A caption:

> We ran Terminal-Bench 2.0 in the Harbor scaffold using the Terminus-2 harness
> with the default parser. […] Claude Opus 4.6 achieved an average 65.4% pass
> rate using adaptive thinking at max effort. We ran all 89 tasks 15 times each
> (1,335 trials), spread across 3 batches at different times to reduce temporal
> variance.

> [Figure 2.5.A] […] At low effort, Opus 4.6 scores 55.1%, generating 40% fewer
> output tokens. At medium effort, it scores 61.1%, generating 23% fewer output
> tokens. **For GPT-5.2-Codex, we reproduced 57.5% on Terminus-2 and 64.7% on
> OpenAI's Codex CLI harness (890 trials).** We reproduced 56.2% for Gemini 3
> Pro, and 50.3% for Gemini 3 Flash, using the Terminus-2 harness (445 trials).

Establishing:

- The task set is **Terminal-Bench 2.0, 89 tasks** — the same set we run, and the
  same set goose and cline run. Not 2.1.
- The **7.2 pp GPT-5.2-Codex harness delta is confirmed** and correctly quoted in
  the prior doc; only the task-set label was wrong.
- A **third variable the prior doc omits: reasoning effort moves the same model
  under the same harness by 10.3 pp** (Opus 4.6: 55.1% low → 61.1% medium →
  65.4% max). Effort is a bigger lever than the harness delta Anthropic measured.
  Any cross-run comparison that does not pin effort is not a comparison. Note
  that cline measured the same thing on GLM-5.2: reasoning off costs it 11.2 pp.
- SWE-bench Verified 80.84% is a **25-trial average**, rising to 81.4% with a
  disclosed prompt modification. It is not pass@1 and cannot be set beside one.

---

## 6. Corrections to `what-harnesses-benchmark.md`

| Prior claim | Correction | Evidence |
|---|---|---|
| goose's table has a **"Claude Code"** row at $0.48/task, ~100% cache | **There is no Claude Code row.** Job `claude-sonnet46-full` is *"harbor's vanilla `Goose` harness (curl-installed) — useful sanity check that our `GooseBinaryAgent` adapter isn't leaving points on the floor."* | goose `evals/harbor/README.md` L39–41 |
| goose runs at **"3k turns; `--max-turns` flag"** | 3k is the **observed total turns across all 89 trials** (~34/task). The **default cap is 100 turns**. | same README, "Defaults" block L103–109 |
| Anthropic Fig 2.5.A is on Terminal-Bench (unqualified) | Specifically **Terminal-Bench 2.0** | Opus 4.6 SC §2.5 |
| TB3 top score **"43.5% (Claude Opus 5)"** | **42.70%, `mini-SWE-agent` + Opus 5, max effort** | frontierbench.ai board payload, 2026-08-15 |
| Harbor-Index "top score 28.1% (GPT-5.5); Claude Opus 4.8 + Claude Code 20.7%" | **Correct.** Add: the 28.1% is on **Codex CLI**, and it is a pair, not a model result | harbor-index.org |
| cline reports "GLM-5.2 (open-weights post), Kimi K3 (2.1 post)" | Sharpen: cline's published dataset is **`terminal-bench/2026-06-open-weights`, TB 2.0, 89 tasks, pass@1, OpenRouter routes, Modal, `--timeout-multiplier 2.0`, n=20, 2026-06-24/25**, cline CLI 3.0.29 / opencode 1.17.9 / pi 0.73.1. **It contains no Claude or GPT arm** — the Claude/GPT figures in cline's blog are quoted from elsewhere, not measured | cline/benchmark-results README + run-configs.md |

**What survives unchanged:** the cost structure. Recomputing the effective input
rate as `(cost − out×$15/M) ÷ in` on the corrected labels still gives harbor's
installed agents $0.24–0.42/M and every `GooseBinaryAgent` row $2.99–3.01/M. The
split is real; it runs between *harbor-installed* harnesses and goose's own
binary-upload adapter, not between "Claude Code" and goose. OSA sits on the
$3.00 side.

---

## 7. Is GLM-5.2 competitive? The two-regime answer

### 7.1 What GLM-5.2 is

`z-ai/glm-5.2`, released **2026-06-16**, MIT-licensed open weights, ~750B total /
40B active MoE, 1M context (ollama advertises 976K for `glm-5.2:cloud`),
$1.40/$4.40 per M in/out with an 83% cache discount. A **GLM-5.3** already exists,
so 5.2 is no longer Z.ai's newest coding model.

### 7.2 Regime A — Terminal-Bench 2 difficulty: competitive

cline's published dataset, TB 2.0, 89 tasks, `openrouter:z-ai/glm-5.2`:

| Harness | Reasoning | GLM-5.2 |
|---|---|---:|
| cline CLI 3.0.29 | medium | **68.5%** (61/89) |
| opencode 1.17.9 | medium | 59.6% (53/89) |
| pi 0.73.1 | medium | 57.3% (51/89) |
| cline CLI 3.0.29 | **off** | 57.3% (51/89) |

Against goose's `claude-sonnet-4-6` rows on the *same 89-task dataset*: goose
codemode 57.3%, harbor-vanilla goose 55.1%, opencode 52.8%, stock goose 50.6%,
pi 47.2%.

**Read this carefully.** It is tempting to conclude GLM-5.2 beats Sonnet 4.6 —
opencode 59.6% vs 52.8%, pi 57.3% vs 47.2%, same harness family, same task set.
**Do not draw that conclusion.** cline ran with `--timeout-multiplier 2.0`; goose
ran at default, and goose's runs lost **16–21 of 89 tasks to timeout** on every
row. Doubling the timeout plausibly recovers most of that gap on its own. The
defensible statement is weaker and sufficient: **on Terminal-Bench 2, GLM-5.2
lands in the same 55–70% band the field's harnesses reach with Sonnet-class
models. It is not the binding constraint at this difficulty.**

### 7.3 Regime B — frontier difficulty: not competitive

| Benchmark | Harness | GLM-5.2 | Sonnet-class | Opus-class | Best |
|---|---|---:|---:|---:|---:|
| Terminal-Bench 3 (74 tasks) | Claude Code (pinned) | **4.59%** | 14.59% (Sonnet 5) | 21.08% (Opus 4.8) | 42.70% |
| Harbor-Index (82 tasks) | Claude Code | below 20.7%, exact figure unquotable | — | 20.7% (Opus 4.8) | 28.1% |
| Terminal-Bench 2.1 | Claude Code | absent (GLM-**5.1** = 58.65%) | 74.61% | 78.88% | 83.82% |

At frontier difficulty, under a pinned harness, GLM-5.2 does not merely trail —
it is 3–7× behind. Harbor-Index's prose supplies the mechanism: open-weight
models **time out on 30–43% of tasks**, and **7.3% of open-model rollouts hit an
Invalid-JSON rejection**. These are long-horizon durability failures and
tool-call serialisation failures, not reasoning failures.

### 7.4 The tool-use reliability problem is documented and specific

Independent bug reports across at least seven unrelated codebases describe
GLM-5.2-specific tool-calling defects, clustered exactly in the regime an agent
harness operates in — streamed tool-call assembly, many tools, deep multi-turn
history:

- Template tokens leaking into `function.name` (e.g. `"tool_12</arg_value>"`),
  measured at ~1 in 2,000 emissions, triggered by long histories and
  parallel tool calls — `fw-ai-external/python-sdk#119`
- Streamed argument corruption producing *valid* JSON with wrong values
  (`"worker.js"` → `"worker.jsrker.js"`) — silent, unrecoverable — `team-telnyx/ai#248`
- Tool calls left unparsed and written into `content` under `tool_choice:
  required` — `vllm-project/vllm#48095`
- Streamed tool-call deltas missing entirely; `pi` had to force non-streaming
  whenever tools are present, **for this model only** — `earendil-works/pi#6357`
- Empty `content` on every tool-call turn, causing opencode to inject a sanitiser
  placeholder that then **pollutes history** — `anomalyco/opencode#33280`
- Non-retryable 400 at step 18 of a session with 1.29M cache-read tokens —
  a long-horizon failure — `Kilo-Org/kilocode#13069`

Some fraction of OSA's losses on GLM-5.2 are attributable to this layer, not to
our scaffold. Our per-loss layer attribution should be reading these out; if it
is not distinguishing "malformed tool call from the provider" from "agent chose
wrong", it is mis-attributing model-serving defects to the harness.

### 7.5 One caveat on our own serving path

Every published GLM-5.2 number above went through **OpenRouter** (`z-ai/glm-5.2`)
or Z.ai direct. We run **`ollama/glm-5.2:cloud`**. Quantisation, tool-call
template, effort default and context limit (976K advertised vs 1M) may all
differ. **cline's 68.5% is not a number we are entitled to expect from our
serving path**, and the difference is measurable if we care to measure it.

---

## 8. Are our absolute numbers comparable to anything published?

**No. Not to any leaderboard, and not yet to cline.**

| Our number | Comparable to? | Why not |
|---|---|---|
| 5–6 of 8 on a Terminal-Bench probe set | **nothing** | Non-standard 8-task subset. No published figure shares that denominator. Task selection is unstated and almost certainly not difficulty-balanced. |
| 4/6 vs codex 6/6 vs mini-swe-agent 6/6 | **only itself** | Internally valid — model pinned across arms — but n=6 gives a 95% CI of roughly ±35 pp. It cannot distinguish a real harness gap from a coin flip. |
| A completed full-89 TB2 run | **cline's GLM-5.2 rows only**, and conditionally | Requires matching `--timeout-multiplier 2.0`, pass@1, and reasoning effort. Even then it is a cross-study comparison with different serving paths and 7 weeks of drift. |
| Any TB 2.1 or TB 3 leaderboard row | **no** | Different task set, different model, multi-trial with error bars, and effort tiers we do not pin. |
| SWE-bench Verified 76.8% | **no** | Different model (Claude 4.5 Opus), and the boards have been academic/lab-submission-only since 2025-11-18. |

**What we would have to do to make an absolute claim.** Three things, in order:

1. **Pin and disclose reasoning effort.** Anthropic's own data shows 10.3 pp of
   movement on effort alone; cline's shows 11.2 pp on GLM-5.2. An undisclosed
   effort setting invalidates any cross-run comparison before the harness is
   even considered.
2. **Run the full 89, at `--timeout-multiplier 2.0`, pass@1** — matching cline
   exactly. That yields one legitimate external comparison: our GLM-5.2 number
   against cline's 68.5%, opencode's 59.6% and pi's 57.3%. This is achievable and
   it is the *only* external comparison currently available to us.
3. **Re-run on a frontier model before making any claim addressed to the field.**
   Not because GLM-5.2 hides harness effects at TB2 difficulty — it does not —
   but because (a) every leaderboard we might be measured against is on
   frontier models, (b) at TB3/Harbor-Index difficulty GLM-5.2 genuinely floors
   out at 4.59% and no harness work is visible there, and (c) the prompt-cache
   defect, our single largest known cost problem, **cannot be exercised through
   Ollama at all** and needs a real Anthropic or OpenAI endpoint to validate.

### 8.1 On the "tuning against an invisible ceiling" worry

The honest answer is **partly reassuring and partly not.**

**Reassuring:** at Terminal-Bench 2 difficulty the ceiling is not binding. The
published spread of GLM-5.2 across cline/opencode/pi is 11.2 pp — larger than
Anthropic's measured 7.2 pp harness delta on GPT-5.2-Codex, and larger than the
3–8 pp harness deltas visible on the TB 2.1 board. Harness work on TB2 with
GLM-5.2 shows up. Our 4/6 against codex's 6/6 is a real signal about the harness,
not an artifact of a weak model — it is just badly underpowered at n=6.

**Not reassuring, in three ways:**

1. **On anything harder than TB2, the ceiling is absolute.** At 4.59% on TB3, a
   harness improvement worth 5 pp on a competent model is invisible. Any future
   work on Harbor-Index, TB3, or SWE-bench Pro on GLM-5.2 measures nothing.
2. **The prompt-cache work — our largest identified defect — is untestable on
   this model.** Ollama does not exercise the Anthropic cache path. That entire
   workstream is unverifiable until we move to a real provider endpoint.
3. **Model defects are contaminating harness attribution right now.** Malformed
   `function.name`, corrupted streamed arguments, empty `content` turns and
   missing tool-call deltas are documented for this exact model. Unless our
   per-loss attribution separates them, some share of what we have been recording
   as harness losses is provider-side.

---

## 9. Default models — what each project ships

A default is a product decision: it is what the authors think their harness needs
to work.

| Project | Default model | Source quality |
|---|---|---|
| **goose** (Harbor eval harness) | **`anthropic/claude-sonnet-4-6`** | Repo, explicit `Defaults:` block. Also: dataset `terminal-bench/terminal-bench-2`, extensions `developer,todo`, concurrency 4, **max turns 100**, trials 1 |
| **cline** (benchmark runs) | no default — every run pins an OpenRouter route explicitly | run-configs.md |
| **aider** | no static default; `select_default_model()` resolves at runtime from available keys, with an OpenRouter OAuth fallback | `aider/main.py` |
| **codex / Codex CLI** | not resolvable from the paths checked; Harbor's adapter defaults `model_reasoning_effort` to `high` | prior doc §4 |
| **OSA (ours)** | `ollama/glm-5.2:cloud`, chosen for being free on the local daemon | `bench/terminalbench/runs/osa-full89/.../config.json` |

goose is the only project in the set that ships a pinned frontier default for its
own benchmark harness, and it picked Sonnet-class. Nobody defaults to an
open-weight model.

**One datapoint on what a too-weak model does to a harness table**, from goose's
own results: `nemotron-3-nano-30b-a3b` scored **1.1% (1/89)** on the same 89
tasks where `claude-sonnet-4-6` scored 50–57%, and goose's own commentary reads:
*"the small model gives up or loses tool-call structure earlier, so it doesn't
even reach the 100-turn cap on most trials."* That is the failure mode we were
worried about, documented, in the very table we have been comparing ourselves
against — and GLM-5.2 at TB2 difficulty is clearly not in it.

---

## 10. Numbers to stop quoting

| Number | Status |
|---|---|
| "Terminal-Bench 3 top score 43.5%" | **Wrong.** Current board: 42.70%, mini-SWE-agent + Opus 5 |
| "goose's table shows Claude Code at $0.48/task" | **Mislabelled.** That row is harbor's vanilla Goose harness |
| "GLM-5.2 scores 81.0 on Terminal-Bench 2.1" | **Vendor self-report, not on the official board.** Cite as a claim, never as a measurement |
| "GLM-5.2 scores 82.7 on TB 2.1 (best reported harness)" | **Unquotable** — no harness named |
| Any "GLM-5.2 SWE-bench Verified" figure | **Unsourced.** Z.ai never published one; OpenHands' run request is still open with zero results |
| A numeric Harbor-Index score for GLM-5.2 | **Unquotable** — chart-rendered only. Qualitative statements are fine |
| Our "5–6 of 8" and "4/6" as absolute performance | **Not comparable to anything published.** Internally valid only, and underpowered |

---

## Sources

Retrieved 2026-08-15.

- SWE-bench leaderboard payload — `raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json` (6 boards; Verified n=180, bash-only n=47, with per-instance detail, cost and API-call counts)
- Terminal-Bench 2.1 board — `tbench.ai/leaderboard/terminal-bench/2.1` (17 entries)
- Terminal-Bench 3 board — `frontierbench.ai` (10 entries; `tbench.ai/leaderboard/terminal-bench/3` is 404)
- Harbor-Index — `harbor-index.org`; dataset page `hub.harborframework.com/datasets/harbor-index/harbor-index-1.0`
- goose Harbor evals — `raw.githubusercontent.com/block/goose/main/evals/harbor/README.md`
- cline benchmark results — `github.com/cline/benchmark-results`, `terminal-bench/2026-06-open-weights/{README.md,summary.md,summary.csv,run-configs.md}`
- Claude Opus 4.6 System Card §2.4, §2.5, Fig 2.5.A — `www-cdn.anthropic.com/…/Claude Opus 4.6 System Card.pdf`
- GLM-5.2 — `z.ai/blog/glm-5.2` (2026-06-16), `github.com/zai-org/GLM-5` README benchmark table, `huggingface.co/zai-org/GLM-5.2`, `artificialanalysis.ai/models/glm-5-2`, `ollama.com/library/glm-5.2`
- GLM-5.2 tool-call defects — `fw-ai-external/python-sdk#119`, `team-telnyx/ai#248`, `vllm-project/vllm#48095`, `earendil-works/pi#6357`, `anomalyco/opencode#33280`, `anomalyco/opencode#42325`, `Kilo-Org/kilocode#13069`, `decolua/9router#2077`
- OpenHands GLM-5.2 eval request — `OpenHands/openhands-index-results#1224` (open, zero results)
- OSA run config — `bench/terminalbench/runs/osa-full89/harbor/2026-08-14__16-49-07/config.json`
