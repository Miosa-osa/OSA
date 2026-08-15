# Beating the field — the ordered list

Every item is scored against a **named competitor number**, because "improve
performance" is not a target and "beat cline's 68.5%" is.

Where we stand, measured, on the only same-model cell that exists
(Terminal-Bench 2.0, GLM-5.2, 89 tasks):

| harness | solve rate |
|---|---|
| cline | **68.5%** |
| opencode | 59.6% |
| pi | 57.3% |
| **OSA** | **55.1%** raw / **56.5%** excluding-with-cause (gate-blocked) |

The two OSA figures are `49/89` and `48/85`. Four of the 89 trials ran against a
**non-conforming task copy** — our local `tasks/terminal-bench-2` carries larger
budgets or memory than the canonical Hub package on `crack-7z-hash`,
`filter-js-from-html`, `gpt2-codegolf` and `query-optimize`, which both
leaderboard contracts forbid and which never appears in `config.json` because it
is baked into the task file. Only `crack-7z-hash` passed, so only it moves the
numerator. Neither figure is admissible against the rows above regardless: those
were produced at `k≥1` under contracts we do not yet meet (`-k 5`, canonical
dataset id). See `docs/research/harbor-framework.md` §9b.

And on the axes the field publishes:

| dimension | OSA | field | gap |
|---|---|---|---|
| solve rate | 55.1% | 68.5% | **−13.4 pp** |
| duplicate calls | 9.4% | 0.7% (codex) | **13x** |
| tool calls / turn | 1.00 | 1.91 (opencode) | **1.9x** |
| input tok / task | 1.82M | 0.71–1.29M | **1.4–2.6x** |
| in:out ratio | 56.1:1 | 56–85:1 | **at the top of the band** |
<!--
  Both token rows re-verified 2026-08-15 and UNCHANGED. `input_tokens_per_task`
  is 161,559,329/89 = 1,815,273.4 and the ratio is 161,559,329/2,878,654 = 56.1.
  Both are already cache-INCLUSIVE, which is the definition the field publishes:
  `report.py` sums uncached + cache_read + cache_write. On this run that fold
  adds nothing, because `ollama/glm-5.2:cloud` reported zero cache tokens on all
  87 telemetry-writing trials. The D7 adapter defect was real but affected only
  what Harbor's own `results.json` reported to external consumers, not these.

  Caveat that does move them, in our favour: 2 of the 89 trials never ran (agent
  boot failed) and contributed 0 tokens to a numerator whose denominator still
  counted them. Over the 87 that ran it is 1,857,004/task.
-->

| effective $/M in | $0.22 | $0.24–0.42 | **better** |
| turns | 78 | 82 (codex) | parity |
| harness fault rate | 3.37% | — | must be 0 |

---

## Tier 1 — closes the solve-rate gap

The only gap that matters. Everything here targets the 13.4 points.

1. **The shallow-turn cluster.** ~43% of model failures are turns that never
   engaged. One species — a completion claimed while a background job is still
   running — is caught at 100% precision (9 of 20 failures, 0 false positives on
   40 solves). **11 of 20 remain undetected and nothing currently finds them.**
   The one that defeats every proxy: `build-pov-ray`, 62 turns at 4.4 s/turn,
   started no background command at all.
2. **`file_transform` in a long run.** Measured 46x–550x less context per edit,
   and the model routes to it — but only verified across 4 short sessions. Its
   whole value is O(1) growth over ~150 turns, which is exactly where our peak
   context hit 201k against codex's 94k on the same task.
3. **The "verify with a program" habit.** Codex answered "is this file
   well-formed" by writing a static analyser and running it 12 times. We read the
   file back 66 times. `file_transform` now provides the mechanism (`count`,
   `assert_balanced`); the habit is not yet in the prompt.
4. **An LSP client.** Codex has one. We do text search where they do symbol
   resolution — a real capability gap on any refactor.

## Tier 2 — efficiency, where the leverage is superlinear

Cost is **quadratic in turns** (`turns x (first+last turn input)/2` predicts
measured total within 5%), so a round-trip saved on a long task is worth far
more than the arithmetic suggests.

5. **Batching — 1.00 vs opencode's 1.91 calls/turn.** No structural block
   exists: `max_response_tokens` is 32,768 at every tier, there is no
   `parallel_tool_calls: false`, and `ToolOrchestrator` already batches
   concurrency-safe calls up to 10. We batch on 5.6% of turns and the split is
   bimodal across runs with no known cause. **The largest unexplained lever left.**
6. **Duplicates at 9.4% vs codex's 0.7%.** Real, unexplained. The windowed
   detector and `file_read` "unchanged" suppression are correctly-built
   backstops that found nothing to catch on the current corpus.
7. **Session-pinned tool profiles.** 2–4k of prefix. Designed, never built.
   Must be pinned once per session — per-turn selection loses ~30x more to cache
   invalidation than it saves.
8. **Native Anthropic conversation caching.** ~16 points of hit rate left on the
   table. Needs a live key to verify; will not ship unmeasured.

## Tier 3 — the instruments must not lie again

Thirteen defects of one shape in a single session, plus seven apparatus defects
and five wrong-field comparisons. The class-level defences matter more than any
instance fix.

9. **Ratchet tests are in place** — bare `function_exported?` baseline 43 and
   cannot grow; every compat provider must resolve the correct billing
   convention; every compat provider must report a reasoning decision. **Extend
   this approach to the remaining shapes**: global-state reads inside per-request
   decisions, `nil`-guard fall-throughs, filters that can only shrink.
10. **Suite nondeterminism at the default seed.** Pre-existing and unchased. It
    undermines every "suite green" claim we make.
11. **Daemon version skew.** The backend survives TUI exit and can be days older
    than the TUI attached to it, with no warning. A whole class of confusing bug
    reports — possibly including the one that started this.

## Tier 4 — benchmark validity

12. Exit-0 driver bug: rate limits are scored as model failures, and Harbor's
    error classifier never fires.
13. Canonical Hub dataset — we run a legacy pin dated 2025-10-31.
14. `__pycache__` uploaded into grading containers.
15. **5 trials per task.** The board protocol. n=1 is a coin flip: we have watched
    a single task flip 4-pass/2-fail with no code change.
16. Twelve documented Harbor adapter deviations. **D1–D7 and D9–D12 are closed**
    (2026-08-15; see `docs/research/harbor-framework.md` §9a, §9b). **D8 — no
    ATIF trajectory export — is the one left**, and it is the one that blocks
    `--upload --public`. Scope: items 1–5 below are ~1 day inside `bench/`, item
    6 is a change in `lib/`.
    1. Read `osa-events.jsonl`, dedupe the twice-emitted `llm_response`, and
       segment into steps on `cost_update` boundaries (OSA emits no explicit
       step markers — this is the only inferred part).
    2. Assemble steps: `streaming_token`→`message`, `thinking_delta`→
       `reasoning_content`, `tool_call`+`tool_result`→`ToolCall`/`Observation`
       (id pairing already matches 21/21 on the sample), `cost_update`→
       `Metrics`.
    3. `Agent(name, version, model_name)` and the user step — both recoverable
       host-side (`self.version()`, `run(instruction=...)`).
    4. Write `<logs_dir>/trajectory.json` and flip `SUPPORTS_ATIF`. That path is
       hardcoded by every consumer, and it is what populates the Hub's
       `trajectory_path` column (`upload/uploader.py:531-556`).
    5. A validation test — `Trajectory(**json)` over the archived runs. Cheap,
       because every ATIF model is `extra="forbid"`.
    6. **The blocker for usefulness, not validity.** `ToolCall.arguments` is a
       required dict; OSA's `tool_call.args` is a *display hint* clipped at 60
       chars (`lib/.../tool_executor.ex:1734-1740` says so in its own comment;
       measured 21/21 calls with `args_bytes > len(args)`). A trajectory built
       today would be schema-valid — `arguments` accepts `{}` — and worthless
       for the trace-export and analysis the flag exists to unlock.

    Not urgent: submissions are closed on both boards. What is worth knowing now
    is that the 2.1 CI's per-rewarded-trial `trajectory_path` check is **not
    locally verifiable** — `tasks/terminal-bench-2-1/` is an empty placeholder,
    and the only citation we hold (§1) quotes the CI's task-count and trial
    minimums, not a trajectory check.
17. TB 2.1 arm — worth **5.6 pp of achievable ceiling** over 2.0 on this machine
    (oracle 86/88 vs 82/89).
18. ~~Recovery-Bench has never completed a run.~~ **Stale — it has.**
    `bench/recoverybench/runs/delta-01/` is a finished two-arm run
    (`finished_at` 2026-08-13T21:19:57Z, zero harness faults in both arms). What
    has never run is the **full 64-task corrupted universe**:
    `results.json:delta.is_full_corrupted_universe = false`, `paired_n = 6`.
    - **The blocker is money and wall-clock, not plumbing.** The 6-task pair cost
      **$42.28 / ~1 h 35 m**; linear to 64 tasks ≈ **$450 / ~17 h** at `-n 2`.
    - **It cannot be run for free.** `bench/recoverybench/run_bench.py` has no
      `--agent` flag at all (contrast the terminalbench runner, which offers
      `osa | oracle | nop`), and the protocol would be meaningless for an oracle
      anyway: corruption is produced by *replaying the weak agent's commands*
      inside `RecoveryOsa.setup()`, a hook a plain `OracleAgent` does not have,
      so both arms would start pristine and the delta would be 0 by
      construction. The one genuinely useful free control — oracle-on-corrupted-
      machine, "is this still solvable after corruption?" — needs a new
      `RecoveryOracle(RecoveryMixin, OracleAgent)` class plus that flag.
    - `upstream/runs/` is **not a baseline**: it is the single
      `claude-haiku-4-5` under terminus-2 trace set used *as the corruption
      source*. The only reference is the published 26.3%→11.2% band.
19. Harbor-Index — 80 tasks, built by the Terminal-Bench authors for
    cross-*agent* comparison. Confirmed never run with OSA (no `results.json`
    under `runs/` carries `dataset_key: harbor-index`). Dataset is downloaded;
    `bench/run-all.sh harbor-index` is wired end to end. **Two things block it
    beyond quota, and both are free to fix:**
    - **Control coverage is 8 of 80.** The clean 8/8 oracle, 0/8 nop at
      `runs/_controls/harbor-index/probe8/` (2026-08-14) covers only the fixed
      cost-probe set in `probeset.py:227-236`, and it is the union of several
      partial imports rather than one sweep. `controls.py gate` treats an
      unmeasured task as a BLOCK, so a full 80-task run would produce no
      quotable rate. Extending the controls costs **nothing** — neither agent
      calls a model.
    - **Judge-task filtering is not wired into `run_bench.py`.** 16 of the 80
      tasks (`hle-`, `omnimath-`, `gaia2-`, `widesearch-`) are graded by an
      LLM-judge ensemble needing a credential at verify time. `controls.py`
      handles this (`gradeable_tasks`, `have_judge_key`); `run_bench.py`
      contains no reference to it, so it would dispatch all 80 and silently
      report on a different denominator.
    - Also note `probeset.py:288-297` records `baseline=None` for harbor-index,
      so the first run establishes the baseline and supports no improvement
      claim. And D6 mattered here: 5 of the 80 tasks declare MCP servers that
      the adapter dropped until this pass.

## Tier 5 — the empty cells

Ten provider x capability gaps, ranked by the sweep that found them: Bedrock
request-side caching; `CacheAttribution` absent from the route it was measured
on; ClaudeCli/CopilotCli usage written to a `:persistent_term` with zero
readers; Ollama images with zero `ImageBudget` coverage; `cap_for/1` hardcoding
two providers; `prompt_caching_enabled?` inverse polarity; dead `:vision` flags;
`FastPath` substring intent matching with no logging; a 4,000-byte threshold
whose sibling was recalibrated; unused Google streaming.

---

## The cheap ladder, before spending anything

The 8-task probe set (`tb-cost-probe-v1`) is oracle-verified, deliberately
4-pass/4-fail, and carries recorded baselines. Paired re-runs on an identical
set detect change far better per dollar than one big sweep.

| step | tasks | answers |
|---|---|---|
| 1 | 8 | does a frontier model change our position at all |
| 2 | 20 | is the effect real or noise |
| 3 | 89 | a number on the leaderboard's axis |

Each step gated on the previous one justifying it.

## The axis nobody is competing on

Terminal-Bench 2.1 publishes cost per row. Codex spent **$2,059** to score
83.15%; Claude Code spent **$553** to score **83.82%**; Cursor CLI spent $134 for
79.33% while reward-hacking 8.99% of trials. **A 15x cost spread inside 5 points
of score, and every row is optimised for rank.**

After tonight's caching, prefix and per-edit work, cost-per-solved-task is the
axis where OSA is strongest — and the one the field publishes but does not
compete on. Reporting solve rate *and* cost with controls attached would be
first.
