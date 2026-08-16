# Regression triage: the three tasks that flipped pass → fail on 1.0.99

**Question asked.** Three tasks in the 89-task arm — `headless-terminal`,
`large-scale-text-editing`, `pytorch-model-cli` — passed on the `f6981b61`
baseline and scored 0.0 on the new arm. Real regression, or n=1 variance? The
answer decides ship-vs-revert.

**Answer, up front.**

| task | verdict | cause |
|---|---|---|
| `pytorch-model-cli` | **REAL REGRESSION** | `f0b88f85` — already fixed at HEAD by `a0c1c768`, which is NOT in the tested artefact |
| `large-scale-text-editing` | **VARIANCE** (route-correlated) | model emitted a bare announcement and zero tool calls; no shipped code path was ever reached. **Read-range subtraction is falsified** — §3 |
| `headless-terminal` | **CANNOT DISTINGUISH** | **not a timeout** (334 s of 1800 s, clean `done`, latency *faster* than baseline); the single failing requirement was untested by *both* runs. A separate real behavioural regression is present but did not cause the 0.0 |

**Nothing should be reverted.** The one real regression is already fixed on
`main`. See §6.

**But the arm cannot answer the question it was run to answer**, because the two
arms differ in more than code. See §1 — read that first.

---

## 1. The comparison is confounded: the two arms are not the same model endpoint

MEASURED, from the arm configs and every trial's `result.json`:

| | baseline `f6981b61` | new `9b57ee7d` |
|---|---|---|
| `config.model` | `ollama/glm-5.2:cloud` | `openrouter/z-ai/glm-5.2` |
| `agent_info.model_info.provider` | `ollama` | `openrouter` |
| OSA version reported by the daemon | **1.0.98** | **1.0.99** |
| `ollama_think` | `"true"` | `null` |
| `artifact.head_commit` | `f6981b61` (matches the run label) | **`04061c68`** (one commit *past* `9b57ee7d`) |

Sources: `bench/terminalbench/runs/osa-tb20-full89-{f6981b61,9b57ee7d}/config.json`.

So the arm varies **code × inference endpoint × thinking toggle** simultaneously.
`glm-5.2:cloud` served through Ollama and `z-ai/glm-5.2` routed through
OpenRouter are different serving stacks for the same weights: different sampling
defaults, different quantisation, different tool-call formatting, different
upstream selection per request. Any per-task delta between these arms is a
compound of at least three variables, and **no per-task delta can be attributed
to shipped code from this arm alone** — in either direction.

That cuts both ways, and it should. The head-to-head on the 13 tasks completed
in both arms at time of writing is **8 passes new vs 7 baseline** — 4 improvements
(`build-pov-ray`, `polyglot-rust-c`, `qemu-alpine-ssh`, `rstan-to-pystan`) and 3
regressions. The improvements are exactly as confounded as the regressions.

### 1a. The reasoning trace vanished, and it is the route, not the code

MEASURED: `thinking_delta` count per trial.

- baseline arm: **87 of 87** trials have reasoning, 608,777 events total.
- new arm: **0 of 17** trials. Zero.

The first instinct was that `b95dbcbc` ("the effort ladder stopped at the vendor
prefix") caused it — that commit widened `OpenAICompat.maybe_add_reasoning/3`
from a name-table gate to a catalog consult, and the new arm's `osa-serve.log`
carries the new line `[OpenAICompat] reasoning_effort=medium model=z-ai/glm-5.2
source=catalog` that the baseline lacks. **That hypothesis is wrong.** Sweeping
every run under `bench/terminalbench/runs/`:

| route | trials | trials with any `thinking_delta` |
|---|---|---|
| `ollama/glm-5.2:cloud` | 109 | 109 |
| `openrouter/z-ai/glm-5.2` | 29 | **0** |

Reasoning is absent on the OpenRouter route in runs built *before* `b95dbcbc`
as well. It tracks the route, not the commit. The proximate cause is in the arm
config: the baseline set `OLLAMA_THINK=true`
(`bench/terminalbench/run_bench.py:652`), an Ollama-only knob with no OpenRouter
equivalent.

### 1b. A real, separable defect this exposed: ~⅔ of generated output is dropped on the OpenRouter route

MEASURED. Summing all surfaced content per arm (`streaming_token` +
`thinking_delta` text, plus `tool_call.args_bytes` de-doubled for the duplicate
emission) at 4 bytes/token, against billed `n_output_tokens`:

| arm | surfaced est. | billed output | ratio |
|---|---|---|---|
| ollama / 1.0.98 | 2,354,615 | 2,769,050 | **0.85** |
| openrouter / 1.0.99 | 87,856 | 266,805 | **0.33** |

Two clean single-generation trials pin it exactly, because they have zero tool
calls and therefore no argument bytes to muddy the estimate:

- `9b57ee7d::large-scale-text-editing` — 64 bytes of text (~16 tok), **160 billed
  output tokens**.
- `04061c68::path-tracing` — 73 bytes of text (~18 tok), **263 billed output
  tokens**.

So the provider *is* generating and billing reasoning content, and OSA is
discarding it. MEASURED cause: `lib/optimal_system_agent/providers/openai_compat.ex:507`
matches one field only —

```elixir
%{"reasoning_content" => text} when is_binary(text) and text != "" ->
```

— and nothing anywhere in `lib/providers/` matches a bare `"reasoning"` delta key,
which is the field OpenRouter's unified API uses. INFERRED (no OpenRouter
credential on this machine to confirm on the wire): adding a `"reasoning"` arm
to that `case` recovers it. What is MEASURED regardless of field name is that
~⅔ of billed output tokens never reach the event stream on this route, so every
OpenRouter transcript we triage is missing the model's deliberation, and
cost/telemetry attribution on that route is opaque.

---

## 2. `pytorch-model-cli` — **REAL REGRESSION**, cause `f0b88f85`, already fixed

The C implementation was **correct**. `test_cli_tool_executable` and
`test_cli_tool_output` both PASSED — the latter checks all 50 MNIST images
against the hidden `TRUE_PRED_CLASSES`. 5 of 6 tests passed. The only failure:

```
E  AssertionError: Unexpected content in /app/prediction.txt: 7
E  assert '7' == '2'
```

### The mechanism, fully reconstructible from `command_output_delta.command`

1. NEW's `cli_tool.c` (`file_write`, 223 lines, `args_bytes=7329`) writes the
   deliverable as a **side effect of every run**:
   `printf("%d\n", pred); FILE *pf = fopen("prediction.txt", "w");`
   BASELINE's `cli_tool.cpp` has exactly one `fopen` (`argv[1]`, read-only) and
   used an explicit shell redirect `./cli_tool weights.json image.png > prediction.txt`.
2. NEW's final smoke test generated three synthetic PNGs and looped the binary
   over them **with cwd `/app`**: `black -> 9`, `white -> 7`, `rand -> 7`.
3. The last invocation left `7` in `/app/prediction.txt`. NEW's own final command
   printed the damage and it was not acted on.

### Why the adequacy gate did not catch it — and why baseline's did

`verification_gate_triggered`: **1 in baseline, 0 in the new trial.** The gate
was enabled in both (`OSA_VERIFICATION_ADEQUACY=<unset>` in both driver logs).
In baseline it fired with `inadequate_test scale=large` and *directly caused*
`file_write /app/test_cli_tool.py`, whose assertion was
`prediction.txt == cli output == torch reference` — an invariant on the named
deliverable. That gate firing is the entire reason baseline passed.

In the new arm the gate stayed silent because its ledger was falsely discharged.
This is already documented in-tree at
`lib/optimal_system_agent/agent/loop/verification_evidence.ex:783-808`, which
names this exact trial: `discriminating_evidence/1` returned a red→fix→green
triple whose "test" was `/tmp/osa-tests/lodepng.o` — a **compiler object file** —
and whose "green run" was `nm`.

**Attribution, MEASURED:** `f0b88f85` ("our own test policy was destroying the
deliverable") did two things in one commit — it told the model to put both tests
*and build outputs* (`-o /tmp/osa-tests/bin`) in `/tmp/osa-tests/`, and it added
`osa-tests` to `@test_dir_segments`. Together those make a `.o` in that directory
read as a discriminating test artefact. `f0b88f85` **is** in the tested artefact
(`04061c68`); the fix `a0c1c768` ("a compiler object file was passing as a
discriminating test", which now requires `code_file?/1`) **is not**.

Corroborating, though weaker (n=17, different task mix): gate incidence dropped
from **64/87 (74%)** in baseline to **8/17 (47%)** in the new arm.

**Falsified:** the prior hypothesis that this trial lost by grading itself
against its own PyTorch reference. Both runs did that; both references were
correct; the new run's 50/50 agreement with hidden ground truth proves its
reference was faithful. The self-authored-oracle story is not the mechanism.

### Residual gap, not closed by `a0c1c768`

`a0c1c768` closes the ledger hole. Nothing in `lib/` or
`docs/research/failure-taxonomy.md` yet addresses the proximate cause: **running
the deliverable as part of testing it can mutate the deliverable.** The
`/tmp/osa-tests/` relocation policy protects the *directory listing* and not the
*file contents* — the test fixtures here were correctly relocated while the write
they induced landed in `/app`.

---

## 3. `large-scale-text-editing` — **VARIANCE**, and no shipped code path was reached

The episode is one turn, **zero tool calls**, 2.16 seconds, status `ok`,
`last_event_type: done`. The entire run was:

> I'll examine both files to understand the transformation needed.

160 billed output tokens, `/app/apply_macros.vim` never created, all 5 verifier
tests failed on `FileNotFoundError`. Baseline ran 21 tool calls and passed.

This divergence is **at the first assistant message, before any tool executes**.
Read-range subtraction, `file_grep`, `file_edit` diffs, `ConflictScope`, the
batch nudge, truncation handling — none of them can run in a session that never
called a tool.

### The read-range-subtraction prior is falsified, twice over

This was the standing prior on this task, and the specific question was: *did the
model act on a subtracted view as though it were the whole file?* It did not, and
it could not have.

**First, by construction.** The trial made **zero `file_read` calls** — zero
`tool_call` and zero `tool_result` events of any kind. There is no subtracted view
to act on. `b297a872` is not reachable in a one-turn, zero-tool episode.

**Second, arm-wide.** Grepping every new-arm event stream for the literal markers
`b297a872` emits (`Messages.subtracted_header/3`: *"are omitted because you
already read them this session"*, and the inline `omitted_gap/2` marker):

| trial | subtraction fires |
|---|---|
| `gcode-to-text` | 1 |
| `make-mips-interpreter` | 1 |
| **all 15 others**, incl. `large-scale-text-editing`, `headless-terminal`, `pytorch-model-cli` | **0** |

Subtraction fired **twice in 17 trials**, and on neither task under investigation.
Where it did fire it behaved correctly — it named the omission in the header,
marked the hole inline at the jump, and offered `resend: true`:

```
<file_read notice: showing lines 71-78 of /tmp/l2big.txt. Lines 29-70 are
omitted because you already read them this session and the file has not changed
since — … Pass `resend: true` to get the omitted lines again.>
     … [lines 29-70 omitted — 42 lines you already hold, unchanged]
   71| …
```

The feared failure mode — a 40%-token-saving feature silently corrupting the
model's picture of a file — is **not observed anywhere in this arm**. It is also
barely exercised: 2 fires across 17 trials means this arm carries almost no
evidence about `b297a872` in either direction, which is worth knowing before
anyone concludes it is safe.

**Route correlation, MEASURED** across every run on disk:

| route | trials | zero-tool `ok` episodes |
|---|---|---|
| `ollama/glm-5.2:cloud` | 109 | **0** |
| `openrouter/z-ai/glm-5.2` | 29 | **2** (`04061c68::path-tracing`, `9b57ee7d::large-scale-text-editing`) |

Two occurrences, two different tasks, both on OpenRouter, never once in 109
ollama trials. n=2 is thin — Fisher's exact on 0/109 vs 2/29 gives p ≈ 0.04 — but
it points at the route, and there is no code path that could produce it.

### What this *does* expose: the announcement backstop cannot fire on this shape

`21bdbc21` shipped tonight specifically to catch "ended on an announcement". It
did not fire here, for **two independent reasons**, both MEASURED from the source
at the tested commit:

1. At `9b57ee7d`, `Guardrails.announcement_continue/2` has only the
   `:interrupted_task` arm, gated on `not talked_only?(messages)`. A session that
   never called a tool has trivially only talked → `:stop`. The `:unstarted_task`
   arm that fixes this was written afterwards and is at HEAD only.
2. **Even at HEAD it would still not fire.** `@announcement_pattern`
   (`lib/optimal_system_agent/agent/loop/guardrails.ex:140`) is
   `~r/(let me |i'll (now|start|begin|write|investigate|wait|hold|report|keep|stop)|now let)/i`.
   `"I'll examine …"` matches no alternative — `examine` is not in the verb list.
   `announcement_only?/1` returns false, so all three continuation clauses are
   dead on this content.

Separately, all three `prose_continue?` clauses (auto-continue, coding nudge,
verification gate) are gated on `continue_on_text_only`, which defaults to
`false` (`config/config.exs:86`). That default is unchanged between the arms and
is documented as deliberate; it is noted here only so the safety-net inventory is
complete.

**Actionable, cheap, low-risk:** widen `@announcement_pattern`'s verb alternation
(`examine`, `look`, `check`, `read`, `explore`, `analyz…`), then re-replay against
`scripts/failure_species.py`'s 34-failure / 49-solve set to confirm the measured
0-of-49-solves precision survives. Do not ship the widening without that replay.

---

## 4. `headless-terminal` — **CANNOT DISTINGUISH**

The deliverable *was* produced: `/app/headless_terminal.py`, 12,221 bytes, and
`/app` was clean. **5 of 6 tests passed in both directions except one:**

```
FAILED test_background_commands — requests.exceptions.ConnectionError:
  HTTPConnectionPool(host='localhost', port=8000) … [Errno 111] Connection refused
```

That test (`tasks/terminal-bench-2/headless-terminal/tests/test_outputs.py:115-130`)
is the only one exercising two things: a **split keystroke send** (command body,
then `"\n"` separately) and a **backgrounded job reachable from another process**.

**Neither run wrote a test for it.** Baseline authored 5 tests, the new run
authored 13; no `&`, no split-send, in either. Baseline passed that assertion by
luck of one-shot generation, not by verifying it. One uncovered requirement, two
independent generations, opposite outcomes — that is the signature of variance.

### It did not time out. It failed on its merits.

Contention was the convenient explanation — this trial ran in the 8.6-minute
window where the host carried 7 concurrent trials instead of 4 — and it is wrong.
The premise is real (host-wide peak of 6 measured across two interleaved jobs,
`osa-tb20-full89-9b57ee7d` and `VOID-contended-probe-minimal-04061c68`), but the
consequence never materialised:

- **Time budget**: 334.01 s used of **1800 s** (task `timeout_sec` × the arm's
  `timeout_multiplier: 2.0`). **18.7% consumed.**
- **Clean ending**: `osa_last_event_type: done`, `osa_status: ok`,
  `osa_turn_error: null`, `turn_recap {tool_calls: 52, elapsed_ms: 333919}`.
- **Latency was *better* than baseline**: median LLM call 1407 ms (new) vs
  1861 ms (baseline) over 53 and 16 calls.
- **Zero** tool results matching `timed out|timeout|killed|SIGKILL` in either run.
  The only regex hits are the literal word "timeout" inside a test file's source.
- The three largest inter-log gaps (81.6 s, 21 s, 12.7 s) each sit immediately
  before a `[loop] LLM call completed in Nms` line — they are generation time for
  a 12.8 KB `file_write`, not stalls.

**Contention is irrelevant to this failure.** The run finished early, cleanly, and
lost on one assertion.

Ruled out, all MEASURED:

- **Not a timeout**: 334 s used of an 1800 s budget; `done`, `osa_turn_error: null`.
- **Not context pressure**: 44,250 / 1,048,576 tokens, `at_blocking_limit: false`.
- **Not host contention**, despite the 7-concurrent window being real (host-wide
  peak 6 measured across interleaved jobs): NEW's median LLM latency was
  **1407 ms vs baseline's 1861 ms** — *faster* — and there are zero
  timeout/killed/SIGKILL strings in either run's tool results. The largest inter-log
  gaps sit immediately before `[loop] LLM call completed in Nms` lines; they are
  generation time for a 12.8 KB `file_write`, not stalls.
- **No subtracted `file_read`**: every ranged read carries an ordinary honest
  footer (`Showing lines 135-146. Use offset=147 to continue.`). No withheld
  header anywhere. (The `withheld` hit in `osa-serve.log` is the unrelated
  `23/80 tools in the default toolbox; 57 withheld`.)
- **No `[INCOMPLETE]`** in either run.
- **`file_grep` never called** in either run.

### A real behavioural regression is present here, and it did not cause the 0.0

Worth fixing on its own merits; both halves MEASURED from the tool sequence:

1. **Test-fitting.** NEW wrote `/app/headless_terminal.py` once at tool call #07
   and **never edited it again across 52 calls**. When its own tests went red at
   #17 and #23, it edited the *tests* (#22, #24, #25 — all `file_edit` on
   `/tmp/osa-tests/test_headless_terminal.py`), and says so in its own stream:
   *"My tests did fail earlier, but I fixed the tests, not the source."* Baseline
   went red at #11 and edited the *source* at #12 — which is precisely why its
   implementation ended up correct.
2. **The gate's remedy is the wrong shape.** `verification_gate_triggered`
   (`inadequate_test`, `scale: large`) fired in **both** runs, but at different
   times with different consequences. In baseline it fired at event 3055 of 3199 —
   after the last tool call — and cost nothing. In NEW it fired mid-run at event
   946 of 1861, and the agent obeyed it by building a deliberately-broken
   straw-man implementation under `/tmp/osa-tests/broken_impl/` and iterating on
   *that* for **18 of its 52 tool calls (~half the wall clock)** — never once
   re-examining the real deliverable. A remedy pointing at *uncovered task
   requirements* (here, the word "background" in the task text) rather than at
   *oracle discrimination* would have had a real chance at this failure.

Note also that `f0b88f85`'s relocation worked as designed — NEW's `/app` was
clean — but baseline left `/app/tests/test_headless_terminal.py` in the
deliverable directory and **still scored 1.0**. On this task the change bought
nothing while moving the tests out of the directory the agent naturally re-ran.

---

## 4a. The other direction: `f0b88f85` also *caused* an improvement

`polyglot-rust-c` went **0 → 1**, and it is the same commit. This matters for the
revert decision, so it is measured here rather than left as a footnote.

Baseline failed on the verifier's **first line**
(`osa-tb20-full89-f6981b61/.../polyglot-rust-c__3pSNWki/verifier/test-stdout.txt`):

```
polyglot_files = os.listdir("/app/polyglot")
>  assert polyglot_files == ["main.rs"]
E  assert ['test_polygl...', 'rust_fib'] == ['main.rs']
FAILED test_fibonacci_polyglot        1 failed in 0.03s
```

Every extra entry was OSA's own — the test the adequacy gate demanded, and the
binaries that test compiled. The new run did all three things `f0b88f85` added,
visible in `command_output_delta.command`:

```
PYTHONDONTWRITEBYTECODE=1 python3 /tmp/osa-tests/test_polyglot_fib.py; echo "exit=$?"
cd /app/polyglot && rm -f rmain cmain && rm -f /tmp/t.cpp /tmp/t && ls -la
find /tmp/osa-tests/bin -type f -delete; rmdir /tmp/osa-tests/bin 2>/dev/null; ls /app/polyglot
```

Test relocated out of the deliverable directory, bytecode suppressed, binaries
swept from `/app/polyglot` before finishing. Reward 1.0.

**So `f0b88f85` is a commit with a measured win and a measured loss, and the loss
is already patched.** Reverting it would trade the `pytorch-model-cli` regression
— which `a0c1c768` fixes on `main` — for the `polyglot-rust-c` regression, plus
the 12-of-89 deliverable-pollution cases the commit was written to fix. That is a
strictly worse trade.

---

## 5. What was checked and found not guilty

Each item on the "shipped tonight" list, against the transcripts rather than the
list:

| change | verdict on these three tasks |
|---|---|
| **Read range subtraction** (`b297a872`) | **Not reached, and barely exercised.** Fires on 2 of 17 new-arm trials (`gcode-to-text`, `make-mips-interpreter`), zero on all three tasks under investigation; `large-scale-text-editing` never called a tool at all. Correct behaviour where it did fire. See §3. |
| **Verification adequacy gate** | Mixed and material. Its *absence* caused `pytorch-model-cli` (§2). Its *remedy shape* wasted half of `headless-terminal` (§4). Not implicated in `large-scale-text-editing`. |
| **`file_grep` rewrite** | Never called in `headless-terminal` or `large-scale-text-editing`; used 6× in `pytorch-model-cli` and surfaced the same `lodepng.h` facts as baseline's shell `grep`. Not implicated. |
| **`file_edit` diff / no-echo** | No diff-anchoring artefact in any of the three. Not implicated. |
| **Truncation handling / 48k-64k rungs** | Zero `[INCOMPLETE]` markers anywhere. Not implicated. |
| **`ConflictScope`** | No parallel same-file edits in any of the three. Not implicated. |
| **Batch-cadence nudge** | Requires tool results; `large-scale-text-editing` had none. No effect observed on the other two. |
| **`code_symbols` always-loaded / tool-array shape** | `Soul` static base is comparable across arms (4977–5973 tokens both sides). No divergence traced to it. |

---

## 6. Ship or revert

**Do not revert anything.**

- The one **real** regression, `pytorch-model-cli`, is caused by `f0b88f85` and is
  **already fixed on `main` by `a0c1c768`**, which was simply not in the artefact
  the arm tested (`04061c68`).
- **`f0b88f85` is not a candidate for revert**, and not only because it is already
  patched: the same commit *caused* the `polyglot-rust-c` 0 → 1 (§4a), and it was
  written against a measured defect — 12 of 89 baseline trials wrote a test
  artefact into a declared deliverable directory, 10 of them solves that happened
  not to be graded on directory contents. Reverting swaps one regression for
  another and reopens ten latent ones.
- `large-scale-text-editing` is not caused by any shipped code.
- `headless-terminal` is not attributable at n=1.

**The blocking problem is not any commit, it is the arm design.** As it stands the
run varies code, inference endpoint, and the thinking toggle at once, so neither
the 3 regressions nor the 4 improvements are evidence about what we shipped.

### Ordered next actions

1. **Run a control arm: 1.0.99 on the ollama route with `OLLAMA_THINK=true`.**
   This is the single change that makes the arm interpretable, and it costs one
   run. Everything below is cheaper than it and worth less.
2. **Targeted n≥5 re-runs**, after the current arm finishes, of
   `large-scale-text-editing` and `headless-terminal` on both routes. Costs cents.
   Prediction: both flip in both arms; the `headless-terminal` test-fitting
   behaviour reproduces regardless of reward.
3. **Add a `"reasoning"` arm** beside `"reasoning_content"` at
   `openai_compat.ex:507`, so the ~⅔ of billed output tokens currently discarded on
   the OpenRouter route become visible (§1b). Until this lands, every OpenRouter
   transcript is missing the model's deliberation and every OpenRouter triage —
   including this one — is working half-blind.
4. **Widen `@announcement_pattern`'s verb alternation** (§3), gated on replaying
   `scripts/failure_species.py` to confirm 0-of-49-solves precision holds.
5. **Close the residual `pytorch-model-cli` gap** (§2): a deliverable that is
   mutated by the act of running it. The relocation policy does not cover it.
6. **Re-aim the adequacy gate's remedy** at uncovered task requirements rather
   than oracle discrimination (§4).

---

### Provenance

Every table above is derived from the artefacts under
`bench/terminalbench/runs/` (read-only; the 89-task arm was live during this
triage and nothing under `bench/` was written). `tool_call.args` was not used
anywhere — all command evidence comes from `command_output_delta.command`,
`args_bytes`, `args_hash`, and `tool_result` payloads. Claims marked INFERRED
are the two noted in §1b; everything else is MEASURED and re-derivable from the
paths cited.

The new arm was still running at 17 of 89 trials when this was written. The
head-to-head in §1 will move.
