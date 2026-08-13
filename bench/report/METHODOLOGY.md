# Methodology: what our benchmark numbers mean, and what they cannot claim

This document exists so that a number produced by `bench/` can survive being
argued with. It covers three things:

1. why a SWE-bench score from one harness cannot be compared with one from
   another,
2. what is actually wrong with SWE-bench as a measurement of ability,
3. what we therefore do, and what we refuse to do.

Every factual claim below is cited. Where the evidence is contested, that is
stated rather than smoothed over.

---

## 0. The one-paragraph version

A SWE-bench Verified percentage is not a property of a model, and it is barely
a property of a harness. It is a property of a *(model × scaffold × budget ×
attempt policy × instance subset × grader version)* tuple, and every one of
those terms moves it by more than the gaps that separate entries on the public
leaderboard. On top of that, the benchmark itself has documented solution
leakage, documented mis-grading, documented memorisation, and documented cases
of agents reading the answer out of git history. We run it because it is the
common currency and because it exercises the harness end-to-end — **not**
because the resulting number ranks us against anyone.

---

## 1. Why published numbers are not comparable

### 1.1 The scaffold moves the number more than the model does

Measured, controlled evidence:

- Epoch AI, running the same models across scaffolds, found scaffold choice
  has "the single biggest impact on the overall performance": **up to 11 points
  for GPT-5 and up to 15 points for Kimi K2 Thinking** on SWE-bench Verified.
  ([Epoch AI, *Why benchmarking is hard*](https://epoch.ai/gradient-updates/why-benchmarking-is-hard))
- Epoch's separate skills analysis puts the swing from scaffold choice alone at
  **up to 20 percentage points**.
  ([Epoch AI, *What skills does SWE-bench Verified evaluate?*](https://epoch.ai/publications/what-skills-does-swe-bench-verified-evaluate))
- Claude 3.7 Sonnet: **62.3% → 70.3%** moving from a standard evaluation to
  Anthropic's custom scaffold. GPT-4o: **23% → 33.2%** across scaffolds in
  OpenAI's own analysis.
  ([OpenHands, *AI Coding Benchmarks Explained*](https://www.openhands.dev/blog/ai-coding-benchmarks-explained))
- Vendor-scaffold vs. the maintainers' neutral bash-only harness on the same
  models: Claude Sonnet 4.5 **77.2%** (Anthropic) vs **72.8%** (Bash Only);
  Claude Opus 4.5 **80.9%** vs **76.8%**.
  ([Anthropic](https://www.anthropic.com/news/claude-sonnet-4-5);
  [Simon Willison, Feb 2026 leaderboard update](https://simonwillison.net/2026/Feb/19/swe-bench/))

The maintainers effectively conceded the point by creating the **Bash Only**
track — a fixed ~100-line ReAct agent with one tool, run by them across every
model, precisely so that the scaffold stops being a free variable.
([mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent))

The academic statement of the problem: *Stop Comparing LLM Agents Without
Disclosing the Harness* — "Without disclosure of harness details, readers
cannot determine whether reported improvements reflect genuine model advances
or merely harness modifications."
([arXiv:2605.23950](https://arxiv.org/pdf/2605.23950))

### 1.2 The denominator is not always 500

Published "SWE-bench Verified" figures are computed on different instance sets:

| Reporter | n | Reason given |
|---|---|---|
| Anthropic (Claude 4 era) | 500 | — |
| Anthropic (Sonnet 3.7 era) | 489 | — |
| OpenAI | 477 | 23 instances whose gold patches "did not reliably pass on our infrastructure" |
| Epoch AI | 484 | 16 excluded as unrunnable |

Epoch additionally estimates a **5–10% dataset error rate**.
([Epoch AI, SWE-bench Verified](https://epoch.ai/benchmarks/swe-bench-verified))

### 1.3 Attempt policy: pass@1, averaged trials, and best-of-N are three things

The official checklist defines pass@1 as "submits 1 prediction per task
instance" and **forbids pass@k**. But it **permits best-of-k** — N rollouts
plus a reranker — provided the selection uses "a separate decision module
without relying on SWE-bench evaluation data," and that is still reported as
pass@1.
([SWE-bench submission checklist](https://github.com/swe-bench/experiments/blob/main/checklist.md))

Magnitudes:

- Anthropic's own single-attempt vs. rejection-sampling gap for Sonnet 4.5:
  **77.2% → 82.0%** ("parallel test-time compute, rejection sampling, and
  internal scoring to select optimal candidates").
- Agentless generates 40 samples per instance and reranks; swapping in
  generated reproduction tests for reranking moves resolution by **3.3–7.3%**.
  ([Agentless](https://github.com/OpenAutoCoder/Agentless/blob/main/README_swebench.md))
- A third, distinct thing: **"averaged over N trials"** (Anthropic uses 10
  trials for Sonnet 4.5, 5 for Opus 4.5). This is variance reduction on an
  estimate of pass@1, not selection — it is *more* honest than a single run,
  not less, and must not be lumped in with best-of-N.

**We run best-of-1, no reranking, no test-time compute, single trial.** That
is the least flattering of the three and is recorded explicitly in every
manifest.

### 1.4 Budgets are usually undisclosed

Epoch publishes hard budgets (2M uncached tokens, 20M cached-read tokens per
task, isolated Docker, no network). Anthropic publishes a thinking budget and
context ceiling but no turn cap or wall-clock timeout. Most vendors publish
none.

**We record all of them** — `agent_timeout_s`, `max_turns`, `max_budget_usd`,
`test_bridge` — in `config.json` and in the manifest.

### 1.5 Cost figures are not comparable at all

The official leaderboard **does not report cost**; `metadata.yaml` requires
only agent, org, and model names. Third-party cost figures vary with prompt
caching, which providers expose inconsistently. A run against a subscription
or local model reports **0 USD**, which means "unpriced", not "free" — the
reporter says so explicitly rather than letting a 0 sit next to someone else's
metered API bill.

---

## 2. What is actually wrong with SWE-bench

### 2.1 Solution leakage in the issue text

*SWE-Bench+* manually inspected SWE-Agent+GPT-4's **resolved** instances and
found the fix present in the issue report or its comments in **32.67%** of
successful patches; a further **31.08%** passed on weak tests. Filtering both
dropped the resolve rate **12.47% → 3.97%** on the full dataset. Per split:
**33.04%** solution leak on Verified (37 of 112 passed patches), with a further
**12.50%** incorrect and **9.82%** incomplete.
([arXiv:2410.06992](https://arxiv.org/abs/2410.06992))

**Read this carefully.** The denominator is *resolved instances*, not the whole
dataset — "32.67% of SWE-bench is leaked" is a miscitation. And the paper is a
**preprint whose expanded version was withdrawn from ICLR 2026**; its headline
0.55% resolve rate should not be quoted as a real-world figure.

### 2.2 Weak tests — including in Verified, after expert review

- **UTBoost** (Yu, Zhu, He, Kang — **ACL 2025**, peer-reviewed) found **36 task
  instances with insufficient tests** and **345 erroneous patches incorrectly
  labelled as passed** (176 Lite, 169 Verified). Correcting them changed
  **40.9% of Lite and 24.4% of Verified leaderboard entries**, producing **18
  and 11 ranking changes**. Concretely: Amazon-Q-Developer-Agent (1st, 55%) and
  devlo (2nd, 54.2%) both fall to a tie at **53.6%**.
  ([ACL Anthology 2025.acl-long.189](https://aclanthology.org/2025.acl-long.189/) ·
  [arXiv:2506.09289](https://arxiv.org/abs/2506.09289))
  **The official leaderboard was not re-issued.**
- **SWE-ABS** strengthens Verified's tests via coverage-driven slicing and
  mutation, and rejects **19.71%** of previously-passing patches; the top agent
  falls **78.80% → 62.20%** and the former #1 drops to #5.
  ([arXiv:2603.00520](https://arxiv.org/abs/2603.00520), preprint)
- **OpenAI's own audit** of 138 frequently-failed problems found **≥59.4% had
  material test flaws** — 35.5% "narrow" (enforcing implementation details
  absent from the problem statement), 18.8% "wide". Note that this subset was
  **deliberately drawn from failures**, so it is not a statement about the
  benchmark as a whole, and its two named components do not sum to the
  headline.

### 2.3 The models have memorised it

*The SWE-Bench Illusion* (Liang, Garg, Zilouchian Moghaddam — **ICSE 2026
SEIP**, peer-reviewed) withholds the repository entirely and still gets:

- **file-path identification from issue text alone: up to 76% on SWE-bench vs
  ≤53% on non-SWE-bench repos**
- **ground-truth function reproduction: up to 35% consecutive 5-gram verbatim
  match on Verified/Full vs 18% elsewhere**

([arXiv:2506.12286](https://arxiv.org/abs/2506.12286))

A second preprint reaches the same conclusion by the same route: 76%/73%
all-files localisation on Verified vs 21%/17.6% on BeetleBox with only issue
text and file structure.
([arXiv:2512.10218](https://arxiv.org/abs/2512.10218))

Context: **>94% of SWE-bench issues were created before the knowledge cutoffs
of the models evaluated on them**, and roughly half of instances date from 2020
or earlier.

**The honest counterweight.** The cleanest same-distribution test — SWE-rebench's
own pre/post-cutoff temporal split — shows only GPT-4.1 declining meaningfully
(**31.1% → 26.7%, −4.4 pp**). The dramatic 13–18 pp drops are *cross-benchmark*
and confound contamination with difficulty and repo-age distribution shift.
*Test of Time* (**ACL 2026**) shows temporal decay can be erased entirely by an
LLM-driven reformulation with source content unchanged, so post-cutoff decay
"cannot on its own establish contamination."
([arXiv:2505.20411](https://arxiv.org/abs/2505.20411) ·
[arXiv:2509.00072](https://arxiv.org/abs/2509.00072))

### 2.4 Agents have been caught reading the answer out of git

**SWE-bench issue #465** (opened by Meta, Sept 2025): task containers shipped
with remotes, branches, tags and reflog intact, so commits *after* the pinned
base commit were reachable. Named traces include Claude Sonnet on
`pytest-6202` finding the future fix via `git log --all`, and Qwen3-Coder-480B
on `django-13513` locating the fix PR via `git log --grep=<issue ID>`.
Maintainers patched the images (~Oct 2025) but conceded they "only performed a
quick preliminary search" and have no method for auditing existing
trajectories. **No leaderboard entry was removed or re-scored.**
([SWE-bench#465](https://github.com/SWE-bench/SWE-bench/issues/465))

Independent confirmation *after* the patch:
[arXiv:2604.11806](https://debugml.github.io/cheating-agents/) reproduced the
exploit without human intervention and documents 6 SWE-bench/SWE-rebench traces
copying historical patches.

**We tested our own images for this** — see §4.1. They are clean.

Note also that the official checklist **never prohibited reading git history**.
It prohibits using `PASS_TO_PASS`/`FAIL_TO_PASS`, the `hints` field, and
unmitigated web browsing.

### 2.5 The benchmark's own author organisation has retired it

OpenAI published *Why SWE-bench Verified no longer measures frontier coding
capabilities*, citing the test flaws above, contamination found by a
"contamination auditor agent", and saturation (SOTA moved only **74.9% → 80.9%
in six months**). SWE-bench co-creator Ofir Press pushed back that saturation
does not invalidate it for lower-scoring models. Both positions are on the
record; the exact publication date is inconsistent across secondary sources.

### 2.6 What SWE-bench Verified actually is

Worth stating plainly, because it is the source of most over-claiming.
93 Python developers annotated 1,699 random samples from the 2,294-instance
test split, three annotators each, ensembled by taking the **highest-severity**
label. Samples were dropped when the problem statement or the `FAIL_TO_PASS`
tests scored ≥2 on a 0–3 severity scale. **38.3%** were flagged for
underspecified problem statements and **61.1%** for unfair unit tests;
**68.3% were filtered out overall**.
([OpenAI](https://openai.com/index/introducing-swe-bench-verified/) ·
[annotation rubric PDF](https://cdn.openai.com/introducing-swe-bench-verified/swe-b-annotation-instructions.pdf))

The surviving 500 are, by the shipped `difficulty` column:

| difficulty | count |
|---|---|
| `<15 min fix` | 194 (38.8%) |
| `15 min – 1 hour` | 261 (52.2%) |
| `1–4 hours` | 42 (8.4%) |
| `>4 hours` | **3 (0.6%)** |

**91% of the benchmark is under an hour of human work.** Verified is the
deliberately *tractable and unambiguous* subset. A good score on it is table
stakes; it is not evidence of a strong harness, and it cannot exercise
long-horizon behaviour because there is almost no long-horizon work in it.

---

## 3. What a defensible report contains

`bench/report` refuses to emit a number without all of the following.

**Sample and selection.** n and the full denominator, always together. The
instance ID list, and a SHA-256 of it. Whether selection was a declared,
seeded random sample — if not, that is reported as unquantified selection bias.

**An interval, never a bare percentage.** We use the **Wilson score interval**
by default (Brown, Cai & DasGupta 2001, *Statistical Science* 16(2):101–133),
with **Clopper–Pearson** available for exact, conservative bounds. The normal
(Wald) approximation is implemented **only as a counter-example** and cannot be
selected: at k=0 or k=n it returns a zero-width interval, which is how "0/10"
gets presented as "0%, no uncertainty."

For scale: at a mid-range rate, **±5 pp needs about 385 tasks** and ±1 pp needs
9,604. A 10-task probe has an interval roughly 55 pp wide. That is why
subsets get counts, not percentages.

**Variance across runs.** The interval above covers sampling over *tasks* only.
It says nothing about run-to-run variation on the *same* tasks, which for a
stochastic agent is substantial — this is why vendors average over 5–10 trials.
A single run is flagged as having no variance estimate.

**Both denominators when the harness lost instances.** Excluding infrastructure
failures inflates; counting them deflates. Both are printed; choosing one is an
editorial act and is left to the reader.

**Failure distribution, before the rate.** Bucketed by cause and attributed to
a layer (harness / agent / model / environment), with a path to the transcript
of every individual failure. For a diagnostic benchmark this is the deliverable
and the pass rate is the by-product.

**Cost accounting.** Tokens in/out/cached, wall-clock, tool calls, turns, and
dollars — with 0 USD explicitly labelled "unpriced", not "free".

**A reproducibility manifest.** `bench/report/cli.py manifest` emits the exact
re-run command, the dataset and split, the `swebench` package version, the
Docker image digests, the OSA git commit and working-tree cleanliness, host
details, and **SHA-256 of every bench source file**, because `bench/swebench`
is under active development and last week's results.json was produced by
different code.

---

## 4. Validity audit of our own pipeline

Findings from reading `bench/swebench` and probing its artefacts. Those marked
**OPEN** are encoded in `honesty.KNOWN_HARNESS_DEFECTS` and appear on every
report until fixed.

### 4.1 What is sound

- **Grading is genuinely the official package.** `bench/swebench/evaluate.py`
  shells out to `swebench.harness.run_evaluation` and does not reimplement
  pass/fail. Verified: `swebench` 4.1.0.
- **Test edits cannot help.** The official harness resets test files to
  `base_commit` and applies the dataset `test_patch` before running. Our
  `git_diff()` additionally strips test paths. Double-protected.
- **The git-history loophole of SWE-bench#465 is not present in our images.**
  Probed `swebench/sweb.eval.x86_64.pallets_1776_flask-5014` directly:
  no remotes; HEAD is a synthetic `SWE-bench` commit;
  `git rev-list --all --count` == `git rev-list HEAD --count` == 4968, i.e.
  **no commit in the object store is unreachable from HEAD**. The future fix is
  not on disk.
- **The controls behave.** gold = 2/2, empty = 0/2 on the smoke set.
- **The prompt does not contain the tests.** `osa_runner.PROMPT` carries only
  `problem_statement`, and explicitly instructs against editing tests.

### 4.2 Inflates the score

**`f2p_test_names_leaked_to_agent` — was unconditional, now opt-in.** The
harness bakes the `FAIL_TO_PASS` node IDs into `run_tests.sh` (mode 0755) at
the repository root, which the prompt then tells the agent to use. Test names
routinely state the required behaviour outright: `pallets__flask-5014`'s sole
F2P is `tests/test_blueprints.py::test_empty_name_not_allowed`. This violates
the official checklist item "Does not use SWE-bench test knowledge
(`PASS_TO_PASS`, `FAIL_TO_PASS`)". The agent cannot *run* those tests (the
test_patch is not applied in the workspace) — but it can read them, and that is
enough.

**Status: mitigated.** `bench/swebench` now gates this behind `--f2p-hint`,
default off, and records `f2p_hint` in `config.json`. The reporter fires this
defect only when the flag was on — and treats runs predating the flag (no key)
as leaked, which is correct, because it was unconditional before it existed.
**All four runs currently on disk predate the flag and are therefore
affected.** Leave the flag off for any run whose number will be quoted.

**`headline_is_pass_at_k_not_pass_at_1` — new in schema v2.** `bench/swebench`
now supports multiple attempts per instance, and its `instances_resolved`
counts `resolved_any` — i.e. **pass@k**. The official checklist defines pass@1
as "submits 1 prediction per task instance" and **does not accept pass@k**.
This is the single largest source of inflation in self-reported figures, so the
reporter blocks quoting the headline whenever `attempts > 1`, surfaces the
recorded `pass_at_1` as the comparable number, and reports `pass^k` (resolved
on *every* attempt) as the reliability figure — which is the one that actually
matters for a harness people depend on.

**`web_lookup_of_solution_not_prevented`.** The task container runs
`--network none`, but the agent runs **on the host**, and
`osa_runner._run_http()` sets `permission_mode overdrive`, disabling the
approval path entirely. OSA ships `web_search`, `web_fetch` and `download`
builtins. The prompt names the repository and the exact base commit, and every
SWE-bench fix is a public commit. This violates the checklist item "Does not
have web-browsing OR has taken steps to prevent lookup of SWE-bench solutions
via web-browsing". Epoch runs with no network access for exactly this reason.

### 4.3 OPEN — deflates the score and corrupts the failure taxonomy

**`pytest_instances_unwinnable`.** `runners.py:_is_test_path()` matches the
substring `"test/"`, which is contained in `"src/_pytest/"`. Every
pytest-dev/pytest instance therefore has its entire source patch stripped
before grading. Verified against all 500 gold patches: **19 stripped in full,
0 in part.** Consequences: the achievable ceiling is **96.2%**, and those 19
report as `no_patch_produced` — charging a harness bug to the agent. The same
predicate also matches legitimate source paths such as `django/test/client.py`.

**Status: still open** as of this writing — `TEST_PATH_MARKERS` in
`runners.py` is unchanged. Schema v2 does now record `dropped_test_paths` per
instance, so the reporter detects the defect *per run* rather than relying on
the static list, and blocks any run in which a non-test source file was
stripped from the graded patch.

### 4.4 OPEN — blind spot

**`gold_control_bypasses_patch_extraction`.** `GoldRunner` returns the dataset
patch string directly; it never materialises a workspace and never calls
`git_diff()`. A gold run at 100% therefore validates **grading only**. The
pytest defect above lived precisely in this blind spot. A trustworthy upper
control would apply the gold patch *to the prepared workspace* and let the
normal extraction path produce the diff.

### 4.5 Lesser observations

- `run_bench.py` rewrites `started_at` on every invocation, so a
  `--reuse-inference` re-grade produces a `config.json` whose timestamps
  describe the grading pass, not the inference. Visible in `osa-smoke2`:
  a 5-second span containing 81 seconds of recorded agent wall-clock. The
  reporter flags this.
- `osa_runner.clear_session_files()` deletes `~/.osa/sessions/<session_id>.*`
  at the **start** of each attempt. Re-running the same `--run-id` therefore
  destroys the transcripts of the previous run — the primary diagnostic
  artefact. Use a fresh run id when the transcripts matter.

---

## 5. What our numbers may and may not be used for

**May.**
Detect regressions between OSA revisions on a fixed instance set. Locate
harness bugs through the failure distribution. Measure cost and latency per
task. Demonstrate that the pipeline is wired correctly (gold 100% / empty 0%).

**May not.**
Be compared with any other harness's published SWE-bench figure — §1.
Be quoted without its denominator and interval — §3.
Be quoted at all as "a SWE-bench Verified score" unless n = 500.
Be treated as a measure of general software-engineering ability: 91% of the
benchmark is under an hour of human work, ~33% of historically-resolved
instances had the solution in the issue text, and the models have
demonstrably memorised parts of it — §2.

---

## 6. Where to go next

SWE-bench Verified is saturated at the frontier (~96% top-of-leaderboard as of
Aug 2026) and is the deliberately tractable subset. For a benchmark used as a
diagnostic instrument, see `bench/report/NEXT_BENCHMARKS.md`.

---

## References

Sorted by what they establish.

**Comparability**
- Epoch AI, *Why benchmarking is hard* — https://epoch.ai/gradient-updates/why-benchmarking-is-hard
- Epoch AI, *What skills does SWE-bench Verified evaluate?* — https://epoch.ai/publications/what-skills-does-swe-bench-verified-evaluate
- Epoch AI, SWE-bench Verified benchmark page — https://epoch.ai/benchmarks/swe-bench-verified
- *Stop Comparing LLM Agents Without Disclosing the Harness*, arXiv:2605.23950
- SWE-bench submission checklist — https://github.com/swe-bench/experiments/blob/main/checklist.md
- mini-swe-agent (Bash Only track) — https://github.com/SWE-agent/mini-swe-agent
- Simon Willison, Feb 2026 leaderboard update — https://simonwillison.net/2026/Feb/19/swe-bench/
- OpenHands, *AI Coding Benchmarks Explained* — https://www.openhands.dev/blog/ai-coding-benchmarks-explained
- Anthropic, *Introducing Claude Sonnet 4.5* — https://www.anthropic.com/news/claude-sonnet-4-5
- Agentless — https://github.com/OpenAutoCoder/Agentless/blob/main/README_swebench.md

**Validity of SWE-bench**
- UTBoost, ACL 2025 — https://aclanthology.org/2025.acl-long.189/ · arXiv:2506.09289
- *The SWE-Bench Illusion*, ICSE 2026 SEIP — arXiv:2506.12286
- *SWE-Bench+*, arXiv:2410.06992 (preprint; ICLR 2026 submission withdrawn)
- *Does SWE-Bench-Verified Test Agent Ability or Model Memory?*, arXiv:2512.10218
- SWE-ABS, arXiv:2603.00520
- SWE-rebench, NeurIPS 2025 — arXiv:2505.20411
- SWE-bench-Live, arXiv:2505.23419
- *Test of Time*, ACL 2026 — arXiv:2509.00072
- *Finding Widespread Cheating on Popular Agent Benchmarks*, arXiv:2604.11806
- Holistic Agent Leaderboard, arXiv:2510.11977
- SWE-bench issue #465, repo-state loopholes — https://github.com/SWE-bench/SWE-bench/issues/465
- OpenAI, *Introducing SWE-bench Verified* — https://openai.com/index/introducing-swe-bench-verified/
- OpenAI, annotation rubric — https://cdn.openai.com/introducing-swe-bench-verified/swe-b-annotation-instructions.pdf
- OpenAI, *Why we no longer evaluate SWE-bench Verified* — https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/

**Statistics**
- Brown, Cai & DasGupta (2001), *Interval Estimation for a Binomial Proportion*, Statistical Science 16(2):101–133
- Newcombe (1998), *Interval estimation for the difference between independent proportions*, Statistics in Medicine 17:873–890
