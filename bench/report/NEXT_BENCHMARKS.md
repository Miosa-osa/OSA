# What we should benchmark next, and why

The purpose of benchmarking OSA is **diagnosis, not a score**. A benchmark that
OSA passes teaches us nothing and wastes the machine. What we want is hard,
real tasks that fail in ways attributable to *the harness* — compaction, long
tool runs, recovery from a bad step, multi-agent dispatch — rather than only to
the model.

That reframes the selection criterion. The question is not "which benchmark is
most respected" but **"which benchmark's failures point at a file in this
repository"**.

---

## Why SWE-bench Verified cannot be the answer

- **It is saturated.** Top of leaderboard is ~96% (Aug 2026); the top five span
  1–4 points. It no longer discriminates.
- **It is deliberately the tractable subset.** 68.3% of candidate instances
  were filtered out for being underspecified or unfairly tested. Of the 500
  survivors, **194 are "<15 min fix", 261 are "15 min–1 hour", and only 3 are
  ">4 hours"** — 91% is under an hour of human work.
- **Therefore it structurally cannot exercise long-horizon behaviour.** There
  is almost no long-horizon work in it. Our compaction, our multi-hour tool
  runs, and our recovery paths are barely touched.
- **OpenAI, which created Verified, has retired it** as a frontier measure.

Keep running it as a regression signal and a pipeline check. Stop expecting it
to tell us what to fix.

Full citations for all of the above: `METHODOLOGY.md` §2.

---

## Recommendation: build these three, in this order

### 1. Recovery-Bench — build this first

**What it is.** Collect failed trajectories from a *weak* model attempting
Terminal-Bench tasks, keep only the failures, then drop a *strong* model into
the resulting corrupted state and measure whether it can finish. The corruption
is genuine, not injected: erroneous actions, misleading reasoning still in
history, half-finished artifacts, broken environment state.

**Why it is first — the attribution property.** It is the only benchmark here
whose measured quantity is a *delta between two conditions with the model held
fixed*. Fresh start vs. corrupted start, same model, same tasks. Whatever
differs is the scaffold. Published result: models averaged **26.3% on standard
Terminal-Bench but 11.2% starting from corrupted states — a 57% relative
drop** — and, decisively, **model rankings reorder between the two conditions**.
That reordering proves recovery is a *separable capability* rather than a
rescaling of general competence. This is exactly the failure mode OSA has been
fixing and has no instrument for.

**Cost to build: near zero.** It runs on **Harbor** and **defaults to
Terminal-Bench 2.0** — the infrastructure the terminalbench agent is already
standing up. Custom harness integration is a first-class feature:
`installed:<agent-name>` wraps any Harbor-installed agent and generates a
recovery variant automatically. `pip install -e .`, `git lfs pull`, point it at
OSA. Days, not weeks.

**Honest caveats.** Task count, license text and disk requirements are not
documented in the README — verify before committing. Small-lab project, so
maintenance risk is real (though traces were regenerated as recently as March
2026). 89 inherited tasks is a small n: expect wide intervals and run k≥5.

https://github.com/letta-ai/recovery-bench · https://www.letta.com/blog/recovery-bench

---

### 2. SWE-Bench Pro (public split, 731 tasks)

**What it is.** 1,865 problems / 41 repos, split public (731) / held-out (858)
/ commercial (276). Long-horizon, multi-file, with human-authored requirement
descriptions and interface specs. Same operational shape as SWE-bench — per-task
Docker, no GPU — so most of `bench/swebench` is reusable.

**Why.** Three reasons.

1. **Not saturated.** Top of Scale's standardized leaderboard is **59.1%**
   (GPT-5.4 xHigh via mini-swe-agent, Aug 2026), up from ~23% at release. There
   is headroom to actually move.
2. **It has a built-in contamination control.** The commercial split
   consistently trails the public split by **15–25 points**, and that gap is
   the intended leakage signal.
3. **It is unusually sensitive to context construction** — removing the
   human-written requirement/interface specs dropped Claude Opus 4.1 from
   **22.7% → 8.2%**, a ~3× swing from *what you put in the window alone*. For a
   harness whose known weak points are compaction and prompt assembly, that
   sensitivity is a feature.

**OSA subsystems stressed:** context compaction (multi-file, hours-of-human-work
tasks — this is where the 128k-denominator and prompt-cache issues surface),
long tool runs, long-horizon planning.

**Honest caveats.** You only get the public split; the *more*
contamination-resistant commercial half is partnership-gated, so you can compare
against Scale's published gap but cannot reproduce it. Aggregate Docker size is
**not published** — measure empirically before filling the disk; budget several
hundred GB for 731 enterprise-scale repo images. Local Docker execution is still
a beta flag. And the copyleft-sourcing contamination argument is a *legal
deterrence assumption with no supporting measurement* — treat the held-out split
and the difficulty as the defensible parts.

arXiv:2509.16941 · https://labs.scale.com/leaderboard/swe_bench_pro_public · code MIT

---

### 3. LOCA-bench

**What it is.** Automated, scalable control of environment state to **regulate
agent context length while holding task semantics constant** — context can be
extended in a controlled way, potentially without bound. It explicitly evaluates
agents as *(model × scaffold)* pairs including context-management strategies,
and finds that performance degrades as state grows but **advanced context
management substantially recovers success rate**.

**Why.** This is the only instrument on the list where **our compaction
implementation is the dependent variable**. We can run OSA's compaction against
a null strategy against naive truncation, on identical tasks with the model
held fixed, and read the difference directly. Nothing else isolates that.

**Cost:** low. Open source, no per-task repo containers of the SWE-bench kind,
no GPU. The work is writing the adapter.

**Honest caveat, and it is a real one.** Four months old, single lab, no
leaderboard traction. You get a clean instrument but **no external comparison
points** — it is a debugging tool more than a benchmark. Given the stated goal
is diagnosis rather than a marketing number I think that trade is right, but it
is a judgment call and worth making consciously.

arXiv:2602.07962 · https://github.com/hkust-nlp/LOCA-bench

---

## Cross-cutting: two things to adopt rather than build

**METR's time-horizon fit, as an analysis layer.** Label tasks with human
completion times, run each task ~8 times, fit a two-parameter logistic of
success against log human task duration, and read off the duration at which the
curve crosses 50%. The reason this is the right framing for us: **a harness's
contribution shows up as a change in the curve's *shape*, not just its
position.** Fit the curve for `OSA + model M` and for `mini-swe-agent + model M`
over the same tasks and the model cancels — the difference is entirely ours.
Better still, compaction failures have a distinctive signature: they do not
shift the curve uniformly, they collapse the tail at exactly the task durations
where the context budget runs out. That is a diagnosis, not a score.

Read METR's own limitations before adopting: it measures *serial human labor
replaceable at 50% success*, not how long an agent can work unattended; error
bars have historically been a factor of ~2; alternative baselining conventions
shift results by >25%; and measurements above 16 hours are unreliable with the
current task suite. The cost is human time labels, which is the real build
expense.

https://metr.org/blog/2025-03-19-measuring-ai-ability-to-complete-long-tasks/ ·
https://metr.org/notes/2026-01-22-time-horizon-limitations/

**TRAIL's error taxonomy, as our failure labelling scheme.** 1,056 annotated
agent traces from GAIA and SWE-bench, with categories that explicitly separate
**harness/system errors from reasoning errors from tool-use errors**. That is
the same cut `bench/report/failures.py` makes by hand; adopting TRAIL's
vocabulary would make our buckets comparable to published work.

arXiv:2505.08638 · https://huggingface.co/datasets/PatronusAI/TRAIL

---

## Honourable mentions

- **ClawArena-Team** (arXiv:2606.31174) — 41 multi-turn multimodal
  multi-directory scenarios, 258 evaluation rounds. Deliberately constrains the
  main agent (text-only perception, partial workspace access, fixed local
  subagent pool) **so score differences reflect management skill rather than
  raw model capability**. If FleetView / multi-agent dispatch becomes a
  near-term priority, promote this to #3. Held back only because it is two
  months old.
- **SWE-bench-Live** (Microsoft) — the healthiest contamination-resistant option:
  **+50 newly-verified tasks every month**, now 1,890 tasks / 223 repos, MIT.
  Its RepoLaunch auto-containerisation is what makes monthly refresh cheap. A
  natural *companion* to SWE-Bench Pro rather than an alternative.
- **Long-Horizon-Terminal-Bench** (arXiv:2607.08964, Jul 2026) — 46 tasks with
  **dense subtask-level partial credit**, ~9.9M tokens and ~85 minutes per task.
  Best model **15.2% pass@1**; mean across 15 models **1.7%**. The partial-credit
  grading is exactly what makes failures localisable. Watch for the repo.
- **HANDBOOK.md** (arXiv:2607.25398) — 65 tasks, 20–124 page policy handbooks
  that must be followed across multi-tool work, with the handbook *mutated* per
  task so nothing is memorisable. 824 deterministic grading criteria. A
  compaction failure shows up directly as a specific dropped policy constraint.
  Cheap and deterministic.
- **SWE-bench Multimodal** — 517 instances / 17 JS repos. Its explicit thesis is
  that a low score means *your scaffold was overfit to Python SWE-bench*, which
  is a harness attribution by construction. At release SWE-agent scored 12% and
  the next-best system 6%.

---

## Explicitly do not build

| Benchmark | Why not |
|---|---|
| **MLE-bench** | ~3.3TB dataset, 440GB RAM and an A10 in the reference environment, 24h per competition, ~$3,000 per seed. Our box cannot produce a statistically valid reading, and it would mostly measure ML competence, not harness quality. |
| **RE-Bench** | Designed around an 8×H100 budget, orchestrated through METR's Vivaria, reference solutions password-gated. |
| **SWE-Lancer** | ~14GB per task image and 10–20 min to build each; ~200 images extrapolates toward 1–3TB. Worse, the Playwright E2E grading has **no published flakiness rate**, so some fraction of "failures" is test noise you cannot separate — which destroys the one property we are buying a benchmark for. |
| **Vending-Bench 1/2** | Conceptually the best long-run-coherence eval in existence, and its finding that agent meltdowns are **uncorrelated with context-window exhaustion** is directly relevant to us. But there is **no public harness from Andon Labs** — we would reimplement from the paper and the numbers would be comparable to nobody's. |
| **Aider polyglot** | Self-contained single-file exercises. No context pressure, no long tool runs, no recovery. Adapting it means reimplementing Aider's 2-attempt edit-format loop, at which point it is not the same measurement. |
| **LiveCodeBench / LCB Pro** | Single-shot generation against hidden tests. The harness contributes essentially nothing to the score. Cheap, but cheap and non-diagnostic is still non-diagnostic. |
| **GAIA / GAIA2** | Gated dataset, hosted scoring, and GAIA is saturated (>90%). |
| **OSWorld / WebArena** | Feasible via Docker+KVM, but they stress GUI and browser control, which is not an OSA subsystem. |
| **CORE-bench** | The most locally-feasible thing considered (CPU + Docker, no GPU) and reproducibility work genuinely stresses long tool runs. But 2024-vintage, lightly maintained, and the signal is diluted with "can the agent install R dependencies". Second tier, not top three. |

---

## Summary

| | Setup cost | Diagnostic value | Stresses |
|---|---|---|---|
| **1. Recovery-Bench** | near zero (reuses Harbor/TB2) | **highest** — model held fixed across both arms | recovery, compaction of a bad prior, long-horizon replanning |
| **2. SWE-Bench Pro** | low–moderate (disk, API spend) | high — unsaturated, contamination control, context-sensitive | compaction, long tool runs, prompt assembly |
| **3. LOCA-bench** | low (adapter only) | high but uncalibrated — no external comparison | compaction, in isolation, as the dependent variable |

Whatever we build, it goes through `bench/report` — a harder benchmark produces
a lower score, and a low score has to be trustworthy before it is useful.
