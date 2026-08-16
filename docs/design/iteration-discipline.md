# Iteration discipline and species 2: the hypothesis is falsified by our own corpus

**Date**: 2026-08-16 · **Corpus**: `bench/terminalbench/runs/osa-tb20-full89-f6981b61`
(89 trials, Terminal-Bench 2.0, `ollama/glm-5.2:cloud`, 49 solved / 34 model failures),
read-only. **Replay tool**: `scripts/iteration_depth.py <run-dir> [--turn-matched]`.

Every claim is **[measured]** (counted from an artefact) or **[inferred]** (a judgement
built on measurements). No benchmark was run. Nothing under `bench/` or `dist/` was
modified.

---

## 0. Answer, up front

The brief's hypothesis was that **mini-swe-agent does not verify better, it iterates** —
and that the nine species-2 failures of `docs/research/failure-taxonomy.md` §2 lose
because they accept one write→test→fix→test cycle where a solver would run four.

**That is false in this corpus, and it is false in the direction that matters.**
**[measured]**

| | species 2 (9) | solves (49) | solves, turn-matched (34) |
|---|---:|---:|---:|
| write→test→fix→test **cycles**, median | **1** | 0 | 0 |
| test runs, median | **4** | 1 | 1 |
| self-authored test runs, median | **4** | 0 | 0 |
| file edits, median | **7** | 2 | 3 |
| external reads, median | **5** | 3 | 2 |
| turns, median | **50** | 24 | 24 |

The nine species-2 episodes are **the most iteration-disciplined episodes in the run**.
They out-iterate the solves on every behavioural axis measured, and they still do so
after the solves are restricted to their own turn band, so this is not a difference in
task length. Three of the nine ran three or more complete red→green→re-test cycles;
`torch-tensor-parallelism`'s tool sequence is literally `EtEtEtREt` — edit, test, edit,
test, edit, test, read, edit, test — and it scored 0.0.

Thirty candidate detectors have now been rejected against these nine: twelve in the
taxonomy §2.4/§2.5, and **eighteen more here**, of which nine are the interventions the
brief proposed, expressed as the gate that would have to fire to demand them. Every one
fires on solved trials. **[measured]**

**Nothing behavioural was shipped.** Two things were: `ToolArgMetrics.assertion_lines/1`
now records the assertion statements of what the model wrote on the `:tool_call` event —
the one fact §2.5 named as missing and unmeasurable (§5) — and the
`abandoned_background` false positive on a solved trial was diagnosed and fixed (§6.1).
Neither gates anything; neither costs the model a turn.

**The honest conclusion is in §6: the residual is a model capability limit, not a
scaffolding gap** — with one precise qualification about what would falsify that.

---

## 1. Method, and the field discipline behind it

`scripts/iteration_depth.py` renders each trial's `agent/osa-events.jsonl` into an ordered
tool timeline. Three rules matter, because two of them were the cause of retracted
findings in earlier passes:

1. **Command text comes from `command_output_delta.command`**, the full unclipped
   command, taken once per `tool_call_id`. `tool_call.args` is a 60-character display
   hint (`Loop.ToolHint`) and has produced three retracted findings; it is never read for
   content here.
2. **`tool_call` is de-duplicated by `tool_call_id`.** The event is emitted twice per call
   on some routes; a naive count doubles every behavioural quantity.
3. **Authorship includes shell-side writes.** A path becomes "ours" when a write tool
   produced it *or* when a command redirected into it (`>`, `>>`, `tee`). Several tests in
   this corpus are written by heredoc — `dna-assembly` performs 5 write-tool edits against
   16 `write_ops` in telemetry — and a measurement that only counts write tools reads
   those tests as **external**, which would have manufactured exactly the anchoring signal
   this document exists to test. **[measured]**

A **cycle** is one completed `test-run → edit → test-run`. Two cycles means the fix was
re-tested after a subsequent change — precisely what a "require a second cycle" gate would
demand.

---

## 2. The discriminator exists. It points the wrong way.

Cycle count separates the two groups cleanly, and backwards. **[measured]**

```
cycles   0    1    2    3    4    5
SP2 (9)  2    3    1    1    1    1
SOL(49) 30    9    5    4    1    -
```

61% of solved trials completed **zero** cycles. 78% of species-2 failures completed at
least one; 44% completed two or more. Of the eleven trials in the whole run with two or
more cycles that never ran an external checker, **four are species-2 failures, six are
solves and one is another failure** — the shape is more common among failures and still
overwhelmingly present among correct work.

The paired comparison the taxonomy built the anchoring hypothesis on tells the same story
once cycles are counted: `dna-insert` (**solved**) ran **one** cycle; `dna-assembly`
(**failed**) ran **three**. **[measured]**

### 2.1 The motivating example falsifies itself

The brief's measured contrast is `cancel-async-tasks`: OSA failing in 13 turns / 106 s
against mini-swe-agent solving in 56 turns / 351 s. OSA has attempted that task **13 times**
across the runs on disk. **[measured]**

| outcome | turn counts |
|---|---|
| **solved** (6) | 7, 10, 13, 24, 31, 31 |
| **failed** (6) | 2, 17, 19, 22, 24, 31 |

(The thirteenth, `bootcheck-9203eb62`, wrote no telemetry and is not evidence either way.)

In the reference run OSA **solved `cancel-async-tasks` in 7 turns and 94 seconds** — an
eighth of mini-swe-agent's turn count on the same task. It has also failed it at 31 turns,
twice. **Turn count does not separate solve from failure on the single task the
iterate-more hypothesis was built from.** **[measured]** The comparison against
mini-swe-agent was a comparison of two samples from overlapping distributions.

---

## 3. The nine gates, and why each is a net loss

Acceptance rule, inherited verbatim from `scripts/failure_species.py`:

> A detector must fire on at least one failure and on **zero** solved trials.

All figures **[measured]**, `--turn-matched` figures in parentheses (solves restricted to
the species-2 turn band [13, 62], n=34).

| intervention, as the gate that would demand it | SP2 /9 | other fails /29 | **solves /49 (34)** | verdict |
|---|---:|---:|---:|---|
| **require a second cycle** (`cycles < 2`) | 5 | 28 | **39 (28)** | rejected |
| require any cycle (`cycles < 1`) | 2 | 24 | **30 (21)** | rejected |
| **require an unauthored reference** (`ext_test_runs == 0`) | 7 | 26 | **39 (27)** | rejected |
| self-tested but never externally | 6 | 10 | **16 (12)** | rejected |
| self-tested ≥3×, never externally | 5 | 4 | **7 (4)** | rejected |
| fire on over-iteration (`cycles >= 2`) | 4 | 1 | **10 (6)** | rejected |
| over-iterated on its own oracle | 4 | 1 | **6 (3)** | rejected |
| consulted nothing external at all | 0 | 4 | **6 (4)** | rejected |
| fix never re-tested after last edit | **0** | 2 | 0 | degenerate — fires on no species-2 trial |

Two rows deserve the emphasis:

**"Require a second cycle" would fire on 39 of 49 solved trials.** The adequacy gate is
measured at ~31% of tokens on the tasks it fires on, for zero additional
model-attributable solves; a gate with the same profile firing on 80% of correct episodes
is not a marginal cost, it is the largest single regression available in this area.
`f0b88f85` turned one pass into a 0.0 by re-aiming a directive; this would put a pushback
in front of `regex-log` (3 turns, solved), `prove-plus-comm` (5 turns, solved) and
`log-summary-date-ranges` (7 turns, solved) — episodes that were right, quickly, on the
first try. **[inferred, from measured firing counts]**

**"Fix never re-tested" fires on zero of the nine.** This is the sharpest single number in
the document. Every species-2 episode that ran a test ran it again after its last edit.
They did not stop early, they did not skip the re-run, they did not accept a stale green.
**Whatever is wrong with these nine, it is not that the loop terminated too soon.**
**[measured]**

---

## 4. What the transcripts say instead

Reading the nine sequences beside their instructions, the shared property is not a missing
step. It is that **the loop was pointed at a proposition the agent had authored, and every
additional turn spent in that loop reinforced the wrong proposition rather than testing
it.** **[inferred]**

`torch-tensor-parallelism` ran four cycles against a test that performed the all-gather
the module owed. Four cycles made that test greener, not truer.
`model-extraction-relu-logits` ran a genuine, discriminating corruption experiment —
inject five spurious rows, watch the test go red, regenerate, watch it go green — measuring
precision on an axis where the verifier measures recall. The experiment was well-designed;
the axis was wrong, and no number of repetitions of a well-designed experiment on the wrong
axis converges on the right one.

This is why iteration cannot be the lever. **Iteration amplifies whatever proposition the
loop is anchored to.** On an episode anchored correctly it converges; on an episode
anchored to a self-authored misreading it manufactures more confident, more
self-consistent, more thoroughly re-tested wrong evidence — which is exactly the reported
symptom ("*Verified: matches exactly in every case*", "*ALL TESTS PASSED*"). **[inferred]**

The corollary is uncomfortable and worth stating plainly: for these nine, **an intervention
that bought more turns would have made the final answer more wrong, not less.**

---

## 5. What was shipped, and why only this

Nothing that gates, nudges, re-prompts or spends a turn. One thing, and it is an
instrument.

`docs/research/failure-taxonomy.md` §2.5 records a hard artefact limit:

> OSA's event log stores a `file_write`'s path but not its content, and `tool_call.args`
> is clipped at 60 bytes. No replay over this run can compare what a test *asserted*
> against what the task *required*, which is the only comparison that separates these nine
> from the solves. A content-based detector is not merely unproven here — it is
> unmeasurable from these artefacts.

Thirty rejected detectors are thirty *shape* proxies standing in for that one missing
content. `ToolArgMetrics.assertion_lines/1` records the content:

- reads `"content"` (`file_write`, `file_transform`) and `"new_string"` (`file_edit`,
  `multi_file_edit`) — the two keys through which every assertion OSA has written reached
  disk;
- keeps lines carrying an assertion form across the languages this corpus tests in
  (Python/C/Rust/JS `assert*`, googletest `EXPECT_`/`ASSERT_`, jest `expect(`, Go
  `t.Error`/`t.Fatal`, testify `require.`), whitespace-normalised so the same assertion at
  two nesting depths compares equal across trials;
- caps at 12 lines × 240 chars per call, scans at most 256 KB;
- returns `nil` — not `[]` — when the call carried none, so the event shape is unchanged
  for the ~90% of calls that are not writes;
- rides on `:tool_call` as `assertions`, alongside `args_bytes`/`args_hash`, which exist
  for exactly this class of reason.

**Ship criteria, against the three the brief set:**

| criterion | status |
|---|---|
| does not fire on solves | **structurally cannot** — it is not a detector; it emits a field and nothing reads it to decide anything. `scripts/failure_species.py bench/terminalbench/runs/osa-tb20-full89-f6981b61` re-run after the change: *17 trials matched a species; 0 detector hits landed on a SOLVED trial* **[measured]** |
| costs no turns on tasks already right | **zero** — no directive, no re-prompt, no counter. The model's context is unchanged; the field goes to the event stream only |
| observable, with a kill switch | the field is on every write's `:tool_call` event in `agent/osa-events.jsonl`. `OSA_ASSERTION_CAPTURE=0` (or `:assertion_capture` in app env) removes it |

Cost on the emitting side: one regex pass over an argument the process is about to write to
disk. **Turn cost of everything shipped in this session: 0.** **[measured — there is no
code path that can add a turn]**

**It is an instrument, not a fix.** It does not make any current episode more likely to
succeed. What it buys is that the next species-2 question — "which sentence of the task
does each assertion correspond to?" — becomes answerable by reading a log instead of by
inventing a thirty-first proxy.

---

## 6. The honest conclusion

**The remaining species-2 gap is a model capability limit, and harness scaffolding is the
wrong place to spend on it.** **[inferred, from the measurements above]**

The argument, in order:

1. The failures are **not** under-verified. They run more tests, more cycles and more edits
   than the solves, and all nine re-ran their test after their last fix. **[measured]**
2. The failures are **not** unanchored. Eight of nine consulted external material before
   their first edit — as did 47 of 49 solves, which is why anchoring carries no signal
   either way. **[measured]** `dna-assembly` installed and calibrated the very tool the
   instruction named, and still lost on a requirement stated only in prose.
3. Every observable proxy for "the test measures the right thing" has now been rejected:
   30 candidates, spanning final-response text, oracle provenance, artefact naming,
   iteration depth, cycle structure and ordering. They are rejected for the same structural
   reason each time — **the solves do the same thing** — and that reason does not weaken
   with a 31st attempt. **[measured]**
4. The one comparison that would separate the groups requires reading the task statement
   and the assertion and judging whether they express the same proposition. That is a
   comprehension act. A harness can make the artefacts available; it cannot perform the
   comparison on the model's behalf without already knowing the answer. **[inferred]**

### 6.1 The `abandoned_background` false positive does not extend the argument

While this was being written, `abandoned_background` — the shipped detector with the best
record — fired on a **solved** trial for the first time (`rstan-to-pystan`,
`runs/osa-tb20-full89-9b57ee7d`). The question raised was whether that makes it the
thirteenth rejected candidate, and whether analytical detection is therefore dead as a
class. **It does not, and it is not.** Diagnosis and fix are in
`docs/research/failure-taxonomy.md` §1a; the finding in one line:

**The job had finished. Only its event was missing.** **[measured]** The completion
broadcast is suppressed when a `bash_output` poll wins the documented check-and-set race,
so a ledger built from started-minus-completed strands a job that has ended. The runtime's
own `running_count` — carried on both background events — reported `1` at the next job's
start and `0` at its completion, and the eight foreground commands in between successfully
used what the "still-running" install had produced. The rule was right; the replay's
notion of "still running" was wrong. Reconciling the ledger against `running_count` removes
the false positive, preserves all 12 true positives of the reference run, and leaves
**every run on disk at zero solved-trial hits**. **[measured]**

Two consequences for this document's argument:

1. **Clause 0 of the verification gate never misfired.** It queries
   `BackgroundManager.list()` for live `:running` snapshots rather than replaying events.
   Across both 89-task runs, all 77 `verification_gate_triggered` events carry
   `inadequate_test`, `unchecked_write` or `failing_check`; `unobserved_background` fired
   **zero** times. **[measured]** No completion was blocked, and no turns were spent.
2. **It is a different class of thing from the thirty rejected candidates.** Those are
   *proxies* — "the final message claims a green test", "the oracle was self-authored",
   "fewer than two cycles" — and they are rejected because **solves exhibit the same
   shape**, which no amount of implementation care repairs.
   `abandoned_background` tests a **directly observable fact**: is a process this session
   started still alive. One consumer of that fact read it through a lossy reconstruction
   and one read it live; the lossy one was repaired. A fact whose *observation* can be
   fixed is not evidence about a proxy whose *premise* is false.

So the conclusion is unchanged and, if anything, sharper: observable facts about the
session remain detectable and worth detecting; **whether an assertion means what the task
meant is not an observable fact about the session**, and that is the whole of species 2.

**What would falsify this and reopen the harness lever.** The claim is *not* "nothing in
the log can ever separate them" — it is "nothing measurable from the artefacts we currently
keep can". §5 changes what we keep. If a future run shows that species-2 trials'
`assertions` fail to name the deliverable, the fixture, or the property word the
instruction uses, at a rate that solves do not, then a content-based gate becomes testable
under the acceptance rule for the first time. Until that measurement exists, **effort here
belongs on the frontier-model arm, not on more scaffolding.**

The species that remain worth harness effort are unchanged and are in the taxonomy: async
abandonment (§1, 10 tasks, one prompt paragraph), detached services (§3, 3 tasks), and
output-ceiling truncation (§4, 3 tasks) — 16 failures whose cause is ours, against 9 whose
cause is comprehension.
