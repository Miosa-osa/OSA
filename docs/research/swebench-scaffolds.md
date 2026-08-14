# SWE-bench scaffolds: what actually moves the number, and what OSA should change

Research pass + engineering translation, 2026-08-14.

The question is not "should we verify". Both benchmarks report zero harness faults, and
verification already happens: 16 of 17 failed instances ran tests, as did 22 of 23
resolved ones (`bench/FINDINGS.md`). The question is what strong scaffolds do that turns
a *failed* verification into a *fix*.

This document is in three parts: what we measured on our own runs (new, this pass), what
the literature actually supports, and a ranked list of changes with implementation
sketches. Evidence strength is labelled throughout and the weak claims are marked weak.

---

## Part 0 — What we measured on our own runs (new)

Two measurements were taken this pass against
`bench/swebench/runs/osa-hard40-airgap` (n=40, 23 resolved, 17 failed) by replaying
`logs/*.events.jsonl` and reconstructing the tool sequence per instance.

### 0.1 The failure is not "ran out of road"

**No failed instance hit a blocking limit.** `hit_blocking_limit=false` on all 17;
`max_turns` was 60 and the failures used 13–61 turns (one outlier at 237, flagged
`stalled`). Every failure stopped **voluntarily, with budget remaining**.

This is the single most important fact for ranking. The agent is not being cut off. It
decides it is done while the target test is still red. That makes the *submission
decision* the lever, not the budget, not the context window, and not the tooling.

### 0.2 The final edit is almost never re-checked

Counting, per instance, whether any successful `shell_execute` matching a build/test
pattern (or invoking `./run_tests.sh`) ran **after the last successful source write**:

| cohort | n (with a patch) | ran any test/build after the last edit | of those, it **passed** |
|---|---:|---:|---:|
| failed | 15 | **3 (20%)** | 3 / 3 |
| resolved | 23 | **7 (30%)** | 7 / 7 |

(2 further failures produced no patch at all — `django__django-13513`,
`sympy__sympy-13877`.)

The two right-hand columns are identical, and that sharpens the diagnosis
considerably. **Nobody ends on a red test run.** In every case where a test or build
was executed after the final source edit, it exited 0. So the standing framing —
"tests run, target test still failing, agent submits anyway" — is not quite what the
trajectories show. What they show is that in 12 of 15 failures **no check of any kind
was run after the final edit**, so the agent never saw a red result to ignore. The
patch it submitted simply was never executed in the state it was submitted in.

That matters for design: a gate that fires on "your last check was red" would catch
**zero** of these. The gate has to fire on "your last edit is unchecked" and then
**force the check to run**, which is why R3 below runs the target check itself rather
than only re-prompting.

Two further conclusions, and the second one is the honest caveat:

1. **`bench/FINDINGS.md`'s "16 of 17 ran tests" is true but reads better than reality.**
   They ran tests, then edited again, and never re-ran. This is precisely the condition
   `VerificationGate` exists to catch, so its predicate
   `VerificationEvidence.pending_files/1 != []` should have been true at turn end on the
   large majority of these runs.

2. **It is not discriminative on its own.** 20% vs 30% on n=15/23 is nowhere near
   significant, and the behaviour is near-universal in *both* cohorts. Many final edits
   are cosmetic. So do **not** expect a large gain from merely forcing a re-run of the
   test. The gain has to come from forcing the *outcome* (the target check passes), not
   the *action* (a check happens). This distinction is the whole design constraint below,
   and it is independently supported by the literature (§1.2).

### 0.3 Whether the gate fires is still unobservable on the bench path

`verification_gate_triggered` appears **zero** times in the 40 airgap logs — but so does
every other interesting `system_event`. The only `system_event`s forwarded over the SSE
transport the bench consumes are `hook_run` (19,533), `session_title`, `task_created`,
`task_updated`, `hook_blocked`, `error`. `bench/scaffold/README.md` reports the same
absence on the Pro baseline (0 in 11,771 frames).

**Absence of the event is not evidence the gate did not fire.** It is evidence the event
is not forwarded on this path. `lib/optimal_system_agent/events/tui_forwarder.ex:40`
carries it for the TUI; the HTTP/SSE path does not. Until that is fixed, no change to the
gate can be evaluated. That is why observability is ranked as a prerequisite, not a nice-to-have.

---

## Part 1 — What the literature supports

### 1.1 The floor: how little scaffolding is actually required

`mini-swe-agent` is ~100 lines, has **one** tool (`bash`), no retrieval index, no
verifier, no reranker, no submission gate, and scores **>74% on SWE-bench Verified**
(`SWE-agent/mini-swe-agent`). Its entire SWE-bench config is a single YAML file. Its
"scaffold" for the edit-verify loop is four lines of prompt:

```
1. Analyze the codebase by finding and reading relevant files
2. Create a script to reproduce the issue
3. Edit the source code to resolve the issue
4. Verify your fix works by running your script again
5. Test edge cases to ensure your fix is robust
```

`step_limit: 250`, `cost_limit: $3`, and a two-step submission ritual (`git diff > patch.txt`,
inspect it, then an exact echo command) that is **ceremonial, not enforced** — nothing
checks the patch before accepting it.

This bounds everything below. Any proposal that costs more than a few hundred lines has
to beat a 100-line baseline that is already at 74%. It also means the reported headroom
for scaffolding on **Verified** is small; the interesting headroom is on **Pro**.

**Evidence: strong** (public code, widely reproduced).

### 1.2 Submission gating is the highest-evidence lever

**ECLoop** ("Preventing Premature Commitment in Coding Agents with an Evidence-Conditioned
Execution Layer", arXiv 2607.28815) interposes between the agent and the repo. It compiles
per-task *evidence conditions* from the issue plus repo structure (AST traversal, call
graph) once per task, then **gates commitment actions** — source edits and final patch
submission — whose action-specific evidence gap is nonempty, returning the unsatisfied
conditions as guidance. Information-gathering actions are never gated. Hold budget: up to
**three** holds per commitment target.

| base agent | model | baseline | +ECLoop | delta |
|---|---|---:|---:|---:|
| mini-swe-agent v2 | GPT-5-mini | 56.2% | 68.0% | **+11.8pp** |
| mini-swe-agent v2 | MiniMax-M2.5 | 75.8% | 80.6% | +4.8pp |
| Codex CLI | GPT-5-mini | 40.4% | 50.8% | **+10.4pp** |
| Codex CLI | MiniMax-M2.5 | 74.8% | 79.8% | +5.0pp |

SWE-bench Verified, 500 instances. It *reduced* tokens 1.4–12.1% and cost 1.5–10.2% —
gating is cheaper than letting the agent flail.

**Evidence: moderate.** The mechanism is exactly our failure shape and the effect is
large. But: single run, **no confidence intervals, no seeds**, self-reported. Note the
gain **halves** with the stronger model (11.8 → 4.8). Our provider is a strong model, so
plan for the +5pp end of that range, not the +12pp end.

Corroboration from a different angle: the Qwen Code CLI harness-evolution study
(arXiv 2607.03691, 35 sequential releases, model held fixed, 50 stratified Verified
tasks) reports that **prompt interventions that add or remove testing change outcomes by
at most 2.6pp**, and concludes that scaffold-level *orchestration* of testing — lint-test
cycles, test-gated retries — is the architecturally relevant variable. This is the sharpest
available warning against "just tell the model to test harder", and it matches our §0.2
result that the *action* is not discriminative.

**XFlow** (arXiv 2606.14790) independently gates submission on a passing check.

### 1.3 Reproduce-first and runtime-grounded diagnosis

**SWE-Doctor** (arXiv 2607.00990) is the strongest published result on the "what happens
after verification fails" question. Three stages: (1) generate multi-faceted bug
reproduction tests (BRTs) via a generate–execute–refine loop, screening out BRTs that fail
for environment reasons rather than for the bug; (2) run each BRT **under a debugger**
(PDB/Delve), collecting suspected fault locations, failure symptoms, propagation paths and
runtime values into a structured diagnosis record, rejecting any diagnosis not grounded in
actual execution; (3) hand the requirements + localisation + diagnosis to mini-SWE-agent
with a completeness check before submission.

| | Verified | Pro |
|---|---:|---:|
| mini-swe-agent | 73.7% | 50.5% |
| live-SWE-agent | 71.8% | 51.4% |
| **SWE-Doctor** | **75.7%** | **59.4%** |

Ablation on a 50-instance Pro subset (GPT-5.4-mini): full 56.0%, drop Stage 1 46–48%,
drop Stage 2 (runtime diagnosis) 48.0%, mini baseline 44.0%. The Stage-2 split by issue
type is the most telling number: on fail-to-pass issues Stage 2 buys nothing (60.0% vs
60.0%), but on **fail-to-fail** issues it buys 53.1% vs 40.6%. Runtime evidence matters
exactly where the agent is stuck.

Stability (5 runs, 50 Pro instances): SWE-Doctor 54.0% ±2.0, mini 42.4% ±2.2,
live 45.2% ±3.4. Pass@5: 70.0 / 58.0 / 62.0. All@5: 40.0 / 24.0 / 24.0.

**Evidence: mixed, and the split matters.**
- On **Pro**, +8.9pp over mini against a 2.0–2.2pp SD: **real**.
- On **Verified**, +2.0pp against that same SD: **within noise**. Do not cite it.
- The paper reports no per-round marginal returns and does not address PASS_TO_PASS at all.

The useful, cheap version of this finding: **BRTs help even when they fail to reproduce**,
because the execution trace is diagnostic regardless. That is a much lower bar than
"generate a correct reproduction test".

### 1.4 How many repair rounds

"How Many Tries Does It Take?" (arXiv 2604.10508): round 1 gives the largest gain
(+9.8pp Gemini 2.5 Pro, +9.1 Scout/Flash, +2.4 Qwen3), round 2 is "still meaningful but
reduced", rounds 3–4 give minimal or zero gain. **Two repair rounds capture 76–95% of
achievable gains** across seven models. Error specificity matters: assertion errors repair
at ~45%, name errors at ~77%.

**Evidence: weak transfer.** This is HumanEval and MBPP-Sanitized — single-function
generation, not repo-scale repair. Cite it only as a sanity check that
`@max_reprompts 2` is a defensible number, not as justification for anything.
A repo-scale corroboration exists but is vaguer: interaction-round scaling shows the
30→45 improvement is much larger than 45→75.

### 1.5 Localisation — the thing we should *not* build

Three independent results, and they point the same way:

**SWE-Explore** (arXiv 2606.07297) measures exploration quality at line level. Retrieval
strategy comparison at K=5 regions:

| strategy | HitFile | Recall | F1 |
|---|---:|---:|---:|
| BM25 | 0.079 | 0.021 | 0.024 |
| TF-IDF | 0.140 | 0.049 | 0.054 |
| Dense (Potion) | 0.088 | 0.025 | 0.026 |
| **agentic agents** | **0.640–0.682** | 0.140–0.194 | 0.182–0.223 |

"Agentic exploration is a clear step above non-agentic retrieval." Context *efficiency*
(relevant AND compact) correlates with downstream repair at r=0.950; file hit rate at
r=0.925. Redundant context does little damage once the essential evidence is present;
**missing** core evidence is the dominant failure. The residual bottleneck is line-level,
not file-level: 65% file hit rate against ~15% line recall.

**SWE-bench Pro's own failure taxonomy** (arXiv 2509.16941) settles it for strong models:

| failure mode | Claude Opus 4.1 | GPT-5 (high) |
|---|---:|---:|
| Wrong Solution | **50.3%** | 39.5% |
| Syntax Error | 31.3% | 29.3% |
| Tool-Use Error | 10.0% | 17.7% |
| **Incorrect File** | **4.9%** | 8.8% |

Localisation is ~5% of the failure mass. Half the failures are *wrong solutions in the
right place*.

**Our own measurement agrees, decisively.** `bench/scaffold/README.md`: across 963 baseline
tool calls on 12 Pro instances, `semantic_search` (154 tok/request), `codebase_explore`
(183), and `code_symbols` (166) were called **zero times**. The model localises with
`file_grep` (ripgrep) and `shell_execute` and ignores everything else. And OSA's
`semantic_search` is not code search at all — it queries OSA's own memory/learning stores
and never touches the working directory
(`lib/optimal_system_agent/tools/builtins/semantic_search.ex`).

One counter-current, correctly scoped: BM25 overtakes agentic search above ~10M corpus
tokens (arXiv 2607.26497), with a ~20-point margin at full scale. SWE-bench repos are far
below that crossover. Irrelevant to us today; relevant if OSA ever targets monorepos.

**Conclusion: building a symbol index, embeddings, or a repo map is the highest-effort,
lowest-expected-value item on this list. Do not do it.** Deleting the unused
localisation tools' schemas is worth more than improving them.

### 1.6 Regression avoidance

PASS_TO_PASS tests pass both before and after the gold patch and exist to catch collateral
damage. The scale of the problem is large in general — one CI-oriented study finds most
models introduce regressions on **>75%** of tasks, with a zero-regression rate below 0.25
for the majority of models.

**TestPrune** ("Can Old Tests Do New Tricks for Resolving SWE Issues?", arXiv 2510.18270)
is the concrete technique: LLM predicts suspicious functions from the issue, LLM picks the
top 10 candidate test files by imports and context, then a coverage-based greedy algorithm
selects the minimal test set exercising those functions. It never consults
FAIL_TO_PASS/PASS_TO_PASS.

| agent | benchmark | baseline | +TestPrune | absolute |
|---|---|---:|---:|---:|
| Agentless (Claude) | Verified | 254/500 | 278/500 | **+4.8pp** |
| Agentless (GPT-4o) | Verified | 194/500 | 219/500 | +5.0pp |
| Trae Agent | Verified | 325/500 | 351/500 | **+5.2pp** |
| SWE-Agent | Lite | 170 | 186 | +5.3pp |

>1000× reduction in suite size, 27× runtime; ~9 tests averaging 52s against ~23 minutes.
$0.02–0.05 per instance in model overhead.

**Evidence: moderate-good** — consistent direction across four agent/model pairs, which is
better than any single-run number here. But: **our own regression bucket is small.** On
the airgap run, `regression_pass_to_pass_broke` is 2 of 17 and
`fix_incomplete_and_regressed` is 1 more. TestPrune's headline gain must therefore come
mostly from the *reproduction/validation* half of what it does, not the regression half —
and for us the addressable bucket is ~3/17, capping the ceiling at ~7pp even at 100% fix
rate.

### 1.7 Test-time compute: best-of-k

The official checklist (`swe-bench/experiments/checklist.md`) is explicit:
**pass@k is prohibited** as a headline; **best@k is permitted** — a system may attempt an
instance multiple times provided (a) it does not use SWE-bench evaluation and (b) a
distinct module of the system, using **no** PASS_TO_PASS/FAIL_TO_PASS/`hints_text`
information, selects which attempt to submit. So this is a legitimate lever reported as
pass@1.

The headroom for us is enormous and **measured**: `bench/FINDINGS.md` #8 records that
**9 of 40 instances flipped between two runs of the same set**. SWE-Doctor's own stability
table shows the same structure — pass@5 70.0% against mean 54.0%, and all@5 only 40.0%.
Roughly a quarter of instances are coin-flips.

The catch is the selector. Execution-free LLM critics and "agentic rubrics" recover part
of the pass@1→pass@n gap but do not execute tests, and reported numbers are pass@16-style
(40.6% Qwen3-32B, 54.2% Qwen3-Coder-30B-A3B) rather than best-of-k-as-pass@1 deltas we can
lift. SWE-Replay (arXiv 2601.22129) reduces the cost by checkpoint-and-rollback rather than
independent full rollouts, but its reported numbers were not extractable in usable detail.

**Evidence: strong that the headroom exists (our own 9/40); weak that any published
selector captures it.** An *execution-grounded* selector — pick the candidate patch whose
self-written reproduction goes green and whose neighbouring tests stay green — is legal,
obvious, and unpublished at the numbers we'd want. Cost is the blocker: k× $46/run.

### 1.8 Context construction

The largest single published effect in this whole document, and it is about **what is in
the prompt**, not what the agent does:

| SWE-bench Pro | GPT-5 (high) | Claude Opus 4.1 |
|---|---:|---:|
| problem statement + requirements + interface | 25.9% | **22.7%** |
| problem statement only | 8.40% | **8.20%** |

~64–68% relative degradation. `requirements` is a prose spec of intended behaviour grounded
in the unit tests; `interface` names the functions/methods the tests expect, with
signatures and file paths, to prevent false negatives from valid-but-unexpected APIs.

**Evidence: strong** (the benchmark authors' own ablation, on the full public set).

For OSA there is nothing to *do* here on the bench — `bench/swebenchpro/runners.py:110`
already puts both in the prompt in `context_mode="full"`, which is the leaderboard setting,
and `no-spec` is a first-class run mode. The transferable lesson is for **real users**, who
never have a `requirements`/`interface` block: an issue→requirements extraction step
(SWE-Doctor Stage 1, CodeScout) is trying to synthesise exactly what Pro hands the agent
for free.

### 1.9 The honesty caveat that applies to everything above

UTBoost (arXiv 2506.09289, ACL 2025) found **36 task instances with insufficient tests**
and **345 erroneous patches** wrongly marked as passing (176 Lite, 169 Verified).
Re-grading changed **40.9% (18/44) of Lite rankings and 24.4% (11/45) of Verified
rankings**. The leaderboard was never re-issued against the corrected tests.

On top of that, from our own work: upstream's audit finds **109 of 728 Pro tasks
under-specified**, every published Pro image ships the fix commit in `/app/.git` (we strip
it; the leaderboard does not), and the official grader is non-deterministic on
network-dependent tests. And our own noise floor is 9/40 flips.

**Practical rule for this document: treat any single-run claim below ~5pp as unmeasured.**
Our n=12 Pro baseline of 9/12 has a Wilson interval of 46.8%–91.1%.

---

## Part 2 — What OSA already does, technique by technique

| technique | OSA status |
|---|---|
| Agentic search | **Yes, and it is the right choice.** `file_grep` shells out to `rg`; `file_glob` is `Path.wildcard`. |
| Symbol/embedding index | **No, and should stay no** (§1.5). `semantic_search` is a memory-store query, not code search. |
| Reproduce-first | **No.** Neither the bench prompt nor `SYSTEM.md` asks for a reproduction script. mini-swe-agent's prompt does. |
| Runtime-grounded diagnosis (debugger) | **No.** Nothing in OSA drives PDB/Delve. |
| Post-edit checking | **Partial.** `Verify.PostEdit` (`config/config.exs:383-385`) runs formatters + single-file syntax diagnostics (`gofmt -e`, `node --check`, `ruff check`…) and injects them into the same turn's tool result. **No test execution, no cross-file semantics, no language server.** |
| Write-was-verified gate | **Yes, advisory.** `VerificationGate`, `@max_reprompts 2`, called at `react_loop.ex:785`. |
| Goal-level verifier | **Yes, expensive, and blind to tests.** `GoalVerifier` (1874 lines) — LLM triage + up to 3 rounds of N read-only skeptic subagents over `git diff HEAD`. `@skeptic_tools` has no `shell_execute`, so **skeptics cannot run tests**. Active on every bench instance (the runner sets `permission_mode overdrive`). |
| Hard submission gate | **No.** Nothing in OSA blocks completion. VerificationGate steps aside after 2, GoalVerifier after 3, DoomLoop stall is escalate-only under overdrive. The only true blocking seam is a `:stop` hook returning `{:block, _}`, itself capped at `@stop_hook_max_continues 5` (`react_loop.ex:1742`). |
| Regression selection | **No.** Test choice is entirely the model's. |
| Best-of-k | **No.** `--attempts 1`. |
| Context construction | **Yes**, at the bench level (`requirements` + `interface`). Nothing for real users. |
| Repair-round budget | 2 (VerificationGate) / 3 (GoalVerifier) — consistent with §1.4. Not the problem. |

### The four defects found in the gate machinery

These are source-level findings, certain, and they are why the gate cannot do its job
even when it fires. All in
`lib/optimal_system_agent/agent/loop/verification_evidence.ex`.

**D1 — a re-read counts as verification.** `@check_tools` (L46-48) includes `file_read`,
`file_grep`, `file_glob`, `dir_list`, `code_symbols`, `semantic_search`,
`codebase_explore`. `covered_after?/3` (L133-142) marks a file verified if *any*
successful `:check` entry after the write names it. So `file_read` of the file just
edited clears the gate. The gate's own directive text **invites this**:

> "Re-read the edited file with `file_read` to confirm the change landed as intended."

That bullet actively teaches the model the cheapest way to defeat the gate.

**D2 — "a check passed" is not "the check passed".** `build_or_test` (L220-236) is one
predicate covering builds *and* tests. `go build ./...` exiting 0 marks every changed file
verified while the target test is red. This is exactly the measured failure shape.

**D3 — `run_tests.sh` matches nothing.** The bench hands the agent `./run_tests.sh`
(`bench/swebench/workspace.py`, `bench/swebenchpro/runners.py:94`) and describes it as "the
same runner the graders use". None of the eight `@build_test_patterns` regexes match it,
and its argument is a *test* id, not the edited file's basename — so both legs of
`covered_after?` fail. In this case the gate errs safe (it fires), but the ledger is
recording the harness's own test runner as "not a test", which is wrong and will bite any
outcome-based rewrite.

**D4 — `task_write` is classified as a write.** `write_like?/1` (L164-169) matches any
tool name containing `"write"`. `task_write` is the todo tool. Harmless for
`pending_files` (it extracts no paths) but `last_write_tool/1` reports `task_write` in the
directive, and any future path-free logic will misfire.

And separately, **the exit-status plumbing is correct** and should not be "fixed":
`shell_execute` returns `{:error, "Exit N:\n…"}` on nonzero
(`.../shell_execute/handler.ex:599-600`), which becomes an `"Error: "`-prefixed result, so
`tool_executor.ex:1284-1288` records `success: false`. A failing pytest does **not** count
as a passing check. Good.

---

## Part 3 — Ranked changes

Ranked by expected effect on the measured failure shape (§0), not by interest.

---

### R1 — Forward `verification_gate_triggered` (and friends) on the HTTP/SSE path

**Mechanism.** Add the gate/verifier `system_event`s to the SSE forwarder allowlist the
way `events/tui_forwarder.ex:40` already does for the TUI, so `bench/*/logs/*.events.jsonl`
records them.

**Expected effect on the score: zero.** It is ranked first because **every other item on
this list is unevaluable without it.** We currently cannot distinguish "the gate never
fires" from "the gate fires and the model ignores it" — and those two diagnoses have
opposite fixes. §0.2 says the predicate should be true on ~12 of 15 failures; §0.3 says we
cannot see whether it was.

**Evidence: not applicable** — this is instrumentation.

**Sketch.** One allowlist entry per event in the HTTP forwarder
(`lib/optimal_system_agent/channels/http/api/agent_routes.ex` and the events forwarder it
uses). Add `:verification_gate_triggered`, the `GoalVerifier` verdict event, and
`:reasoning_only_halt`. Then re-run a 12-instance arm and read the counts.

**Risk: near-zero.** More SSE volume; the bench already ingests 19,533 `hook_run` frames
per 40 instances, so the marginal cost is noise.

---

### R2 — Fix the coverage predicate (D1–D4)

**Mechanism.** In `verification_evidence.ex`:

- Split `@check_tools` into `@inspect_tools` (read/grep/glob/list/symbols — record as
  `:inspect`, **never** satisfying coverage) and `@verify_tools` (`shell_execute`, `repl`).
  Only `:verify` entries can cover a write.
- Split `build_or_test_command?/1` into `build_command?/1` and `test_command?/1`, and add
  `run_tests.sh` (plus `./run_tests.sh`, `bash run_tests.sh`) to the test patterns.
- Restrict `write_like?/1` to a real path-bearing write (require `paths != []`), which
  kills the `task_write` misclassification.
- Delete the "re-read the edited file" bullet from the `VerificationGate` directive
  (`verification_gate.ex:127`) — it is an instruction to defeat the gate.

**Expected effect.** On its own, small and unmeasurable — it makes the gate fire *more
often*, and firing produces an advisory re-prompt, which §1.2 says is worth ≤2.6pp. Its
value is that R3 is impossible without it.

**Evidence: certain on the defect, weak on the gain.** D1–D4 are source facts. The gain is
inferred.

**Risk: low, but real.** Tightening coverage makes the gate fire on turns where it
currently does not, spending up to 2 extra model round-trips per turn. Bound it by keeping
`@max_reprompts 2`.

---

### R3 — Make completion conditional on a *passing target check*, not on *a check having happened*

**This is the change I would make first** (R1 and R2 are its prerequisites, and both are
cheap).

**Mechanism.** Today `VerificationGate` asks "did some passing check touch the changed
files?". Change it to ask "**did the check the agent itself nominated as the success
criterion pass, in the current state of the tree?**":

1. When the agent first runs a command classified as `test_command?` (including
   `run_tests.sh`), record it as the session's **target check** — the command string, not
   the outcome.
2. At turn completion, if any source file has been written since the target check last
   ran, or the target check's last run was `success: false`, the turn is **not** complete.
3. Instead of only re-prompting, **run the target check** (the executor already has the
   machinery) and put the actual output in the directive. Then re-prompt with a concrete,
   grounded failure rather than "run one now".
4. Keep the 2-reprompt cap. But when it is exhausted, **record a distinct terminal status**
   (`:completed_unverified`) instead of falling through silently to `finish_turn/2`. That
   status is what makes the effect measurable and is also the honest thing to report to a
   user.

**Insertion point.** A new `cond` branch in `react_loop.ex` between L881 and L898,
immediately before `true -> finish_turn(content, state)` — the same shape as the existing
VerificationGate branch at L785-794. Everything needed is already on `state`: `session_id`,
`working_dir`, `messages`, `iteration`. `GoalVerifier.capture_diff/1`
(`goal_verifier.ex:1753`) already produces a `git diff HEAD` if the directive should carry
one.

For a **no-code** pilot before touching `lib/`, the same policy can be prototyped as a
`:stop` hook returning `{:block, reason}` — `react_loop.ex:1744-1793` injects
`"[Stop hook feedback — do not stop yet]\n" <> reason` and re-enters `run(state)`, bounded
at `@stop_hook_max_continues 5`. The hook payload lacks `working_dir`, so it must resolve
cwd itself. **This is the cheapest possible experiment** and it needs no `lib/` change at
all, which matters given the constraints on this repo.

**Expected effect.** This is ECLoop's mechanism applied to our exact failure shape. ECLoop
reports +11.8pp / +10.4pp on weak models and **+4.8pp / +5.0pp on a strong model**. Our
provider is strong, so **plan for ~+5pp**, i.e. roughly 2 instances on a 40-instance arm —
which our own 9/40 noise floor **cannot resolve**. Say that out loud now rather than after
the run: this needs paired arms (`bench/scaffold/paired.py`, exact McNemar on discordant
pairs) and probably a larger n than we have ever run.

Supporting evidence from our own data, which is the strongest part of the case: **no failed
instance hit a limit** (§0.1) — every one of them had budget to keep going and chose to
stop. A gate is the only mechanism that converts unused budget into another repair round.

**Evidence: moderate.** Strong mechanism match, strong local diagnosis, but the published
effect is single-run with no CIs and shrinks with model strength.

**Risk: moderate, and needs a named escape hatch.** The failure mode is a gate that cannot
be satisfied — a target check that is red for environmental reasons, or an agent that
churns two extra rounds on every turn for nothing. Mitigations: keep the 2-cap; never gate
when the target check's failure output is unchanged between rounds (reuse
`DoomLoop.FailureSignature`); and never gate a turn with no source writes.

---

### R4 — Reproduce-first, as a prompt change plus a nominated target

**Mechanism.** Two parts, and only the first is cheap.

*Cheap half:* add mini-swe-agent's workflow step to the coding instructions —
"create a script that reproduces the issue and fails, before you edit" — and treat that
script as R3's target check. This makes R3's gate meaningful on instances where the agent
never runs the project suite.

*Expensive half:* SWE-Doctor Stage 2 — run the reproduction under PDB/Delve and feed
runtime values back. Nothing in OSA does this.

**Expected effect.** SWE-Doctor: **+8.9pp on Pro**, and on fail-to-fail issues the runtime
half alone is 53.1% vs 40.6%. On **Verified it is +2.0pp against a 2.0pp SD — within
noise, do not cite it.** Note also that the *prompt* half alone is close to what the
harness-evolution study measured as ≤2.6pp; the gain lives in the execution, not the
instruction.

**Evidence: mixed.** Good on Pro, noise on Verified, and the cheap half is the half with
the weakest support. The most transferable finding is that BRTs help **even when they fail
to reproduce**, because the trace is diagnostic regardless — a low bar worth exploiting.

**Sketch.** Prompt half: a line in the coding section of `SYSTEM_LEAN.md`, plus wiring the
script's path into the verification ledger as the target. Debugger half: a new
`Verify.Runtime` module invoked on a red target check, shelling to `python -m pdb -c`
scripts; this is a real project, not a patch, and should not start until R3 is measured.

**Risk (prompt half): low but non-zero.** Reproduction scripts are new files and must not
leak into the patch. `bench/swebench/runners.py:136-181` strips test-patch files, and
`run_tests.sh` is gitignored, but an agent-authored `repro.py` at repo root **would** land
in `git add -A`. Verify the strip predicate before shipping this — `bench/FINDINGS.md`
records that a bad strip predicate previously made 19 of 500 instances unwinnable.

---

### R5 — Coverage-selected regression check before completion

**Mechanism.** TestPrune, minus the LLM: at completion, map the changed files to the test
files that import or cover them (ripgrep on import statements is enough for a first cut),
run that set, and require it green. Never touch PASS_TO_PASS.

**Expected effect.** TestPrune reports +4.8 to +5.3pp absolute across four agent/model
pairs — the most *consistent* direction in this document. **But our addressable bucket is
small**: 2 of 17 failures are `regression_pass_to_pass_broke` and 1 more is
`fix_incomplete_and_regressed`. Even a perfect fix caps at ~3/17 ≈ 7pp, and realistically
far less. TestPrune's headline gain evidently comes mostly from its validation half, which
R3 already covers.

**Evidence: moderate-good in the literature, weak for our failure distribution.**

**Sketch.** A `Verify.Regression` module that, given `VerificationEvidence` changed paths,
greps for `import <module>` / `from <module>` under test dirs, takes the top N, and runs
them through the same shell path. Feeds R3's gate as a second condition.

**Risk: moderate.** Runtime. TestPrune's minimised suites average 52s against ~23 min for
a full suite; a naive import-grep selection could easily pick a slow set and eat the
30-minute agent timeout.

---

### R6 — Best-of-k with an execution-grounded selector

**Mechanism.** Run k attempts per instance. Select with a module that uses **only**
non-oracle signals: does the agent's own reproduction script now pass; do the
coverage-selected neighbouring tests still pass; is the diff minimal and syntactically
clean. Report as pass@1. This is explicitly permitted —
`swe-bench/experiments/checklist.md` prohibits pass@k as a headline but allows best@k
provided the selector uses no SWE-bench evaluation and no
PASS_TO_PASS/FAIL_TO_PASS/`hints_text`.

**Expected effect: potentially the largest single number on this list.** Our own
`bench/FINDINGS.md` #8 measured **9 of 40 instances flipping between two identical runs**
— roughly a quarter of instances are coin-flips, and a perfect selector would convert most
of that variance into resolutions. SWE-Doctor's stability table shows the same shape
(pass@5 70.0% vs mean 54.0%).

**Evidence: strong that the headroom is real** (measured, ours). **Weak that any published
selector captures it** — published verifiers are execution-free rubric critics reported at
pass@16, not as best-of-k-as-pass@1 deltas. An execution-grounded selector is obvious and
legal but unvalidated.

**Risk: cost, and a credibility risk.** k× $46 per 40-instance arm, and the provider quota
already killed the `no-spec` ablation and all of `bench/scaffold` Phase 2. More importantly:
best-of-k improves the *number* without improving the *agent*, and every point it buys is a
point we did not earn by fixing R3. Rank it last of the score-moving items deliberately.
SWE-Replay's checkpoint-and-rollback is the cost mitigation to look at if this is ever
pursued.

---

### R7 — Do not build localisation. Delete instead.

**Mechanism.** No new retrieval. Cut the schemas for the tools the model never calls.

**Evidence: strong, and it is ours.** `semantic_search`, `codebase_explore`, `code_symbols`
were called **zero times in 963 baseline tool calls** while costing 503 tok/request
between them. 19 of 34 active tools were never called at all, costing 7,798 tok/request —
54.2% of the schema budget, 6.7M input tokens, 11.9% of the baseline run's 56.7M.
`delegate` alone is 1,824 tokens and was never called once, while OSA's own steering
actively recommends it. Externally: "Incorrect File" is 4.9% of Opus 4.1's Pro failures,
and agentic grep already beats BM25/dense by ~8× on HitFile at repo scale.

**Blocker.** `bench/scaffold/README.md` establishes that `permissions.deny` removes
*execution* but not the *schema* — `Registry.list_active/0` still emits it. Cutting the
schema needs a code change (`should_defer?/0` is compile-time). `semantic_search` and
`codebase_explore` already set `should_defer?` → true; the rest do not.

**Expected effect on resolve rate: unknown, plausibly zero.** This is a cost change, not a
score change — though a 7.8k-token-per-request prefix cut is worth having on its own, and
§1.5's context-efficiency result (r=0.950) leaves open that a shorter tool list helps
marginally. Do not claim it will.

**Risk: low for OSA-the-benchmark-subject, real for OSA-the-product.** A tool never used on
12 SWE-bench Pro instances may be load-bearing for a real user. Defer schemas, do not
delete tools.

---

### R8 — Issue→requirements extraction, for real users only

**Mechanism.** Before working an underspecified issue, extract a behavioural requirements
list and an expected-interface sketch, and put them in context — synthesising what Pro's
`requirements`/`interface` columns hand the agent for free.

**Expected effect on our benchmark numbers: none.** `bench/swebenchpro/runners.py:110`
already includes both in `context_mode="full"`. Doing this *on top* would be measuring our
own paraphrase.

**Evidence: strong for the underlying effect** (22.7% → 8.2% for Opus 4.1, the benchmark
authors' own full-set ablation) **but it does not transfer to a score we report.** Listed
because it is the largest published effect in this document and the temptation to "apply"
it will recur; the correct reading is that it is already applied.

---

## Summary table

| # | change | expected effect | evidence | risk | effort |
|---|---|---|---|---|---|
| R1 | Forward gate events on SSE | 0 (unblocks all measurement) | n/a | ~0 | hours |
| R2 | Fix coverage predicate D1–D4 | small alone | certain defect, weak gain | low | hours |
| R3 | **Gate completion on a passing target check** | **~+5pp (plan), +5–12pp (published)** | moderate | moderate | days |
| R4 | Reproduce-first (prompt half) | +2.6pp ceiling as prompt; +8.9pp Pro with runtime half | mixed; noise on Verified | low / high | hours / weeks |
| R5 | Coverage-selected regression check | ≤7pp ceiling for our distribution | moderate-good lit, weak fit | moderate | days |
| R6 | Best-of-k, execution-grounded selector | potentially largest | headroom strong, selector weak | cost | days + $ |
| R7 | Delete unused tool schemas | ~0 on score; −7.8k tok/request | strong (ours) | low | days |
| R8 | Issue→requirements extraction | 0 on our numbers | strong but non-transferable | low | — |

## The one change I would make first

**R3 — gate turn completion on a passing target check — piloted as a `:stop` hook, with R1
shipped alongside it so the result is readable.**

The reasoning is our own data, not the literature. Every failed instance stopped
voluntarily with budget left (§0.1). In 12 of 15 failures the submitted patch was never
executed in the state it was submitted in (§0.2). OSA has three separate mechanisms whose
job is to catch this and **not one of them can refuse to finish** — VerificationGate steps
aside after 2, GoalVerifier after 3, DoomLoop is escalate-only under `overdrive`. The
missing piece is not a check; it is a refusal.

Piloting it as a `:stop` hook (`react_loop.ex:1744-1793`) means the first experiment needs
no change to `lib/` at all.

Two things to say before the run, not after:

- **The expected effect is ~+5pp on a strong model, and our noise floor is 9/40 flips.** A
  single 40-instance arm cannot see this. Use `bench/scaffold/paired.py` and its exact
  McNemar read-out, and budget for a repeat arm as the noise control — that arm is not
  optional here, it is the measurement.
- **The published +11.8pp is on GPT-5-mini.** On the strong model in the same paper it was
  +4.8pp. Anyone quoting the larger number for OSA is quoting the wrong row.

---

## Sources

- [mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent) — and its verbatim SWE-bench config, `src/minisweagent/config/benchmarks/swebench.yaml`
- [SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering (NeurIPS 2024)](https://proceedings.neurips.cc/paper_files/paper/2024/file/5a7c947568c1b1328ccc5230172e1e7c-Paper-Conference.pdf)
- [Preventing Premature Commitment in Coding Agents with an Evidence-Conditioned Execution Layer (ECLoop)](https://arxiv.org/html/2607.28815)
- [SWE-Doctor: Guiding Software Engineering Agents with Runtime Diagnosis from Multi-Faceted Bug Reproduction Tests](https://arxiv.org/html/2607.00990v1)
- [Don't Blame the Large Language Model: How Scaffolding Evolution Shapes Coding Agent Quality](https://arxiv.org/abs/2607.03691)
- [How Many Tries Does It Take? Iterative Self-Repair in LLM Code Generation](https://arxiv.org/html/2604.10508v1)
- [SWE-Explore: Benchmarking How Coding Agents Explore Repositories](https://arxiv.org/html/2606.07297v1)
- [SWE-Bench Pro: Can AI Agents Solve Long-Horizon Software Engineering Tasks?](https://arxiv.org/html/2509.16941v2)
- [Can Old Tests Do New Tricks for Resolving SWE Issues? (TestPrune)](https://arxiv.org/html/2510.18270v2)
- [UTBoost: Rigorous Evaluation of Coding Agents on SWE-Bench](https://arxiv.org/abs/2506.09289)
- [Agentic Rubrics as Contextual Verifiers for SWE Agents](https://arxiv.org/pdf/2601.04171)
- [SWE-Replay: Efficient Test-Time Scaling for Software Engineering Agents](https://arxiv.org/pdf/2601.22129)
- [BM25 Wins at Scale: A Scaling Study of Retrieval-Augmented Generation Paradigms](https://arxiv.org/html/2607.26497v2)
- [ORACLE-SWE: Quantifying the Contribution of Oracle Information Signals on SWE Agents](https://arxiv.org/pdf/2604.07789)
- [SWE-bench submission checklist](https://github.com/swe-bench/experiments/blob/main/checklist.md)
- [Most Coding Agents Break 75%+ of Their Own Fixes Over Time (StackSweep / SWE-CI)](https://www.engineerscodex.com/swe-ci-coding-agent-benchmark)
