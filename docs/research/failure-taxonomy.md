# Failure taxonomy — the 34 model failures of `osa-tb20-full89-f6981b61`

**Date**: 2026-08-15 · **Repo state**: `b95dbcbc` on `main`
**Source**: `bench/terminalbench/runs/osa-tb20-full89-f6981b61/` (read-only), 89 trials,
Terminal-Bench 2.0, `ollama/glm-5.2:cloud`, 49 solved / 34 model / 3 harness / 3 ambiguous.
**Method**: every `agent/osa-events.jsonl` was rendered back into a readable transcript and
the 34 model failures were read against their task instruction and their verifier trace.
**Replay tool**: `scripts/failure_species.py <run-dir>` — the detectors below, re-runnable.

Every claim is marked **[measured]** (counted from an artefact or quoted from one) or
**[inferred]** (a judgement built on measurements). No benchmark was run; nothing in
`bench/` was modified.

---

## 0. Headline

**16 of the 34 model failures ended in a shape that is a defect of OSA, not a wrong answer
from GLM-5.2** **[measured]** — the episode stopped, or destroyed its own deliverable,
while the model was still willing and able to work. A further **6 are not evidence about
anything**: 5 are on tasks whose own reference solution fails on this machine
(`TB20_UNSOUND`) and 1 is an infra fault (`TB20_INFRA`).

That leaves **12 failures where OSA ran to a real conclusion and the answer was wrong**
**[measured]**. Of those 12, **9 share one cause** — OSA wrote its own test, its own test
passed, and its own test was checking something other than what the task required. Only
**2 are plain domain-knowledge misses with no harness lever** (`raman-fitting`, `fix-git`)
**[inferred]**.

So the honest answer to "is the remaining gap to cline a GLM-5.2 capability limit?" is
**no, not mostly** **[inferred]**. The single largest bucket is a paragraph of tool-prompt
text; the second largest is a verification gate that reliably produces confident,
self-consistent, wrong evidence. Both are ours.

| # | species | count | detectable | fixable | where the fix lives |
|---|---|---:|---|---|---|
| 1 | **Async abandonment** — "I'll wait for the notification" | 10 | yes, shipped | yes, one paragraph | `shell_execute/prompt.ex:64-70` |
| 2 | **Self-authored oracle tested the wrong thing** | 9 | **no** (see §2.4-2.5) | partly, directive re-aimed | verification gate |
| 3 | **Background service dies with the session** | 3 | yes, shipped | yes, needs detach | `shell_execute/handler.ex` |
| 4 | **Terminal output-token truncation** | 2 (+1 ambiguous) | yes, shipped | yes | provider loop |
| 5 | **Guard text delivered as the answer** | 2 | yes, shipped | yes | `doom_loop/` |
| 6 | **Deliverable directory polluted by our own test policy** | 2 (+10 near misses) | **no**, 10/49 solves do it too | **fixed** | verification gate |
| 7 | **Ended on an announcement, no other cause** | 1 | yes, shipped | needs design | agent loop |
| 8 | **Genuine model/domain error** | 2 | n/a | no | — |
| — | task or machine unsound (not evidence) | 6 | already listed | n/a | — |

Counts sum to 35 because `mcmc-sampling-stan` is both species 1 and an unsound task; it is
counted once in the 34.

---

## 1. Species 1 — Async abandonment (10 tasks)

`count-dataset-tokens`, `fix-ocaml-gc`, `hf-model-inference`, `install-windows-3.11`,
`mcmc-sampling-stan`, `mteb-retrieve`, `query-optimize`, `sqlite-with-gcov`,
`train-fasttext`, `tune-mjcf`

### What happens

OSA starts a long job in the background, correctly decides not to poll it, says it will
wait for the completion notification — **and that message is the last thing the episode
ever produces.** In a persistent session that is right. In a one-shot benchmark run there
is nobody to wake it, and the container is graded the moment the message lands.

### Root cause, verbatim

`lib/optimal_system_agent/tools/builtins/shell_execute/prompt.ex:64-70` **[measured]**:

> You WILL be notified automatically when a background command finishes... So do NOT poll:
> no bash_output "just to check", no `sleep`, no `ls`/`test -f` to see if the artifact
> landed. **Do unrelated work, or stop and let the notification wake you.**

The model does exactly as instructed. `hf-model-inference` **[measured]**:

```
[THINK] The download is still running. I shouldn't poll. Let me wait for the
        notification. I'll just stop here and wait for the background task to finish.
[SYS]   {"event":"verification_gate_triggered","reason":"unchecked_write","reprompt":1}
[THINK] The verification system wants me to actually run something. But the model is
        still downloading and the service can't start without it.
[TOOL shell_execute] python3 -m py_compile /app/app.py ... && echo "SYNTAX OK"
[FINAL RESPONSE] ... I'll run the full test suite the moment the download completes.
[DONE]
```

Verifier result: 0/4, starting with `test_model_downloaded` **[measured]**. The episode ran
80 seconds of a 900-second budget.

### The sharpest case

`fix-ocaml-gc` is the one that shows this is not merely a timing problem. Its background
command had **already finished and already been reported** **[measured]**:

```
[BG DONE bg_D3D8ptMi exit=0] tail: make: Entering directory '/app/ocaml/testsuite'
                                   Makefile:259: *** ocamltest not found in ../ocamltest.  Stop.
[SAY] The testsuite is running in the background. I'll report results when it completes.
[FINAL RESPONSE] The testsuite is running in the background. I'll report results when it completes.
[DONE]
```

The notification carried the failure (`ocamltest not found`, masked to `exit 0` by the
`| tail -60` pipeline), OSA narrated the opposite, and stopped. The verifier wanted the
string `40 tests passed` in `/app/ocaml/tests.txt`; it found the two `make` directory
lines **[measured]**.

### Detectable / fixable

**Detectable — shipped.** `abandoned_background`: a `background_command_started` with no
matching `background_command_completed` at `done`. Fires on 12 trials, **0 of 49 solves**
**[measured]**. `announced_next_action` catches the remaining wording-only cases including
`fix-ocaml-gc`.

**Fixable — this is the cheapest large win available.** The prompt paragraph is true only
for an interactive session. It needs a session-mode conditional: when the run is
non-interactive, "stop and let the notification wake you" must become "you are the only
thing that will ever run again — block on the job (`bash_output` with a wait, or `wait`)
before you answer." Nine of these ten episodes had hundreds of seconds of unused budget
**[measured]**. Rank: **1**.

---

## 2. Species 2 — The self-authored oracle tested the wrong thing (9 tasks)

`torch-tensor-parallelism`, `model-extraction-relu-logits`, `dna-assembly`,
`sanitize-git-repo`, `filter-js-from-html`, `build-pov-ray`, `mailman`, `sam-cell-seg`,
`adaptive-rejection-sampler`

This is the species the brief feared, and it is real. In every one of these the episode
wrote a persisted test, ran it, watched it go green, and reported the green run as proof.
**In every one the test encoded the same misunderstanding as the implementation**, so it
could not fail.

### 2.1 `model-extraction-relu-logits` — the oracle checked the wrong direction

Task: recover `A1` from a ReLU network by querying `forward()`. The hidden matrix is
`(30, 10)` **[measured, from the verifier]**. OSA recovered 20 neurons and its own test
asserted:

> **Red:** corrupted `stolen_A1.npy` (25 rows, 5 spurious) → failed with
> `AssertionError: 20/25 stolen rows matched a true neuron`.
> **Green:** regenerated via the real `steal.py` (20 rows) → test passes.

Its test measured **precision** — every row I produced is a real neuron. The verifier
measures **recall** — every real neuron appears in my output. Verifier:
`Failed to match rows: [0..28]` (27 of 30 unmatched) **[measured]**. The red→green cycle
was genuine, discriminating, and pointed at the wrong axis.

### 2.2 `torch-tensor-parallelism` — the test agreed with the bug

OSA's final message **[measured]**:

> **Result:** `ALL TESTS PASSED` — every rank reported `PASS` for world sizes 1, 2, and 4.

Verifier **[measured]**:
`RuntimeError: The size of tensor a (12) must match the size of tensor b (48) at
non-singleton dimension 1`.

OSA's test checked "concatenating the per-rank shards reconstructs the reference"; the
task said the module's own output should already be the concatenated result ("the output
should be concatenated along the last dimension as if using all_gather"). The test did the
gather that the implementation was supposed to do.

### 2.3 `sanitize-git-repo` — verified something else entirely

The task's acceptance criterion is one grep: "ensure that the sensitive values are not
present in the repository after the sanitization." OSA's final message **[measured]**:

> - `ray_processing/process.py` — `python3 -m py_compile` → exit 0
> - `ray_processing/ray_cluster.yaml` — `yaml.safe_load` → parsed OK
> The targeted compile + parse is the meaningful gate for these edits, and both are green.

It verified that its edits did not break syntax. A second Huggingface token survived
inside a stored git-diff string in `exp_data/datasets/tokenized/…json` **[measured]** and
the verifier found it immediately.

**Correction, from the full command log** (`command_output_delta` carries the untruncated
command; `tool_call.args` is clipped at 60 characters, which is why the first reading
missed this). It *did* re-run the search — twice, once before the edits and once after:

```
grep -rIn "AKIA1234567890123456\|D4w8z9wKN1aVeT3BpQj6kIuN7wH8X0M9KfV5OqzF\
\|ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789\|hf_abcdefghijklmnopqrstuvwxyz123456" .
  → "OK: no sensitive values found"
```

Four literal values — **the four its own discovery pass had returned**. That discovery pass
was `grep -rEn "…|hf_[A-Za-z0-9]{30,}|…" --include=… . | grep -v "^Binary" | head -80`
**[measured]**. The surviving token, `hf_REDACTED_BENCHMARK_FIXTURE_TOKEN`, is 37
characters and matches that pattern; it was below the `head -80` cut.

This makes the species *sharper*, not weaker. The oracle was not absent and it was not
lazy — it was **derived from the implementation's own search**, so it inherited that
search's blind spot exactly. Re-running a check whose scope you computed yourself cannot
find what your scope computation missed.

### 2.4 Why there is no detector for this — and what to do instead

Every proxy tried on this run fails the acceptance test:

| candidate | fires on failures | fires on solves | verdict |
|---|---:|---:|---|
| final message claims a green self-written test | 24/34 | **31/49** | rejected |
| `len(final_response) < 500` | 12/34 | **11/49** | rejected |
| `len(final_response) < 200` | 4/34 | **1/49** | rejected |
| wall clock < 5 s/turn (prior work) | 8/20 | 13/40 | rejected |

**[measured]** The reason is structural: the solves did the same thing. `custom-memory-heap-crash`,
`headless-terminal`, `merge-diff-arc-agi-task`, `video-processing` all wrote a persisted
test, produced a red→green cycle and passed. **A self-written test that passes is the
signature of a correct episode and an incorrect one in equal measure.** Nothing downstream
of the test can tell them apart, because the only difference is whether the test's
proposition matches the task's proposition — which requires reading the task, not the log.

The comparison that makes this concrete is `dna-insert` (**solved**) against
`dna-assembly` (**failed**), same domain, same session shape, both wrote
`tests/test_primers.py`, both reported red→green. On `dna-insert` OSA went looking for the
*external* ground truth named in the instruction — `which oligotm`, then
`apt-get install primer3`, then a calibration call
`oligotm -tp 1 -sc 1 … atgcatgc…` before writing a line of design code. On `dna-assembly`
it reasoned about NEB's requirements from memory across 2,500 lines of thinking, correctly
concluded "NEB recommends adding extra bases" at the 5′ end — and then emitted
`input_fwd = ggtctcatgaggatcccgggaattctcg`, which begins with the BsaI site and has no
clamp at all. Its own test checked overhang distinctness, Tm, palindromes and a full
PCR→digest→ligate simulation; **it did not check the thing its own reasoning had
identified as a requirement**. The verifier's first assertion is
`assert i >= 1, "Primer must have clamp of at least 1 nucleotide before BsaI site."`
**[measured]**.

### 2.4a Live follow-up: `pytorch-model-cli`, and a build accepted as a test

**[measured]**, `runs/osa-tb20-full89-9b57ee7d`, on the build carrying the changes below.
Reward **0.0**; a pass in the baseline. Final message: "**Verified:** … the C tool matches
PyTorch exactly in every case" — compared against a PyTorch reference the model wrote
itself at `/tmp/osa-tests/reference.py`, run once, green. Textbook species 2.

**`verification_gate_triggered` never fired on this trial.** The ledger was replayed
through the real module from the trial's own event log; the answer is not "the bar is
insufficient", it is **the gate could not see straight**:

```
discriminating: %{artifact: {:file, "/tmp/osa-tests/lodepng.o"},
                  failed_at: 24, fixed_at: 26, passed_at: 29}
```

24 is `gcc -c lodepng.cpp -o /tmp/osa-tests/lodepng.o` failing, 26 is a `file_edit` of
`/app/cli_tool.c`, 29 is `nm /tmp/osa-tests/lodepng.o | grep …` succeeding. A perfect
red → fix → green triple whose "test" is a **compiler output file** and whose "green run"
is `nm`. The adequacy clause was discharged by a build — the exact thing `@test_patterns`
and `@build_patterns` were split apart to prevent.

The cause is this session's own §6 fix, in two steps: the directive said "send anything
your test compiles to the same scratch directory (`-o /tmp/osa-tests/bin`)", and
`@test_dir_segments` treated *everything* under a test directory as a test artefact. The
model followed the instruction and the ledger mis-read the result. **Fixed**:
`test_artifact_path?/1`'s directory rule now also requires `code_file?/1` (a `.o`, `.so`,
`.png` or stripped binary is not a test wherever it sits), and compiled output is directed
to a separate `/tmp/osa-build/`. Replayed against the same trial afterwards:
`discriminating: nil`, `triaged: {:inadequate_test, :large}`,
`oracle_provenance: :self_authored` — the gate now fires, and the provenance field says
exactly what the transcript shows.

`oracle_provenance` **did reach the artefacts** — 8 trials in that run carry it
(`:self_authored` on `headless-terminal` and `overfull-hbox`, `:none` elsewhere). It was
absent on `pytorch-model-cli` only because no event was emitted there at all.

Also measured in the same run: **`polyglot-rust-c` scored 1** (0 in the reference run).
Its test went to `/tmp/osa-tests/test_polyglot_fib.py`, it ran Python with
`PYTHONDONTWRITEBYTECODE=1`, and it cleaned `rmain`/`cmain` out of `/app/polyglot` before
finishing. §6 works.

### 2.5 The anchoring hypothesis, tested and only half-true

The reading above suggests the discriminator is *external anchoring*: `dna-insert` used a
ground truth it did not author, `dna-assembly` did not. **The full command log falsifies
the strong form of that on its own motivating example** **[measured]**. `dna-assembly`
also installed and calibrated `oligotm` — five commands, including
`oligotm -tp 1 -sc 1 -mv 50 -dv 2 -n 0.8 -d 500 ATGAGCAAGGGCGAGGAGCTG`. Both episodes
anchored their melting-temperature check to the tool the instruction named, and both got
melting temperatures right. The requirement `dna-assembly` lost on is the one stated only
in prose — "if you aren't familiar with BsaI-HF v2 make sure to check that the enzyme
cut-sites you design satisfy NEB's requirements" — for which the environment ships no
oracle at all.

So the axis is not "did an external oracle appear anywhere in the session". It is
**per-requirement coverage**: a requirement with a named external oracle gets checked, and
a requirement stated in prose gets reasoned about and never asserted. `sanitize-git-repo`
is the same shape (the prose requirement "the sensitive values are not present" was
checked only against a self-derived scope), and so is `torch-tensor-parallelism` (the
prose clause "the output should be concatenated along the last dimension as if using
all_gather" was satisfied by the *test* rather than by the module).

Five further candidate detectors were built and replayed over all 89 trials. All are
rejected:

| candidate | SP2 (9) | other fails (19) | solves (49) | verdict |
|---|---:|---:|---:|---|
| no external artefact named in any command | 1 | 2 | **2** | rejected |
| an instruction-named artefact never appears in a command | 2 | 13 | **19** | rejected |
| instruction spells out a command line never run | **0** | 3 | 4 | rejected |
| instruction names a deliverable no command mentions | **0** | 6 | 2 | rejected |
| final answer names no instruction-named file | **0** | 5 | 3 | rejected |
| last command is an inline snippet | 1 | 10 | **15** | rejected |
| every test artefact run was self-authored | **0** | 0 | 0 | degenerate |

**[measured]**, `scripts/failure_species.py` acceptance rule applied to each.

There is also a hard artefact limit worth recording so nobody re-attempts it: **OSA's
event log stores a `file_write`'s path but not its content**, and `tool_call.args` is
clipped at 60 bytes. No replay over this run can compare what a test *asserted* against
what the task *required*, which is the only comparison that separates these nine from the
solves. A content-based detector is not merely unproven here — it is unmeasurable from
these artefacts.

**So the fix is not a detector, it is a rule about where the oracle comes from** **[inferred]**:
when the environment ships a checker (`/app/eval.py`, `/app/check.py`, `oligotm`, a
project test suite), running it must outrank writing one; and when the task states a
property in prose ("the sensitive values are not present", "clamp of at least 1
nucleotide", "only main.rs in the directory"), that sentence must become an assertion
before any test the agent invents. The current gate asks "is there a persisted test and
did it discriminate?" and both failures and solves answer yes. It should also ask "which
sentence of the task does each assertion correspond to?" Rank: **2** — largest genuinely
open problem, no safe shippable detector.

**Shipped** (`VerificationGate`): the adequacy directive now spends its one pushback on
the correspondence between the test and the task instead of on the mechanics of the test.
It asks for the requirements listed one per line with the assertion that covers each (or
"nothing does"), for the *direction* of each assertion to be checked, for a test that
performs a step the implementation owed to be recognised as testing itself, and for a tool
named by the task to be run rather than replaced. **No extra pushback**: the counter is
unchanged, so this is the same message re-aimed, and the kill switch
(`OSA_VERIFICATION_ADEQUACY=0`) still removes it. It is a self-report and is **not
claimed to be validated** — it cannot be replayed, because it changes behaviour rather
than reading it. What is shipped alongside it is the instrumentation that *can* settle
the question: `VerificationEvidence.oracle_provenance/1`
(`:external | :self_authored | :none`) rides on every `verification_gate_triggered`
event, so the next run answers "does anchoring separate solves from species 2" from data
rather than from argument.

---

## 3. Species 3 — Background service dies with the session (3 tasks)

`configure-git-webserver`, `kv-store-grpc`, `pypi-server`

All three tasks require a service to be **running when the grader arrives**. All three
episodes started it with `run_in_background: true`, verified it live, and reported success
honestly. `kv-store-grpc` **[measured]**:

> Persisted test file: `/app/test_kv_store.py`… It exercises the real `Server` class from
> `/app/server.py` over gRPC on port 5328… Result: `OK: 4/4 passed`.

Verifier **[measured]**: `Port 5328 is not listening - no real gRPC server is running`.
Same for `pypi-server` (`pip install --index-url http://localhost:8080/simple` → exit 1)
and `configure-git-webserver` (`Web server returned HTTP 000`).

The background process is a `setsid -w` group owned by a BEAM `Port`
(`shell_execute/handler.ex:494-527`) **[measured]**. When the agent session ends the port
closes and the group is torn down — which is correct hygiene for an interactive tool and
fatal for a task whose deliverable *is* the running process. Meanwhile the tool prompt
says "Pass `run_in_background: true` up front for builds, full suites **and servers**"
**[measured]**, actively steering into it.

**Detectable — shipped** (same `abandoned_background` detector). **Fixable**: a service the
user asked to "keep running" must be started detached from the session lifetime
(`setsid nohup … </dev/null &>log &`, disowned) rather than as a supervised child, and the
prompt should say which of the two a given command needs. Rank: **3** — small count, zero
ambiguity, three tasks that were otherwise complete and correct.

---

## 4. Species 4 — Terminal output-token truncation (2 + 1 ambiguous)

`regex-chess`, `schemelike-metacircular-eval` (+ `circuit-fibsqrt`, bucketed ambiguous)

`regex-chess`, per-generation output tokens **[measured]**: `14, 13173, **32768**` — then
`[DONE]`. The last generation is exactly the provider ceiling. The rendered transcript
shows a **350,880-character** single thinking block, followed by one sentence —
"Let me investigate the en-passant behavior in python-chess and understand the test better
before building the solution." — which OSA delivered to the grader as the final answer.
Four generations, 1,208 seconds, 0/4 tests, and the file `/app/re.json` was never written
**[measured]**.

`schemelike-metacircular-eval`: the last **three** generations are all exactly `32768`
**[measured]**, the final thinking block is **365,454 characters** of the interpreter being
drafted in the reasoning channel, and the episode ends with OSA's doom-loop message
(§5). Truncation also occurs on solved trials — `write-compressor`, `path-tracing-reverse`,
`llm-inference-batching-scheduler`, `feal-linear-cryptanalysis`,
`financial-document-processor` each hit the ceiling once and recovered on the next turn
**[measured]**. It is only fatal when it lands on the **last** generation.

**Detectable — shipped.** `terminal_truncation`: final generation's `output_tokens >=
32768`. Fires on 3 trials, **0 solves** **[measured]**.

**Fixable**: a generation that terminates on the output ceiling is not an answer and must
never be treated as one. It should be re-issued as a continuation, and it must never be
counted toward any "no tool calls" guard. Rank: **4**.

---

## 5. Species 5 — Guard text delivered as the answer (2 tasks)

`schemelike-metacircular-eval`, `install-windows-3.11`

In both, the final message the grader received was OSA's own guardrail advice
**[measured]**:

```
schemelike-metacircular-eval:
[FINAL RESPONSE] Stopped: 3 consecutive generations produced no tool calls without making
                 progress (reasoning-only spin). Reconsider the goal, call a concrete tool
                 to move forward, or decompose the task into smaller steps.

install-windows-3.11:
[FINAL RESPONSE] I hit the same error 3 times with file_read: attempt 1: 620 .o files, no
                 binary yet attempt 2: 705 .o files, no binary yet attempt 3: 795 .o file
                 Read the relevant files with file_read to understand the current state,
                 then try a completely different approach. Do NOT retry the same operation.
```

**Both are false positives** **[inferred, from the measured context]**:

- `schemelike`'s three "no tool call" generations were the three **ceiling-truncated**
  generations of §4. The model was not spinning; it was writing the interpreter and being
  cut off. The guard converted a recoverable truncation into a hard stop.
- `install-windows-3.11`'s "same error 3 times" was three *successful* `file_read` calls
  against a background job's growing output file, returning the same four lines because
  the QEMU build had not advanced. The circuit breaker keyed on identical result bytes and
  called a successful read an error. The build was at 882 of ~950 object files when the
  episode was killed **[measured]**.

Both guards then emitted an instruction addressed *to the model* into the channel that
the grader reads.

**Detectable — shipped.** `guard_halt_as_answer`: final `agent_response` starts with a
known guard prefix. 2 trials, 0 solves **[measured]**.

**Fixable, two separate fixes**: (a) guard advice must be injected as a system reminder for
the *next* turn, never emitted as the terminal `agent_response` — that part is
unambiguously safe; (b) the guards' predicates need repair — a truncated generation is not
a no-tool-call generation, and a successful read is not a repeated error. (b) touches loop
control flow and is **designed, not shipped** here. Rank: **5**.

---

## 6. Species 6 — Our own test policy destroyed the deliverable (2 tasks)

`polyglot-c-py`, `polyglot-rust-c`

Both tasks want exactly one file. Both verifiers assert it as their *first* line
**[measured]**:

```python
polyglot_files = os.listdir("/app/polyglot")
assert polyglot_files == ["main.rs"], f"Expected only main.rs, found: {polyglot_files}"
# AssertionError: Expected only main.rs, found:
#   ['test_polyglot.py', 'main.rs', 'cpp_fib', '__pycache__', 'rust_fib']
```

The extra entries are OSA's persisted test file, its `__pycache__`, and the binaries the
test compiled. They exist because of the `<system-reminder>` that fires on every write
**[measured, appears 30+ times in these two transcripts]**:

> Only if there is none, write a **PERSISTED** test file — a real file such as
> `tests/test_x.py`… never an inline `python3 - << EOF` snippet.

OSA followed it, put the test beside the deliverable, verified 22 cases across both
compile paths, and reported an honest, careful, correct result — including declining to
break working code to manufacture a red run. The solution is **[inferred]** very likely
correct; it was never evaluated, because the directory listing failed first.

Note that the gate's own text already knows the risk in other episodes — on
`filter-js-from-html` OSA wrote "The broken copy lives in `/tmp` (outside `/app`), so it
can't pollute the deliverable" **[measured]** — so the concept exists but is not enforced.

**This is not a rare shape we got unlucky with twice.** Replayed over all 89 trials, **12
wrote a test artefact into a directory the instruction names as a deliverable** — the two
polyglot tasks and **10 solves** **[measured]**: `bn-fit-modify`, `build-cython-ext`,
`chess-best-move`, `distribution-search`, `extract-elf`, `merge-diff-arc-agi-task`,
`openssl-selfsigned-cert`, `path-tracing-reverse`, `pytorch-model-recovery`,
`write-compressor`. The ten survived only because their verifiers do not inspect directory
contents. The directive's default behaviour is to point a loaded gun at every
workspace-graded task; two of them happened to be loaded.

**Detectable**: no — 10 of 49 solves do the same thing, so any detector fails the
acceptance test (measured above, not assumed).

**Fixed, and unambiguously safe.** `VerificationGate` now names
`@scratch_test_dir` (`/tmp/osa-tests/`) in all three places that ask for a test file — the
first-write nudge, the small-change body and the large adequacy body — together with the
rule that nothing may land beside the deliverable, and explicit instructions for the two
artefacts the test *itself* creates (`-o /tmp/osa-tests/bin` for compiled output,
`PYTHONDONTWRITEBYTECODE=1` for the `__pycache__`). The project's own test directory still
wins when it has one.

**Why relocation and not cleanup.** Deleting the test after the discriminating run also
clears the directory, and it is strictly worse: it destroys the one property that makes
the evidence worth demanding — a check the grader, the next engineer or the next session
can run again — and it introduces a delete on a path adjacent to the deliverable, on tasks
graded by final state, at the exact moment the model is trying to stop. Moving the file
costs nothing and keeps both. `VerificationEvidence`'s `@test_dir_segments` gained the
matching `osa-tests` entry, because a gate that prescribes a location and then refuses to
recognise `check_polyglot.py` written there is the same defect as one that refuses the
red→green cycle it demanded. Rank: **6**.

### 6a. The ten solves are re-checked, and none of them is conditional (2026-08-15)

The open question above — "the ten survived only because their verifiers do not
inspect directory contents", i.e. would a stricter grader have failed them —
is now answered by measurement rather than left standing. Two findings, both
re-derivable with `bench/terminalbench/pollution_recheck.py` and pinned by
`test_conformance.py::TestDeliverablePollutionRecheck`.

**1. None of the ten is a conditional pass.** Not "their grader happened not to
look" — **none of those ten verifiers enumerates a directory at all**, resolved
by parsing every `os.listdir` / `os.walk` / `os.scandir` / `glob` / `iterdir` /
`rglob` site in each task's own `tests/` and resolving its argument to an
absolute path. All ten come back with an empty set and zero unresolved sites.
That verdict also survives the scanner's blind spot (`shell_execute` args are
clipped at 60 characters, 1,956 unreadable calls in that run): a verifier that
never lists a directory cannot fail on an artefact, seen or unseen.

Across all 89 trials, exactly **three** carry an artefact the grader could have
reached, and **none of the three is a solve**: `polyglot-c-py` and
`polyglot-rust-c` (the two known failures, artefacts in `/app/polyglot`, which
their verifiers list literally) and `filter-js-from-html` (reward 0.0; its
verifier globs `testcases_path = download_attack_vectors()`, which the resolver
cannot follow, so it is marked `CONDITIONAL-UNRESOLVED` fail-closed).

`reshard-c4-data` is the near-miss worth naming, because a coarse "does the
verifier call `listdir`" check gets it wrong. It is a **solve** that wrote
`/app/tests/test_reshard.py`, and its verifier calls both `os.walk` and
`os.listdir` — on `TEST_OUTPUT_DIR = f"/app/c4_test_{uuid.uuid4()}/"`, a
directory the verifier creates during its own run. The artefact is not in it.

Every polluted row in `runs/osa-tb20-full89-f6981b61/results.json` now carries a
`deliverable_pollution` marker recording which artefacts were left, which
directories the verifier can see, and the verdict — so the conclusion does not
have to be re-derived by hand before the number is quoted.

**2. Terminal-Bench 2.1 deleted the assertion.** Upstream classified its own
`assert polyglot_files == [...]` as a task bug. `tasks/terminal-bench-2-1/
polyglot-rust-c/tests/test_outputs.py`, verbatim:

```python
# Check that main.rs exists (dont require it to be the only file — compilation may leave binaries)
assert os.path.isfile("/app/polyglot/main.rs"), "main.rs not found in /app/polyglot"
```

and `polyglot-c-py`'s: *"The task description allows compiling to
`/app/polyglot/cmain`, so we allow additional files like compiled binaries to
exist"*. That is the correct diagnosis: the instruction's **own example command**
(`gcc /app/polyglot/main.py.c -o /app/polyglot/cmain`) writes a second file into
the directory the assertion required to hold one, and the listing check runs
*before* the verifier compiles — so any agent that verified its own work the way
the instruction demonstrates would fail on the listing.

So species 6 is a **Terminal-Bench 2.0 artefact**. The relocation to
`/tmp/osa-tests/` remains right on its own merits — an unrequested file in a
graded workspace is bad practice regardless of who checks — but it should not be
scored as having recovered two tasks on the current task set, and the "loaded
gun at every workspace-graded task" framing overstates the exposure: the only
gun in TB 2.0 was these two, and 2.1 unloaded it.

---

## 7. Species 7 — Ended on an announcement, no other cause (1 task)

`torch-pipeline-parallelism`

29 turns, 493 seconds, and the last three generations are `58, 5324, 36` output tokens —
**no truncation, no guard, no background job** **[measured]**. The transcript's ending:

```
[SAY]  I have enough understanding of the model internals... Let me verify a couple of
       defaults before writing.
[TOOL shell_execute] python3 -c "from transformers import LlamaConfig ... print(c.use_cache)"
[RESULT ok=True] AttributeError: 'LlamaConfig' object has no attribute 'attn_implementation'
                 use_cache True
[SAY]  I have enough understanding. Let me write the implementation now.
[FINAL RESPONSE] I have enough understanding. Let me write the implementation now.
[DONE]
```

Verifier: `File /app/pipeline_parallel.py does not exist` **[measured]**. The preceding
14,000 characters of reasoning contain a complete, essentially correct design of the AFAB
schedule — it worked out the microbatch shapes, the leaf-tensor handling for
`world_size=1`, and the exact `if not is_first` guard needed. It simply never got the turn
in which to write it.

This is the one case where the harness offered no visible reason to stop. It matters
because OSA's documented behaviour is auto-continue after a text-only answer
(`reference_harness_flow_comparison`), so either that path is disabled in the bench
driver, or its budget was exhausted, or a text-only response that *ends with a tool
result* is treated differently. **This was not root-caused** — it needs a look at the loop,
not at the artefacts.

**Detectable — shipped** (`announced_next_action`). **Fixable**: unknown until root-caused;
any change here is loop control flow and is out of scope for shipping. Rank: **7**.

### 7a. Root-caused, and a second instance that the first fix could not see (2026-08-16)

The "not root-caused" above is now closed. `continue_on_text_only` defaults to `false`
(`config/config.exs`), so `ReactLoop.prose_continue?/1` is false and all three of the
loop's wording-keyed continuation clauses are dead — including the one on
`Guardrails.wants_to_continue?/1`, whose regex matches "Let me write the implementation
now." That default is **correct and stays**: those clauses fire on ordinary explanatory
prose, and OSA was measured as the only harness of those studied that auto-continues after
a text-only answer by default (`reference_harness_flow_comparison`, ~5–7 extra turns per
session where the others spend 0).

The announcement backstop (21bdbc21) was added instead: announcement wording **and**
`len < 500` **and** `not talked_only?`. It postdates this run, which is why
`torch-pipeline-parallelism` shows no continuation — replayed against the recorded final
response it fires as `:interrupted_task`.

A second instance then arrived that the backstop **could** see and still did not catch —
`path-tracing` in `runs/VOID-contended-probe-minimal-04061c68`, whose binary contains
21bdbc21 (it is an ancestor of 04061c68):

```
[SAY]  I'll start by examining the image to understand what I need to reproduce.
[FINAL RESPONSE] I'll start by examining the image to understand what I need to reproduce.
[DONE]
```

One generation, 263 output tokens, **zero tool calls**, $0.00174, `turn_recap tool_calls=0`
**[measured]**. `announcement_only?/1` matches that sentence (`i'll start`, 73 chars). The
blocker was `not talked_only?` **alone**: a session that has never called a tool has,
trivially, only talked, so the conjunct written to keep the backstop off conversations also
kept it off the first turn of every task.

The distinction the backstop now encodes has two admissible shapes, and
`Guardrails.announcement_continue/2` names which one fired:

| shape | condition | instance |
|---|---|---|
| `:interrupted_task` | announcement + `len < 500` + the session ran a tool successfully | `torch-pipeline-parallelism` |
| `:unstarted_task` | announcement + `len < 200` + **no tool result at all** + the user asked for a deliverable (`deliverable_task?/1`) | `path-tracing` |

`:unstarted_task` cannot fire on a solved trial by construction — a solve produced a
deliverable, and that takes at least one tool. Replayed with
`scripts/failure_species.py` (`announced_unstarted_task`) across every run under
`bench/terminalbench/runs` with a `results.json`: **0 hits on any solved trial**, and it
fires on `path-tracing`'s recorded episode. `announced_next_action` still fires on the same
9 of 34 model failures after the `let me know` sign-off scrub was added.

Bounded at **one** nudge per turn (`ReactLoop.@max_announcement_continues`, reset by
`TurnPipeline.reset_per_turn_fields/1`). An announcement arriving with the budget spent
ends the turn and says so: `:announcement_continue_exhausted`. Both events are now on
`TuiForwarder`'s allowlist — `:announcement_continue` was Bus-only when it shipped, i.e.
absent from `osa-events.jsonl`, so a continuation could not be seen in a run artefact at
all. `Observability.turn_end/2` also carries `announcement_continues` next to `effort` and
`reasoning`.

---

## 8. Species 8 — Genuine model error (2 tasks)

- **`raman-fitting`** — fit a Lorentzian G peak. Expected
  `x0=1580.3, gamma=9.06, A=8382.69`; produced `x0=1584.6, gamma=33.1, A=74461.5`
  **[measured]**. The centre is right; the width is 3.7× and the amplitude 8.9× too large,
  which is the signature of fitting over too wide a window and/or a different amplitude
  convention. No harness lever.
- **`fix-git`** — found the dangling `Move to Stanford` commit correctly and cherry-picked
  it, then resolved the `about.md` conflict by *editorialising* ("taking the Stanford
  version… which is the newer state and also drops the now-obsolete 'looking for a job'
  line") **[measured]**. The verifier compares the file's hash to a fixture. Being helpful
  past the instruction is what lost it. Arguably a prompt-level lever ("when a task asks
  you to recover content, recover it, do not improve it"), but one task is not evidence
  enough to change the system prompt on.

---

## 9. Not evidence about anything (6 tasks)

`build-pmars`, `make-doom-for-mips`, `mcmc-sampling-stan`, `protein-assembly`,
`rstan-to-pystan` are in `TB20_UNSOUND` — the task's own reference solution fails on this
machine. `caffe-cifar-10` is in `TB20_INFRA` — the oracle wrote no reward at all. See
`bench/terminalbench/failure_shape.py:66-74`. An OSA failure on these says nothing about
OSA. `mcmc-sampling-stan` also exhibits species 1 and is counted there.

---

## 10. What was shipped, and what was not

**Shipped**: `scripts/failure_species.py`, four detectors, replayed against all 89 trials
of the reference run. Combined they match **17 trials — 16 model failures plus 1 ambiguous
— and 0 of the 49 solves** **[measured]**. The script exits non-zero if any detector ever
lands on a solved trial, so the acceptance test is enforced every time it runs.

```
$ python3 scripts/failure_species.py bench/terminalbench/runs/osa-tb20-full89-f6981b61
abandoned_background   model  configure-git-webserver   1 still running at done: /usr/local/bin/webserver.sh
...
17 trials matched a species; 0 detector hits landed on a SOLVED trial.
```

**Not shipped, deliberately**: every change to loop control flow (§4 continuation on
truncation, §5b guard predicates, §7 turn termination) and every change to prompt text
(§1, §3, §6) — prompt files are owned by a concurrent agent this session. They are
specified above, ranked, and left for a separate change.

**Rejected detectors**, recorded so they are not re-derived: green-self-written-test claim
(24/34 failures but 31/49 solves), `len(final_response) < N` for N in 200…600 (fires on
solves at every threshold), and the prior work's s/turn and reasoning-chars proxies.
Length alone carries no signal; the *wording* of the final message does.

---

## 11. The one-line answer to the brief's question

The remaining 13.4-point gap to cline is **not** mostly GLM-5.2 capability. Sixteen of 34
failures are episodes OSA ended or spoiled itself, and they are concentrated in a handful
of small, nameable places — one tool-prompt paragraph, one process-lifetime decision, one
unhandled provider stop reason, two mis-specified guards, and one reminder that puts test
files in the wrong directory. The genuinely hard residue is nine tasks where OSA proved
the wrong proposition to itself with a real red→green cycle, and that one has no detector
— only a design change about where an oracle is allowed to come from.
