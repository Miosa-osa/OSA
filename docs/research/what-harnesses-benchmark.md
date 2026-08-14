# What harnesses actually benchmark themselves on

The question this answers: **which benchmarks do agent *harness* projects publish
themselves on** — not which benchmarks exist for models. If we have been
benchmarking on model benchmarks, this is where that shows up.

Companion documents. `bench/report/METHODOLOGY.md` establishes why published
numbers are not comparable and what a defensible report contains; this document
does not re-derive any of it. `bench/report/NEXT_BENCHMARKS.md` ranks candidate
benchmarks by diagnostic value; this document ranks them by *what our competitors
actually report*, which is a different axis and occasionally disagrees.

Evidence rule applied throughout: **a project's own repository beats its
marketing page.** Where only a marketing page exists, that is stated. Where a
number is a *(model × scaffold)* pair reported as if it were a harness result,
that is stated too.

---

## 0. The five findings, before the detail

1. **The harness field's real leaderboard is Terminal-Bench, run through
   Harbor.** Not SWE-bench. SWE-bench's own maintainers built a filtered
   "Bash Only" view *specifically to remove the harness*, whose tooltip reads
   "Show only runs in the mini-SWE-agent environment, **so scores compare models
   rather than harnesses**." They conceded the main board is scaffold-confounded.
   Terminal-Bench went the other way: its submission key is literally
   `<agent>__<model>`, the agent is installed into the container, and the same
   model appears under a dozen harnesses.

2. **Almost nobody publishes a number about their own harness.** opencode,
   gemini-cli, Amp and the `openai/codex` repo publish *zero* benchmark numbers
   about themselves. Anthropic and OpenAI publish numbers for their **models**
   using internal scaffolds that are explicitly not the shipped CLI. Cursor and
   Cognition publish self-invented benchmarks that are unreproducible in
   principle. The two projects doing genuine harness measurement are **goose**
   and **cline**, and both do it on Terminal-Bench through Harbor.

3. **Our current set is nearly right, and one item is wrong for a reason we did
   not anticipate.** SWE-bench Verified, SWE-bench Pro, Terminal-Bench and
   Recovery-Bench are all defensible. But we run **Terminal-Bench 2.0, and the
   live leaderboards are 2.1 and 3** — 2.1 fixed 28 tasks. Our number is against
   a superseded task set. That is a one-flag fix, not a strategy change.

4. **Four benchmarks we had not heard of are directly on-thesis**, chief among
   them **Harbor-Index** (82 tasks distilled from 6,627 candidates across 54
   benchmarks, explicitly built for cheap cross-*agent* comparison, a few hundred
   dollars a run, unsaturated at 28.1%) and **Harness-Bench** (arXiv 2605.27922 —
   a benchmark whose entire stated purpose is measuring harness effects).

5. **The cost problem is not the model price. It is prompt caching, and the
   evidence is a published table.** goose's own Harbor results file contains a
   model-pinned cross-harness run whose numbers, divided out, show Claude Code,
   opencode and pi paying **$0.24–0.42 per million input tokens** while every
   goose-native config pays **exactly $3.00** — the full uncached rate. goose
   burns *fewer* tokens and pays *five times more*. OSA is on the goose side of
   that line and burns 3–7× the tokens as well. See §5; it is the single most
   actionable thing in this document.

---

## 1. Per-project table: what each project publishes about itself

"Self" = a number about the harness. "Model" = a number about the model, using a
scaffold that is not the shipped product. "Pair" = product + model, inseparable.

| Project | Publishes about itself? | Benchmarks it reports | What it measures | Reproducible config? |
|---|---|---|---|---|
| **opencode** | **No — nothing** | none | — | n/a (has an abandoned private bench) |
| **goose** | **Yes, cleanly** | Terminal-Bench 2 (89) via Harbor | **Harness** — model pinned, competitors installed | Yes: `cmd.py` + per-config YAML |
| **cline** | **Yes** | Terminal-Bench 2.0 & 2.1, diffEditSuccess, cline-bench | **Harness** | Yes: repro cmds + public trace repo |
| **aider** | Yes, but inverted | polyglot (225), edit-format, refactor/laziness, SWE-bench Lite/full | polyglot = **Model** (aider is the fixed scaffold); ablations = **Harness** | Yes — best-in-class Docker + CLI |
| **mini-SWE-agent / SWE-agent** | Yes | SWE-bench Verified / Multilingual / bash-only | **Model** *by design* — it is the field's scaffold control | Yes: `config/benchmarks/*.yaml` |
| **OpenHands** | Yes | SWE-bench Verified (77.6%), Multimodal, +20 adapters | **Pair** — model not held fixed across their own history | Yes, best-documented of anyone |
| **Codex CLI** | **No — zero in repo** | (OpenAI blog reports model numbers) | **Pair** presented as Model | Only in system-card cyber appendix |
| **Claude Code** | Safety only | "Malicious use of Claude Code" 83.2% → **99.6%** with product mitigations | **Harness delta** — the cleanest one published anywhere | No |
| **gemini-cli** | **No** | `evals/` exists but explicitly disclaims benchmark status | CI gates, not results | Runnable, no scores |
| **cursor-cli** | No (Cursor the product: yes) | CursorBench 3.x, Terminal-Bench 2.0 | **Pair** sold as Model | **Not even in principle** |
| **Amp** | Effectively no | unnamed 102-task internal eval, "wrapped Terminal-Bench" | **Pair** | No |
| **Devin / Cognition** | Stopped in 2024 | 13.86% SWE-bench (2024), FrontierCode, 4 others | **Pair** benchmarked against **Model** baselines | No — FrontierCode deliberately closed |
| **Hermes** (NousResearch) | Essentially no | "HermesBench" (private), `evals/readtool` | readtool = **Harness**, textbook ablation | readtool: yes |

### The things worth arguing with

**opencode publishes nothing about itself.** Verified across README, opencode.ai
docs, and an open issue conceding it does not support SWE-bench evaluation. The
only opencode number in circulation is the one **goose** published about it. They
do own `opencode-bench` — commit-replay scored by a three-LLM judge panel — but
their own `benchmark-observations.md` is a post-mortem admitting the judges
disagree and the method is too unstable to publish. They built it, found it
didn't work, and shelved it. **Do not cite its numbers**; do note that a serious
competitor tried LLM-judge grading and abandoned it.

**aider's polyglot is a MODEL leaderboard, and this settles the question we had
about it.** 225 Exercism exercises across six languages; aider is the *fixed
scaffold* and models are the rows. It never installs a competing agent. It is
therefore not a harness benchmark, and `NEXT_BENCHMARKS.md`'s decision to
exclude it stands — with one correction: **Harbor now ships `aider-polyglot` as a
225-task dataset**, so running it against OSA no longer means reimplementing
aider's edit loop. It is one flag. It is still a model benchmark; it is now a
*cheap* one.

Aider's genuinely original contribution is the opposite of the leaderboard: the
**refactoring / "laziness" benchmark** — 89 real Python methods, AST-graded,
passing only if the extracted top-level function's node count lands within 10% of
the original. It checks no behaviour at all. It is an instrument for detecting
elided code (`# ... rest unchanged`), and switching the edit format to udiff cut
lazy coding **3× with the model unchanged**. That is a harness experiment, and
it is the cleanest published template for isolating one scaffold mechanism.

**Devin's 13.86% (March 2024) should not be cited.** It is 79 of 570 instances —
a 25% subsample of *full* SWE-bench, not Lite — with Devin unassisted and every
baseline assisted, and it compares a closed pair against model-level baselines.
Cognition themselves wrote in Oct 2025: "we stopped reporting SWE-Bench numbers
in 2024." Also correct a common error: **SWE-bench Multimodal is not
Cognition's** — it is the Princeton/Stanford/Meta SWE-bench group (arXiv
2410.03859).

**Cursor's CursorBench is unreproducible in principle**, and that is not a
rhetorical flourish: private task corpus (sourced from Cursor's own codebase via
"Cursor Blame"), private LLM graders, and evaluation inside Cursor's own harness
which they separately tune per-vendor. Three stacked home-field advantages.
Credit where due — their **Terminal-Bench footnote is the fairest disclosure in
this survey** (official Harbor, default settings, 5 iterations averaged, explicit
per-vendor harness attribution). It is also the benchmark where they lose.

**Anthropic published a harness-vs-harness measurement of a competitor's
product**, and it is the best single datapoint in this document. Claude Opus 4.6
system card, Figure 2.5.A: for GPT-5.2-Codex they reproduced **57.5% on Terminus-2
and 64.7% on OpenAI's Codex CLI harness** (890 trials). Same model, same
benchmark, **7.2 points of pure harness delta**.

---

## 2. Which benchmark measures what, and why

The mechanism, not the marketing.

**Terminal-Bench measures the harness** more than anything else on this list, for
three structural reasons. The agent is genuinely *installed into the container* —
Harbor's `BaseInstalledAgent.install()` runs `apt-get` inside the box and, for
Claude Code, curls Anthropic's bootstrap script and runs the real shipped binary.
Grading inspects container state via `tests/test.sh` writing
`/logs/verifier/reward.txt`; there is no patch to extract and nothing the agent
*says* is read. And the leaderboard is keyed on `<agent>__<model>`, so the same
model appears under a dozen scaffolds and the delta is readable directly.
Harbor even models harness failure as first-class types —
`ContextWindowExceededError`, `OutputTokenExceededError`, `ApiRateLimitError`.

**SWE-bench measures the pair**, which `METHODOLOGY.md` §1 already establishes.
What is new here is that **the maintainers now agree in writing**. The Bash Only
board — 47 entries, all mini-SWE-agent — exists to pin the scaffold. mini-SWE-agent
is ~190 lines, bash-only, no tool-calling interface, linear history,
`subprocess.run` per action, and scores **76.8%** on Verified (Opus 4.5,
2026-02-17). It is within a couple of points of every elaborate commercial
harness. ProgramBench adopted it as its sole scaffold for the stated reason of
"reducing confounds between model capability and harness design." **mini-SWE-agent
has become the field's standard scaffold control**, and that is the strongest
available argument that elaborate-harness SWE-bench scores are mostly model.

One further note on SWE-bench: since 2025-11-18 the Verified and Multilingual
boards accept submissions **only from academic institutions or established
research labs**. Commercial harness submissions are rejected. We could not submit
even if we wanted to.

**Recovery-Bench holds the model fixed by design**, and its `installed:<agent>`
mechanism makes agent-sweeping first-class. Its headline finding — models are
*actively misled* by a failed trajectory left in context — is a scaffold property
(what you carry forward, when you compact, whether you reset), not a model
capability. Our reading of it was correct.

---

## 3. Benchmarks we did not know about

Ranked by value to us. Everything here is new relative to `NEXT_BENCHMARKS.md`.

### 3.1 Harbor-Index — the highest-value find
`harbor-index.org` · in the Harbor registry as `harbor-index`

**82 tasks selected from 6,627 candidates across 54 benchmarks**, final set
spanning 29 of them across software engineering, scientific research, tool use,
maths, data analytics and security. Three-stage filter: drop anything with >33%
pass rate across frontier models, LLM-audit for instruction/verifier misalignment,
then 14 independent human reviewers. Binary pass/fail, no partial credit.

Why it matters to us, in their own framing: the source evaluation consumed "226B
tokens and over $300K of compute," and **"condensing into Harbor-Index costs a
frontier agent only a few hundred dollars."** It is explicitly built to support
"reliable comparison across agents efficiently." Unsaturated — **top score 28.1%
(GPT-5.5); Claude Opus 4.8 + Claude Code 20.7%; nothing above 30%.** And they
audited for reward hacking: 9 of 1,476 rollouts (0.6%) flagged.

This is a compact, unsaturated, cheap, harness-comparable benchmark from the
Terminal-Bench authors, runnable on one box through infrastructure we already
have installed. Nothing else on the list has that combination.

### 3.2 Harness-Bench — a benchmark built to answer this exact question
arXiv **2605.27922**, *"Harness-Bench: Measuring Harness Effects across Models in
Realistic Agent Workflows."*

106 sandboxed tasks, **5,194 execution trajectories across model-harness
pairings**. Defines the harness as "the execution layer managing context, tools,
state, and recovery" and makes it the object of study. Names a failure mode we
have been describing without a word for: **execution-alignment failure**, where
plausible reasoning decouples from tool feedback and workspace state. Caveat: it
deliberately maps the joint space rather than holding the model fixed, and code
availability is not stated in the abstract. **Read the paper before building
anything** — its taxonomy may be worth more to us than its tasks.

### 3.3 Terminal-Bench Pro — 200 public tasks, TB2.0-format
`github.com/alibaba/terminal-bench-pro` · Harbor registry `terminal-bench-pro@1.0`

Alibaba. **400 tasks (200 public / 200 private)** across 8 domains, expert-designed
from real scenarios and GitHub issues, **~28.3 test cases per task** — far denser
verification than TB2's typical single pytest. Fully TB2.0-format, so it runs
through Harbor unchanged:

```
harbor run --dataset terminal-bench-pro@1.0 --agent claude-code \
  --model anthropic/claude-sonnet-4-5 --n-concurrent 4
```

The public/private split is a real contamination control, on the SWE-bench Pro
model. Caveat: submissions go by **email to `yanquan.xx@alibaba-inc.com`**, so
there is no automated verification and no public methodology page.

### 3.4 Claw-SWE-Bench — the effect size we have been asserting, measured
arXiv **2606.12344** · `github.com/opensquilla/claw-swe-bench`

350 issue-resolution instances, 8 languages, 43 repos, with a `BaseClawAdapter`
protocol that normalises prompting and patch collection across *heterogeneous
harnesses*. Runs a five-harness × two-model sweep. **With the model held fixed,
harness choice moves pass@1 by 12.5 pp (GLM-5.1) and 27.4 pp (Qwen3.6-flash) —
against a 29.4 pp spread across nine models on a fixed harness.** The scaffold
effect is nearly as large as the model effect. Ran on a single 16-core Linux box
with an 80-instance Lite subset. Small group, new; **take the adapter protocol as
the reusable artifact, not the board as authoritative.**

### 3.5 The rest, briefly
- **Terminal-Bench 3 / Frontier-Bench** — **74 professional computer-work tasks,
  7 domains. Top score 43.5% (Claude Opus 5).** Deeply unsaturated. This is where
  the frontier moved.
- **Terminal-Bench Challenges** — three single-task, unlimited-resource,
  *metric-graded* (not pass/fail) projects: Rust compiler speedup graded on
  instruction count over 52 rustc-perf crates; an inference engine in one
  <25 kB C/CUDA file scored on a TTFT/throughput Pareto frontier; WASM rendering.
  A genuinely different measurement shape.
- **HAL, the Holistic Agent Leaderboard** (arXiv 2510.11977, Princeton) — not a
  task set but infrastructure that sweeps {model} × {scaffold} × {benchmark},
  whose *stated contribution* is decomposing performance into model vs scaffold.
  21,730 rollouts, ~$40k. The most on-thesis third-party artifact in existence.
- **CooperBench** (Harbor, 652 tasks) — multi-agent cooperation, 652 feature
  pairs across 12 repos requiring **two agents to coordinate**. If FleetView
  becomes a priority, this is the instrument, and it is already in the registry.
- **CodeClash** (arXiv 2511.00839) — multi-round *tournaments* where agents
  maintain competing codebases in a code arena. Long-horizon codebase
  maintenance, not one-shot patching. 1,680 tournaments.
- **ProgramBench** (Meta/Stanford/Harvard) — 200 tasks: rebuild a program from
  its compiled binary and docs, no source, graded by 248,000 fuzz tests. Top
  score **4.5%**. Brutal, and it uses mini-SWE-agent as its sole scaffold.
- **Harbor's registry is 80 datasets.** `swebench-verified` (500) and
  `swebenchpro` (731) are both in it. Also on-shelf: `gso` (102 software
  optimisation), `legacy-bench`, `compilebench`, `swtbench-verified` (433),
  `featurebench` (200), `vmax-tasks` (1043 real JS bug fixes),
  `swe-gen-js` (1000), `openthoughts-tblite` (100), `scale-ai/swe-atlas-{qna,tw}`.
  **Everything we want to run is one `--dataset` flag away from infrastructure
  already in `bench/terminalbench/.venv`.**

### 3.6 One caveat on all of it
An independent analysis of 5,700+ Harbor runs reports that **53% errored out**
producing no data, and that roughly one in five correct results was misclassified
as a failure — with 42% of 1,526 agent+model combinations failing the trivial
`hello-world` task. Whether that reflects Harbor or the analyst's operation of it
is unclear from the piece. Either way: **Harbor's own infrastructure noise may
exceed the harness deltas we are trying to measure.** Run the `oracle` and `nop`
agents as controls on every dataset before quoting anything, exactly as we do
gold/empty on SWE-bench.

---

## 4. Model and config: what everyone actually runs

This is the question that matters most, so it gets the fullest treatment the
sources allow. Blank cells are undisclosed, and the blanks are the finding.

| Project | Model + version | Default or chosen? | Turn / budget limits | Test-time scaling | Cost disclosed |
|---|---|---|---|---|---|
| **goose** (Harbor) | `claude-sonnet-4-6`, pinned across 9 of 10 rows | chosen, pinned | **3k turns**; `--max-turns` flag | none stated | **yes, per run** |
| **cline** | GLM-5.2 (open-weights post), Kimi K3 (2.1 post) | chosen | timeout multiplier **2.0**, n=20 concurrency | pass@1; reports **pass^k** + flakiness separately | yes ($49.8, $79) |
| **mini-SWE-agent** | `claude-4.5-opus`, `gemini-3-flash`, `minimax-m2.5` | swept | `--cost-limit` | none — single attempt, no tools | **yes, on the leaderboard** |
| **Anthropic** (model) | Opus 4.6 | own | 64K thinking budget (128K for TB) | **25 trials averaged** for SWE-bench; 15 runs × 89 for TB | no |
| **OpenAI** (model) | GPT-5.3-Codex `xhigh` | own | **1,000 turns**, compaction **every 100K tokens** | `resume --last` on abort; "multiple runs aggregated" | no |
| **Cursor** | Composer 2.5 | own | — | TB: **5 iterations averaged** | no |
| **Amp** | per-model cards | swept | — | — | yes ($513 for 102 tasks) |
| **OpenHands** | Claude Opus 4.5 | chosen | `--max-iterations 500` | `ITERATIVE_EVAL_MODE` retries **3×** and silently raises temp 0→0.1 | no |
| **Hermes** (Harbor cfg) | any | — | **`max_turns: 90`**, delegation 50, **compression at 0.85** | none | no |

### The disclosure asymmetry
The best-disclosed configuration anywhere is OpenAI's, and it is buried in a
system-card *cyber-eval* appendix, not attached to any headline: Codex CLI,
`xhigh` effort, web search on, `--dangerously-bypass-approvals-and-sandbox`,
**up to 1,000 turns**, **compaction triggered every 100K tokens**, and
`resume --last` when the agent aborts. That last item silently inflates the
denominator, and it is disclosed nowhere near the number it affects.

Anthropic's is the most honest at the headline: named harness (Terminus-2),
named node type, 1,335 trials, adapter open-sourced to Harbor — and a disclosed
prompt modification ("use tools as much as possible, ideally more than 100
times…") that lifts SWE-bench by 0.6 pp. Publishing the prompt is honest; it also
means the number is partly a prompt-engineering artifact. And **25-trial-averaged
is not pass@1** and must not be compared to a single-run figure.

### What the Harbor adapters reveal, whether or not the projects meant them as configs
Read from `bench/terminalbench/.venv/.../harbor/agents/installed/`:

- **codex**: `codex exec --dangerously-bypass-approvals-and-sandbox
  --skip-git-repo-check --model <m> --json --enable unified_exec`, with
  `model_reasoning_effort` **defaulting to `high`**.
- **opencode**: `opencode --model=<m> run --format=json --thinking
  --dangerously-skip-permissions`. Sets `OPENCODE_FAKE_VCS=git`.
- **goose**: writes a recipe YAML, then `goose run --recipe … --output-format
  stream-json`. Exposes `--max-turns`.
- **claude-code**: exposes `--max-turns`, `--effort`, **`--max-budget-usd`**,
  `--fallback-model`, `--permission-mode`, `MAX_THINKING_TOKENS`.
- **mini-swe-agent**: `--cost-limit`, `--exit-immediately`.

Two structural observations. First, **`--max-budget-usd` and `--cost-limit` are
first-class in two of the five** — cost is a control input, not just an output.
Second, and more important: **every single adapter parses `cache_read` and
`cache_write` tokens separately**, and Harbor's `AgentContext` has a first-class
`n_cache_tokens` field. Cache-hit rate is a metric the entire field reports.
Ours is zero.

---

## 5. The cost finding: it is caching, not price, and the evidence is published

goose's `evals/harbor/README.md` contains a model-pinned cross-harness table over
89 Terminal-Bench 2 tasks. It is the only published artifact anywhere that gives
tokens *and* cost *and* pass rate for multiple harnesses on one model. Dividing
it out — per task, and then solving for the effective input rate:

| arm | in/task | out/task | ratio | $/task | eff. $/M input | implied cache hit |
|---|---|---|---|---|---|---|
| **Claude Code** | 1.15M | 13.5k | 85:1 | **$0.48** | **$0.24** | ~100% |
| **opencode** | 1.25M | 18.0k | 70:1 | $0.79 | $0.42 | ~96% |
| **pi** | 1.29M | 20.2k | 64:1 | $0.84 | $0.42 | ~96% |
| goose codemode | 0.71M | 12.4k | 58:1 | $2.32 | **$3.00** | **0%** |
| goose summon | 0.76M | 11.2k | 67:1 | $2.44 | $3.01 | 0% |
| goose sum_codem | 0.88M | 15.7k | 56:1 | $2.86 | $2.99 | 0% |
| goose dev-only | 0.79M | 13.5k | 59:1 | $2.58 | $2.99 | 0% |
| **OSA** (head-to-head) | **3–8M** | — | **~140:1** | — | **$3.00** | **0%** |

Method and its limits, stated plainly. The effective input rate is
`(total_cost − output_tokens × $15/M) ÷ input_tokens`, assuming Anthropic
Sonnet-tier pricing ($3/M in, $15/M out, $0.30/M cache read). **That pricing is
assumed, not confirmed for `claude-sonnet-4-6`.** The goose table also carries no
run date and no trial count, and one goose row reports 2.4M input where its
siblings report 63–78M, which means the token accounting is not uniform across
rows. Treat the absolute cache percentages as indicative.

The *structure* survives all of that, and it is what matters:

- **Every goose-native config lands within 0.4% of exactly $3.00/M.** Four
  independent rows hitting the full uncached rate to three significant figures is
  not a pricing-assumption artifact. goose gets no cache benefit at all.
- **Every third-party harness lands at $0.24–0.42/M** — an 86–92% discount.
- **goose burns the fewest input tokens of anyone in the table and pays the
  most.** 0.71M/task versus Claude Code's 1.15M, at 4.8× the cost per task.
  Caching dominates cost so completely that it inverts the token ranking.

**Read against OSA, the conclusion is unambiguous.** Every harness in this table
lands in a narrow band: **0.7–1.3M input tokens per Terminal-Bench task, at a
56–85:1 input:output ratio.** OSA burns 3–8M at ~140:1. So OSA has *two*
independent multipliers stacked:

1. **3–7× the input tokens** of the entire competitive field.
2. **0% cache hits**, where the CLI harnesses run at ~96–100%.

Multiplied: **12–35× Claude Code's cost per task** on identical work. At 32.5M
input tokens — the longest head-to-head task, which codex solved on 3.66M — the
input alone is ~$97 uncached against Claude Code's median $0.48.

The 140:1 ratio is its own diagnostic. Everyone else sits at 56–85:1. A ratio
that high means many turns, each re-reading an enormous context and emitting very
little. That is the signature of a context that is not being trimmed between
turns — which matches the known `split_system/2` cache-block flattening and the
compaction denominator issue, and points at the same subsystem from a second
direction.

**And note what this costs us in benchmarking, not just in production.** Harbor-Index
costs a frontier agent "a few hundred dollars" for 82 tasks. At 12–35× the field's
per-task cost, that is thousands for us. **Our benchmarking budget problem is a
harness defect, not a benchmark-selection problem.** Fix the burn and the whole
benchmark menu becomes affordable.

---

## 6. Recommendation

### 6.1 The honest headline: the current set is right, with one correction

**SWE-bench Verified, SWE-bench Pro, Terminal-Bench and Recovery-Bench is a
defensible set, and this research did not find a gap in it.** Every argument in
`METHODOLOGY.md` and `NEXT_BENCHMARKS.md` survived contact with what competitors
actually publish, and two were strengthened: SWE-bench's maintainers now
concede the scaffold confound in writing, and Terminal-Bench's `<agent>__<model>`
submission key confirms it is the field's harness board.

The one thing that is wrong is small and mechanical: **we run Terminal-Bench 2.0;
the live leaderboards are 2.1 and 3.** TB 2.1 fixed 28 tasks and added continuous
validation. Our number is against a superseded task set, and 2.1 is where our
competitors' current numbers are. One dataset flag.

### 6.2 Ranked, by: measures the harness / is what competitors report / runs on one box / cost

| # | Benchmark | Harness? | Competitors report it? | One box? | Cost | Verdict |
|---|---|---|---|---|---|---|
| 1 | **Terminal-Bench 2.1** | **yes** | **yes** — Claude Code, Codex, Cursor CLI, goose, opencode, cline, OpenHands, mini-SWE-agent | yes | low | **Switch from 2.0. Do this first.** |
| 2 | **Harbor-Index** | yes | new, from the TB authors | yes | **a few hundred $** | **Adopt.** 82 tasks, unsaturated at 28.1%, built for cross-agent comparison |
| 3 | **Recovery-Bench** | **yes — model fixed by design** | no | yes (reuses TB2) | near zero | **Keep.** Finish the run. Unique attribution property |
| 4 | **SWE-bench Verified** | pair | yes, universally | yes | moderate | **Keep as regression signal only.** We cannot submit — academic/lab-only since Nov 2025 |
| 5 | **SWE-bench Pro** | pair | yes — OpenAI reports it | yes | moderate–high (disk) | **Keep.** Unsaturated, contamination control, and it is in the Harbor registry |
| 6 | **Terminal-Bench 3** | yes | emerging | yes | low (74 tasks) | **Watch.** Top score 43.5%; this is where the frontier moved |
| 7 | **Terminal-Bench Pro** | yes | not yet | yes | moderate | **Second tier.** 200 tasks, 28 tests each, but email submission and no public methodology |
| 8 | **aider-polyglot** | **no — model bench** | aider's own leaderboard | yes | very low | **Optional.** Now one Harbor flag; run it only to say we did |
| 9 | **CooperBench** | yes | no | yes | moderate | **Only if FleetView becomes a priority.** Then it is the right instrument |

**Do not add:** CursorBench (unreproducible in principle), FrontierCode
(deliberately closed), anything LLM-judge-graded — opencode already ran that
experiment and published the post-mortem.

### 6.3 What to publish, and in what form

Publish exactly what goose publishes, because it is the format that makes a
harness claim legible: **model pinned, one row per harness, and tokens, cost,
turns, wall-clock and pass rate on every row.** Our head-to-head already produces
all of that plus per-loss attribution, which no competitor publishes. Add
`n_cache_tokens` to the reported columns — every adapter in the field emits it,
and it is where our biggest defect is visible.

Two claims we can make that nobody else can, and should therefore lead with:
per-loss layer attribution (harness / agent / model / environment), and a
declared, probed air-gap. Both are already built.

---

## 7. Config changes to adopt, ranked by expected effect on token burn

This is the gap. Ranked by expected effect; all of it lives outside the
directories currently under benchmark load.

**1. Fix prompt caching. Nothing else on this list is close.**
Every CLI harness in the goose table runs at 96–100% cache hits; we run at 0%.
Cost impact alone is ~10×, before any token reduction. The known mechanism is
`split_system/2` flattening the cache blocks around a microsecond timestamp — any
per-request-varying token inside a cache-prefixed block invalidates the whole
prefix. **Verify with an actual `cache_read_input_tokens > 0` from a live
provider, not a test.** Ollama-served models will not exercise this path, so this
must be validated against Anthropic or OpenAI directly.

**2. Cap turns explicitly, and compact on a token trigger rather than a
denominator.** OpenAI runs Codex at **1,000 turns with compaction every 100K
tokens** — an absolute token trigger, not a fraction of a context window. That
sidesteps the fabricated-context-window class of bug entirely. Hermes compresses
at 0.85 of context; goose and Claude Code both expose `--max-turns`. We should
have both a turn cap and an absolute-token compaction trigger, and both must be
recorded in the manifest.

**3. Attack the 140:1 input:output ratio directly.** The field sits at 56–85:1.
Ours implies the context is not being trimmed between turns — stale tool output,
full file re-reads, and unpruned history all riding along on every request.
Instrument per-turn input growth and find what is not being dropped. This is
worth 3–7× on its own and is independent of caching.

**4. Add `--max-budget-usd` / `--cost-limit` as a first-class runtime control.**
Claude Code and mini-SWE-agent both expose it; Harbor plumbs it through. A
benchmark run that cannot bound its own spend is one bad task away from the
budget. This is cheap to build and immediately useful.

**5. Adopt mini-SWE-agent as our fixed-scaffold control.** It is ~190 lines,
bash-only, no tool-calling interface, and scores 76.8% on SWE-bench Verified. The
field has already standardised on it as the scaffold control, and it is already a
working arm in our head-to-head. Every OSA number should be reported next to the
mini-SWE-agent number on the same model. **If a 190-line bash loop matches us,
that is the finding**, and we should be the ones to publish it.

**6. Steal one measurement design: Hermes `evals/readtool`.** Nine hostile-file
fixtures (a 2.7 MB `package-lock.json`, a 600 KB minified single line, a 150 K-line
log, a **FIFO that blocks naive reads**, PNG bytes behind a `.txt` name), model
held fixed, one harness feature toggled. Their published result: adding a
stat-based guard to `read_file` cut tokens **−43% on Opus and −79% on Qwen**, and
wall-clock **−81%**, with accuracy unchanged at 1.00. That is a token-burn fix
found by a cheap, deterministic, single-mechanism ablation — exactly the shape of
instrument our 140:1 ratio needs, and it costs a day to build.

---

## Sources

Primary sources only; secondary claims are marked as such in the text.

**Harness projects**
- goose Harbor evals — `github.com/block/goose/tree/main/evals/harbor`
- cline evals — `github.com/cline/cline/blob/main/evals/README.md`; results at `github.com/cline/benchmark-results`; `cline.bot/blog/recursive-self-improvement-for-coding-agents`
- aider — `aider.chat/docs/leaderboards/`, `/docs/unified-diffs.html`, `github.com/Aider-AI/aider/tree/main/benchmark`
- opencode — `opencode.ai/docs/`, `github.com/anomalyco/opencode-bench` (`benchmark-observations.md`)
- mini-SWE-agent — `github.com/SWE-agent/mini-swe-agent`; leaderboard data `github.com/swe-bench/swe-bench.github.io` → `data/leaderboards.json`
- OpenHands — `github.com/OpenHands/benchmarks`; `index.openhands.dev`
- Hermes — `github.com/NousResearch/hermes-agent`, `evals/readtool/`
- Codex CLI — `github.com/openai/codex` (no benchmark numbers in repo)
- gemini-cli — `github.com/google-gemini/gemini-cli/tree/main/evals`

**Vendor disclosures**
- Anthropic Claude Opus 4.6 system card (Fig 2.5.A harness delta; §5.1.2 Claude Code safety eval)
- Anthropic — `anthropic.com/engineering/swe-bench-sonnet`, `/engineering/infrastructure-noise`
- OpenAI GPT-5.3-Codex system card §5.1.2 (Codex CLI harness spec)
- Cursor — `cursor.com/evals`, `/blog/cursorbench`
- Cognition — `cognition.com/blog/swe-bench-technical-report`, `/frontiercode`

**Benchmarks and infrastructure**
- Terminal-Bench / Harbor — `tbench.ai`, `harborframework.com`, ICLR 2026 `openreview.net/forum?id=a7Qa4CcHak`; registry `raw.githubusercontent.com/laude-institute/harbor/main/registry.json` (80 datasets)
- Harbor-Index — `harbor-index.org`
- Harness-Bench — arXiv 2605.27922
- Claw-SWE-Bench — arXiv 2606.12344
- Terminal-Bench Pro — `github.com/alibaba/terminal-bench-pro`
- HAL — arXiv 2510.11977, `hal.cs.princeton.edu`
- Recovery-Bench — `github.com/letta-ai/recovery-bench`
- CodeClash — arXiv 2511.00839 · ProgramBench — `programbench.com`
- Survey: agent system and harness design — arXiv 2606.20683
- Skeptical counterweight on Harbor infrastructure noise — `neurometric.substack.com/p/what-we-learned-about-the-harbor`
