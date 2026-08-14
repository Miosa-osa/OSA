# Turn-count diagnosis

**Date**: 2026-08-14 · **Repo state**: `1a542dbf` on `main` · **Author**: diagnosis pass, no code changed.

**Sources** (all read-only, already on disk):
`bench/headtohead/runs/h2h-1/` (5 arms × 6 Terminal-Bench 2.0 tasks, model held fixed at `glm-5.2:cloud`),
`bench/terminalbench/runs/*/` (52 OSA task runs with `agent/osa-events.jsonl`),
plus `lib/optimal_system_agent/agent/loop/**` for the machinery claims.

Every number below is labelled **[measured]** (counted from an artefact or read off a
literal in the source) or **[inferred]** (a model or judgement built on measurements).
Nothing was run; no benchmark, no release, no test suite.

---

## 0. Headline: the premise is wrong, and that is the most valuable finding here

The brief's hypothesis was: *OSA takes 3–5× the turns, that is flailing, and flailing is
the shared root of the capability gap.*

**The artefacts refute it.** Turn counts on the six head-to-head tasks, same model, same
limits **[measured]**:

| task | **OSA** | codex | mini-swe-agent | opencode | solved by |
|---|---:|---:|---:|---:|---|
| regex-log | 13 | 8 | 8 | 9 | all |
| configure-git-webserver | 10 | 14 | **49** | 26 | osa, codex, mini |
| largest-eigenval | 21 | 21 | **87** | 34 | osa, codex, goose, mini |
| sparql-university | 21 | 25 | 13 | 6 | all |
| cancel-async-tasks | 13 | 14 | **56** | 9 | codex, mini |
| schemelike-metacircular-eval | **277** | 60 | **246** | 32 | codex, opencode, mini |
| **total** | **355** | **142** | **459** | **116** | |
| **total excl. schemelike** | **78** | **82** | **213** | **84** | |

(OSA turns = `llm_response` events with `duration_ms != 0` in `osa-events.jsonl`;
competitor turns = `source: agent` steps in the ATIF `trajectory.json`.)

Read the last row. **Excluding one task, OSA takes 78 turns where codex takes 82 and
opencode 84.** And the harness that beat us 6/6 — mini-swe-agent — took **213**, nearly
3× OSA, on those same five tasks. It took 56 turns on `cancel-async-tasks` and solved it;
OSA took 13 and got it wrong.

Across all 52 OSA runs on disk **[measured]**: median 31 turns, mean 51.5, p90 120, max 305.
Split by outcome (40 runs with a graded `verifier_result`):

| outcome | n | median turns | mean | range |
|---|---:|---:|---:|---|
| solved (reward 1.0) | 22 | 28 | 37.3 | 10 – 175 |
| not solved | 18 | 26 | 52.1 | 0 – 277 |

The medians are the same. `path-tracing` was **solved at 175 turns** and again at 75.
`sparql-university` was **failed at 8 turns** and solved at 21 and 31. Turn count does
not predict solving in the body of the distribution; only the extreme tail (277, 154,
120) is both long and failing, and the extreme *short* tail (2, 8, 13) is failing too.

**Honest conclusion**: turn count is a real and severe *cost* driver (§3) and there is a
real *runaway* pathology confined to a handful of tasks (§2), but it is **not** the shared
root of the capability gap. The capability gap has a different, concrete cause, and the
artefacts show it plainly (§5). Cutting turns as a capability strategy would be the false
victory the brief warned about — the harness that beat us takes *more* turns than we do.

---

## 1. Where the turns go — categorised

Aggregate over all 52 OSA runs **[measured]**: 2,678 turns, 2,797 tool calls.

| metric | value | note |
|---|---:|---|
| tool calls per turn | **1.04** | OSA essentially never batches |
| exact-duplicate tool calls (same name + byte-identical args, anywhere in session) | **701 / 2,797 = 25.1%** | |
| permission denials (`outside allowed read paths`) | 142 | 2.7 per run |
| shell calls shuttling files through `/root/.osa/workspace` | 113 | see §2.3 |
| `hook_run` events | 33,518 = **12.5 per turn** | overhead, not turns |

Duplicate rate, same six tasks, same model **[measured]**:

| arm | exact-duplicate tool calls |
|---|---|
| codex | **1 / 140 (0.7%)** |
| mini-swe-agent | 34 / 459 (7.4%) |
| **OSA** | **157 / 361 (43.5%)** |

That 43.5% is dominated by one task; excluding `schemelike`, OSA is 5/84 (6%) — in line
with mini. So duplication is not a constant tax, it is a **failure mode that switches on**.

### 1.1 Work per turn — the one metric where OSA is uniformly behind

Size of the arguments of each tool call, in bytes, same six tasks **[measured]**:

| arm | n calls | median | mean | p90 | max |
|---|---:|---:|---:|---:|---:|
| **OSA** | 361 | **62** | 156 | 389 | 3,071 |
| codex | 140 | 286 | 635 | 1,564 | 8,091 |
| mini-swe-agent | 459 | 351 | 742 | 1,549 | 10,523 |
| opencode | 185 | 144 | 570 | 1,258 | 11,289 |

Output tokens per turn on `schemelike` **[measured]**: OSA 431, mini 695, codex 1,008.

**OSA's median tool call carries 62 bytes of argument — 4.6× smaller than codex's, 5.7×
smaller than mini's — and it issues 1.04 of them per turn.** OSA takes small bites. On the
one task where the work is large, 4.6× smaller bites × the same amount of work ≈ 4.6× the
turns, which is very close to the observed 277 vs 60 **[inferred]**.

---

## 2. The runaway: `schemelike-metacircular-eval`, 277 turns, 32.5M input, unsolved

This single task is 78% of OSA's turns and **91% of OSA's input tokens** across the whole
head-to-head **[measured]**. Its 277 tool calls decompose into 125 unique signatures and
**152 exact repeats**. The top repeats **[measured]**:

```
59 ×  file_read     "/root/.osa/workspace/eval.scm"            (byte-identical args)
44 ×  shell_execute "cp /root/.osa/workspace/eval.scm /app/eval.scm && cd /app && ..."
27 ×  shell_execute "cd /app && python3 -c \"lines = open('/root/.osa/workspace/e..."
 7 ×  file_write    "eval.scm"
 7 ×  file_grep     "/root/.osa/workspace/eval.scm"
 3 ×  file_read     "/root/.osa/tool-results/...__file_read.txt"
```

### 2.1 The loop is `read(X) → edit(X) → read(X) → edit(X) → …`

Reconstructed action stream, mid-run **[measured]**, abridged:

```
file_read  /root/.osa/workspace/eval.scm
file_edit  {…old_string/new_string…}
  "Now there's a stray blank line…"
file_read  /root/.osa/workspace/eval.scm
file_edit  {…}
  "Now copy and test:"
shell_execute cp /root/.osa/workspace/eval.scm /app/eval.scm && cd /app && …
  …
file_read  /root/.osa/workspace/eval.scm
file_read  /root/.osa/workspace/eval.scm     ← twice in a row, same args
file_edit  {…}
```

`file_read` here carries **no offset/limit** — every one of the 59 reads pulls the whole
of a growing file back into context.

### 2.2 All three loop detectors are structurally blind to it

- `IdenticalCall` (`lib/optimal_system_agent/agent/loop/doom_loop/identical_call.ex:64-96`)
  halts on a **consecutive streak** of ≥4 identical `{name, phash2(args)}`. The observed
  loop interleaves an `file_edit` between every pair of reads, so the streak never exceeds 2.
  **It never fired: `doom_loop_halt` appears 0 times in the log** **[measured]**.
- `Stall` (`doom_loop/stall.ex:76-85`) requires `not introduced_new_tool? and not
  wrote_or_edited? and not investigated?` over a 12-call window. `file_read` is in
  `@progress_tools` (`stall.ex:34`) and `file_edit` is in `@write_edit_tools`
  (`stall.ex:26`), so a read↔edit loop scores as *both* investigating *and* writing.
  Never stalled.
- `FailureSignature` needs repeated *errors*. These calls all succeed.

### 2.3 Two structural amplifiers, both OSA's own doing

**(a) The path allowlist forces a shadow workspace.** The first two tool calls of that run
**[measured]**:

```
dir_list  /app    → "Error: Permission denied: Access denied: /app is outside allowed read paths"
file_read /app/interp.py → same denial
```

(`lib/optimal_system_agent/tools/builtins/dir_list/handler.ex:48`,
`.../file_read/handler.ex:59`.) The agent responds by working in
`/root/.osa/workspace/eval.scm` and `cp`-ing to `/app` before every test — **44 shuttle
calls in this run, 113 across all runs** **[measured]**. Codex works directly in `/app`
and needs none. 142 denials across 52 runs, by tool: `file_write` 48, `file_read` 45,
`dir_list` 41, `file_edit`/`file_glob` 3 each, `web_fetch` 2.

**(b) Tool results are spooled to disk and read back.** Opening sequence **[measured]**:
`file_read /app/interp.py` (denied) → `shell_execute cat /app/interp.py` → `file_read` →
then **four** `file_read` calls against
`/root/.osa/tool-results/…__file_read.txt`, one of which returns the same file again with
line numbers prefixed. The same 17.5 KB file entered context at least three times in the
first eight tool calls.

**(c) `success` is always `true`.** Every `tool_result` in the runaway carries
`"success": true`, including the permission denials, whose payload is the string
`"Error: Permission denied…"` **[measured]**. Nothing downstream — gates, retries,
failure-signature detection — can distinguish a denial from a success.

### 2.4 The stall detector fires constantly and is configured never to act

The bench driver sets `permission_mode overdrive` before the first prompt
(`osa-driver.log`: `overdrive -> HTTP 200`). `Stall.hard_halt?/1`
(`doom_loop/stall.ex:129-133`) is:

```elixir
Application.get_env(:optimal_system_agent, :stall_hard_halt, true) and
  Map.get(state, :permission_mode) != :overdrive and
  Map.get(state, :permission_tier) != :auto
```

so under overdrive it is escalate-only. Measured across all runs **[measured]**:

| task run | "Stall detected" | "Graded escalation" | halts |
|---|---:|---:|---:|
| path-tracing (175 turns) | 81 | 3 | **0** |
| make-mips-interpreter (154) | 63 | 3 | **0** |
| polyglot-rust-c (54) | 37 | 3 | **0** |
| password-recovery (48) | 25 | 3 | **0** |
| …9 more runs | 2–18 | 3 | **0** |

Driver telemetry agrees: `self_inflicted={'stall_detector': 247}` on the 305-turn run,
`{'stall_detector': 95}` on a 162-turn run, `81` on the 175-turn one **[measured]**.
Escalation caps at 3 nudges (`doom_loop/escalation.ex:26`) and after that **hundreds of
consecutive no-progress detections produce no action at all**.

---

## 3. Cost is quadratic in turns, not linear — the "30k prefix × 94 turns" model is wrong

Per-turn input tokens grow monotonically. Modelling total input as
`turns × (first_turn_input + last_turn_input) / 2` predicts the measured total within
5% on every head-to-head task **[measured]**:

| task | turns | measured input | first turn | last turn | trapezoid prediction |
|---|---:|---:|---:|---:|---:|
| cancel-async-tasks | 13 | 302,897 | 21,287 | 25,889 | 306,644 |
| configure-git-webserver | 10 | 226,584 | 21,169 | 23,338 | 222,535 |
| largest-eigenval | 21 | 509,256 | 21,217 | 28,089 | 517,713 |
| regex-log | 13 | 432,213 | 21,392 | 36,448 | 375,960 |
| sparql-university | 21 | 590,011 | 21,566 | 34,219 | 585,742 |
| **schemelike** | **277** | **32,486,024** | 21,452 | **201,112** | **30,825,114** |

**Consequence [inferred]**: input cost scales as roughly O(turns²) once the transcript
dominates the static prefix. Halving turns on a long task cuts cost ~4×, not 2×. It also
means the static-prefix work (the other agent's) caps out at a ~21k floor per turn — real
on short tasks (21k of 23k = 90% of turn-1 input) and marginal on the runaway (21k of
117k average = 18%).

---

## 4. Machinery audit — each candidate confirmed or refuted

Verified against source; file:line given.

| candidate | verdict | evidence |
|---|---|---|
| **Auto-continue after a text-only answer** | **REFUTED — already off** | `continue_on_text_only` defaults `false` (`react_loop.ex:96-104`, `config/config.exs:86`). With it off, a text-only answer hits `finish_turn` at `react_loop.ex:910`. The two nudge clauses it gates (intent-narration, cap 2, `react_loop.ex:720-743`; code-in-markdown, cap 3, `:745-765`) are dead by default. The prior "5–7 extra turns" finding no longer applies. |
| **Zero-tool gate** | bounded, and off by default | `@max_zero_tool_gate_prompts 1` (`react_loop.ex:63`), *and* additionally gated by `continue_on_text_only`. Max 1 extra turn, currently 0. |
| **Grounded verification gate** | on by default, cap 2, **and it is being satisfied by weak evidence** | `verification_gate.ex:51` `@max_reprompts 2`; trigger at `:76-83`. Worst case +2 turns — negligible for cost, but see §5: it passes on any exit-0 shell command touching the changed file, including a self-authored throwaway probe. |
| **Reasoning-only backstop** | cap 3 | `doom_loop/reasoning_only.ex:35`. |
| **Post-compaction auto-continue** | on by default, fires **exactly once** | `proactive_compaction.ex:796-798`. ≤1 turn. |
| **Stop-hook continue** | cap 5, one branch unguarded | `react_loop.ex:1814`, `:1829`; the `%{continue: true, message: msg}` branch at `:1847-1850` increments the counter but never checks it. Not observed in bench artefacts. |
| **Retries** | small and bounded | max_tokens bump ≤2 (consumes an iteration, `react_loop.ex:506,546`); context-overflow ≤3 (does *not* consume one, `:1485`); idle-timeout ≤2 (consumes, `:1428,1539`); tool-arg REASK ≤2 (`tool_arg_validator.ex:28`); in-tool transient retry 3 attempts, no iteration (`tool_retry.ex:43-48`); doom-loop resample ≤2 (`doom_loop/resample.ex:42-43`). Truncated-tool-call re-emit (`react_loop.ex:568-675`) is **unbounded** and consumes an iteration — a latent risk, not observed in these artefacts. Aggregate observed: `self_inflicted` shows `provider_error: 2` on one run, `crash: 4` on another, `compaction/context_window_exceeded: 1` on a third **[measured]**. Retries are **not** a material turn driver. |
| **Subagent/delegate round-trips** | not a factor here | Background by default (`tools/builtins/delegate/handler.ex:271-289`); results fold into the parent turn. **Exactly one `delegate` tool call appears across all 52 bench artefacts** (in
`recoverybench/runs/delta-01/corrupted/…/schemelike-metacircular-eval__DYYw2S6`) **[measured]**. |
| **Turn/iteration limits** | **do not bind — confirmed still true** | `max_turns` and `max_budget_usd` both default `nil` = off (`loop/limits.ex:19-22`). Per-turn ReAct ceiling is `max_iterations: 10_000` from `config/config.exs:63`, which wins over the effort ladder (medium = 100, `effort.ex:40`). The 277- and 305-turn runs ended on the **harness's 1800 s wall clock** (`status=timeout`), not any OSA limit; every other run ended voluntarily. |
| **Loop detection** | present, and blind to the actual loop | §2.2. `doom_loop_halt` fired **0 times** in **0** of the 52 runs **[measured]**. |

---

## 5. What codex does in 60 turns that takes us 277 — and what mini does that we don't

### 5.1 codex on `schemelike-metacircular-eval` (60 tool calls, 0 duplicates, solved)

Its actual command sequence **[measured]**:

1. `ls -la /app && echo "---TESTS---" && ls -la /app/test/` — two questions, one call.
2. `cat /app/interp.py`, then `sed -n '180,420p' /app/interp.py` — targeted second look.
3. **Four batched reads**: `for f in <8 .scm files>; do …; done` — 26 test files in 4 calls.
   OSA read them two at a time.
4. **One 7,838-character heredoc**: `cat > /app/eval.scm << 'SCHEMEEOF' …` — the entire
   metacircular evaluator written in a **single tool call**. OSA built the same artefact
   with 66 `file_edit`/`file_write` calls, each preceded by a full re-read of the file.
5. **Every subsequent edit is a self-contained script**:
   `cd /app && python3 - << 'PY'` / `src=open('eval.scm').read()` / `old="…" new="…"` /
   write back. **The file content never enters the model's context to be edited.** That is
   why codex's context ends at 94k while OSA's ends at 201k.
6. **A persistent test harness**: `cat > /tmp/check.sh` (a loop over `test/*.scm` counting
   pass/fail), then `bash /tmp/check.sh 2>&1 | tail -5`. One call gives the whole suite
   status. OSA ran individual scheme snippets by hand, dozens of times.
7. Waits on background work with `sleep 20` / a `yield_time_ms` call instead of polling.

**The single-sentence version**: codex uses the shell as its editor, so a file edit costs
one call and zero context; OSA uses fine-grained read/edit tools, so every edit costs a
full file read into context plus an edit plus (here) a `cp` shuttle.

### 5.2 mini-swe-agent on `cancel-async-tasks` — the actual capability gap

This is the more important comparison, because OSA *failed* this task in **13 turns** and
mini *solved* it in **56**.

**OSA (12 tool calls, 106 s, wrong)** **[measured]** — full sequence:
```
shell   python3 --version && ls /app/
dir_list /app                                    ← denied
shell   ls -la /app/
file_write /app/run.py
shell   cat > /app/run.py << 'PYEOF' …           ← rewrote it via shell anyway
shell   cat /app/run.py
shell   cd /app && python3 - << 'PYEOF' …        ← throwaway inline probe
shell   cd /app && python3 - << 'PYEOF' …        ← throwaway inline probe
shell   cat > /app/run.py << 'PYEOF' …
shell   cd /app && python3 - << 'PYEOF' # Re-examine…
shell   cd /app && python3 - << 'PYEOF' …
shell   python3 -c "from run import run_tasks; import inspect…"
FINAL:  "…**Verified:** concurrency cap respected (peak=4 with 20 tasks/limit 4), error propagati…"
```

**mini (56 tool calls, 351 s, correct)** **[measured]** — first 20:
```
write /app/run.py
write /tmp/test_run.py            ← a persistent test file
rewrite /app/run.py
run   python3 /tmp/test_run.py
rewrite /app/run.py
run   python3 /tmp/test_run.py
write /tmp/test_ki.py             ← a real KeyboardInterrupt test
inspect CPython: inspect.getsource(asyncio.runners.Runner…)   ← twice
inspect asyncio.base_events source
rewrite /app/run.py (adds signal handling)
run   python3 /tmp/test_ki.py; echo "EXIT CODE: $?"
rewrite /app/run.py
run   python3 /tmp/test_ki.py; echo "EXIT CODE: $?"
write /tmp/test_ki2.py
write /tmp/test_real_ki.py        ← "test real keyboard interrupt scenario"
…
```

OSA wrote **zero** persistent test files and ran **five throwaway inline probes**, then
declared "Verified". mini wrote **four** named test files, read CPython's `asyncio`
source to understand the mechanism it was being asked to implement, and iterated
write→test→fix four times.

**And OSA's grounded verification gate passed this.** `VerificationEvidence`
(`verification_evidence.ex:1-38`) asks "did a check exit 0 and touch the changed file".
OSA's throwaway `python3 - << PY` probes exited 0 and imported `run.py`, so
`failing_check_since_write` was `nil` and `pending_files` was empty. The gate is a
**liveness** check ("something ran and passed"), not an **adequacy** check ("the thing
that ran actually exercises the requirement"). It is trivially satisfied by a probe the
model wrote to satisfy it.

**This — not turn count — is the capability gap [inferred, but strongly evidenced]**: on
the two tasks OSA lost head-to-head, it stopped early with a self-certified shallow check,
while both winners built durable test harnesses and kept iterating against them.

---

## 6. Ranked changes

Ordered by (turn/cost saving) ÷ (capability risk). **Nothing in this list has been
implemented.** Items 1–4 reduce turns and cost with little or no capability downside;
items 5–7 are capability work that will *increase* turns, and I believe they are the ones
that move solve rate.

### Tier A — turn/cost reduction, low capability risk

**A1. Widen `IdenticalCall` from a consecutive streak to a windowed counter.**
Currently `identical_call.ex:64-96` only sees back-to-back repeats, so the 59× read loop
was invisible. Change: count occurrences of `{name, args_hash}` within a sliding window
(say 20 calls); nudge at 3, halt at 5 — *unless* the file's `{mtime,size}` changed since
the last identical call, in which case the re-read is legitimate.
*Estimated saving*: 152 of 277 calls on the runaway; ~700 of 2,797 calls (25%) fleet-wide,
though only ~5% outside the runaways **[inferred]**. On a quadratic cost curve, cutting
the runaway from 277 to ~140 turns cuts its 32.5M input to ~9M **[inferred]**.
*Risk*: **low-to-moderate**. A legitimate re-read after an edit must not be blocked —
hence the mtime/size exemption, which `FileState` (`tools/file_state.ex:95,111-123`)
already tracks. Without that exemption the risk is real and this becomes Tier B.

**A2. Make `file_read` return a diff-or-nothing when content is unchanged since the
session's last read of that path.** `FileState` already records `{mtime, size}` per
`{session, path}`. If unchanged, return `"unchanged since your read at <turn N>; content
is already in context"` instead of the bytes.
*Estimated saving*: this alone removes most of the 59-read cost on the runaway and is the
single biggest lever on the quadratic context growth, because it stops re-injecting a
growing file **[inferred]**.
*Risk*: **moderate**. If the model genuinely lost the content to compaction, this
starves it. Mitigation: bypass whenever a compaction has occurred since the recorded read.
This needs the mitigation designed before it ships.

**A3. Fix the `/app` path denials.** 142 denials across 52 runs, and — worse — they push
the agent into a shadow-workspace + `cp` pattern that cost 44 extra calls on the runaway
and 113 fleet-wide. The task's own working directory should be in the read/write allowlist.
*Estimated saving*: ~255 tool calls fleet-wide (~9%), plus removal of a whole class of
confusion **[measured for the call counts, inferred for the confusion]**.
*Risk*: **low on the benchmark, non-trivial in general** — this is a sandbox boundary and
loosening it is a security decision, not a performance one. Design it as "the session's
declared working root is allowed", not "allowlist off".

**A4. Make `tool_result.success` truthful.** Every denial and error currently reports
`"success": true` with an `"Error: …"` string payload. This silently disables
`FailureSignature` detection, corrupts the verification ledger, and makes every downstream
gate unable to tell a denial from a result.
*Estimated saving*: 0 turns directly; it is the **precondition** for A1, A5 and any
honest instrumentation **[inferred]**.
*Risk*: **low** in principle, but it changes what several gates see, so it needs its own
test pass. It is the highest-value item per unit of risk and I would do it first.

**A5. Make an exhausted stall do *something* under overdrive.** `stall.ex:115-119`
currently logs "escalate-only, continuing" — 247 times in one run, 81 in another, with
zero effect after the third nudge. Not necessarily a halt: a *checkpoint* (force a written
plan, or a compaction, or a switch to a different tool family) would be the
capability-preserving version.
*Risk*: **moderate**. A hard halt here is exactly the "give up earlier" trap. Halting is
not recommended; escalating differently is.

### Tier B — reduce turns by increasing work per turn (design, do not ship blind)

**B1. Encourage larger, self-contained tool calls.** OSA's median tool-call argument is
62 bytes against codex's 286 and mini's 351; OSA emits 431 output tokens per turn against
codex's 1,008. The fix is prompt/tool-affordance work — **explicitly the other agent's
territory** (SYSTEM.md, tool descriptions, schemas) — so this is recorded here as a
measurement to hand over, not a change to make.
*Estimated saving*: if OSA's bite size matched codex's, the 277-turn task is ~60 turns and
~3.5M input tokens **[inferred, by direct proportion — treat as an upper bound]**.
*Risk*: **moderate**. Bigger bites mean bigger blast radius per mistake.

**B2. Batch-read affordance.** Codex read 26 test files in 4 calls via `for f in …; do`.
OSA has no multi-read and read them 2 at a time. A `file_read` accepting a list of paths,
or a documented batch idiom, is a pure win on exploration turns.
*Risk*: **low**, but it is a schema change — coordinate with the schema owner.

### Tier C — the capability work (will *increase* turns; do it anyway)

**C1. Make the verification gate check adequacy, not liveness.** Today any exit-0 command
touching a changed file satisfies it (`verification_evidence.ex`), which is how OSA
self-certified a wrong `cancel-async-tasks` answer in 13 turns. Design: require the check
to be a **persisted artefact** (a file on disk that can be re-run), not an inline
heredoc; and require it to have *failed at least once* before passing, which is the
cheapest available proxy for "this test actually tests something".
*Estimated effect*: **+10 to +40 turns per task** **[inferred]**, and it is the change
most likely to move solve rate, because it converts OSA's failure mode (stop early,
self-certify) into mini's success mode (build a harness, iterate).

**C2. Reward reading the dependency's source.** mini read CPython's `asyncio.runners`
source before implementing against it; OSA never did on any task in these artefacts.

### Explicitly *not* recommended

- Any turn cap. `max_turns` is off and that is correct: `path-tracing` was solved at 175
  turns. A cap set anywhere below 175 would have converted a solve into a fail.
- Hard-halting on stall. Same reason.
- Re-enabling or tuning `continue_on_text_only`. It is already off; it is not the problem.

---

## 7. What I did not implement, and why

**Nothing.** The brief authorised shipping only changes that are *unambiguously* safe and
clearly evidenced, with the auto-continue as the example. That example turned out to be
already disabled (`config/config.exs:86`), so the one pre-authorised change does not exist.

Every remaining item either changes what the model sees (A1, A2, B1, B2, C1), changes a
security boundary (A3), or changes what several gates observe (A4, A5). None is
unambiguously safe. They are designed and ranked above for a decision.

## 8. Caveats on this diagnosis

- n = 6 tasks in the head-to-head, 1 attempt each. Every arm's confidence interval is
  wide enough to contain every other arm; the run's own report says so. The turn-count
  *comparison* is far more robust than the solve-rate comparison, because turn counts are
  not a Bernoulli draw — but a single 277-turn outlier still drives most of the aggregate.
- The 52 OSA runs span several code versions (v1.0.96 and earlier) and several bench
  configs. The distribution in §0 mixes them.
- Competitor turn counts come from their ATIF `trajectory.json`; OSA's come from
  `llm_response` events. These are close analogues but not identical definitions.
- goose produced 1-step trajectories (it never reached the model on 3 tasks) and is
  excluded from every turn comparison.

---

# CORRECTION (2026-08-14, implementation pass on A1/A2/A5)

**Read this before acting on §1, §1.1, §2 or B1 above. Those sections measure a
display field, not the agent.**

## The instrument, not the system

`osa-events.jsonl` `tool_call.args` is **not** the tool's arguments. It is
`Agent.Loop.ToolHint.summarize/1` (`lib/optimal_system_agent/agent/loop/tool_hint.ex`),
the one-line hint the TUI prints next to a tool name, and it is lossy by design:

* `shell_execute` is hard-clipped to **60 characters** (`tool_hint.ex:85`).
  In the `schemelike` run, **all 134** shell args are <= 60 chars and **127 are
  exactly 60**, visibly cut mid-path (`"cat /app/test/calculator.scm … /app"`)
  **[measured]**.
* `file_read` renders **only the path**; `offset` and `limit` are dropped
  entirely **[measured]**.

Competitor arms were counted from their ATIF `trajectory.json`, which carries
full arguments (codex: max 8,174 chars, **zero** entries at 60) **[measured]**.
So the head-to-head duplicate comparison hashed OSA's clipped display strings
against codex's real arguments.

## What that invalidates

| claim | status |
|---|---|
| §1 "OSA 43.5% duplicate calls vs codex 0.7%" | **invalid** — different fields compared |
| §2 "59 × `file_read` … byte-identical args" | **invalid** — see below |
| §1.1 "OSA's median tool call carries 62 bytes of argument" | **invalid** — the median is 62 because the log clips at 60 |
| B1 "OSA takes small bites" (handed to the prompt owner) | **unsupported by this evidence**; may still be true, but is not measured here |
| §2.4 / A5 stall counts (95, 63, 31, 22 …, escalations always 3, halts always 0) | **confirmed** — read from log lines, independent of `args` |
| §3 quadratic cost model | **unaffected** — token counts, not args |

## Re-measured, on the same run

Recovering the true read windows from the `tool_result.result` payloads (which
*are* recorded faithfully), the "59 identical reads" are **49 distinct offset
windows**, and **not one of them returned bytes identical to a previous read**
**[measured]**. They are a file being read in slices as it grows, not a loop.

Requiring a duplicate to have a byte-identical **result** as well as the same
displayed args:

| metric | naive (diagnosis method) | corrected |
|---|---:|---:|
| tool calls | 277 | 277 |
| exact repeats | **152 (54.9%)** | **26 (9.4%)** |
| of which `file_read` | 59 | **0** |
| of which `shell_execute` | 71+ | 24 |

The largest corrected cluster is 15 × `cp <ws>/eval.scm /app && cd /app && <test>`
— all returning **empty output** **[measured]**. Silent or waiting, not looping.

## Consequence for A1/A2

Both were implemented, tested and shipped, but their measured yield on this
corpus is **zero**, and they must not be described as turn-reduction levers:

* **A2** (`file_read` returns "unchanged") would have suppressed **0** of the 59
  reads, because no read repeated a window with unchanged bytes.
* **A1** (windowed identical-call), replayed over **all 52 runs**: **0 halts**,
  4 nudges, **0 solved runs halted**. It is a correctly-built backstop for a
  pathology this corpus does not contain.

Two findings from building them that *are* load-bearing:

1. The mtime/size exemption specified in A1 is **too weak**. The right change
   signature is the **result bytes**: it covers `read -> edit -> read` *and*
   `test -> fix -> test` (identical `shell_execute`, changing output), which a
   stat-based exemption cannot see at all.
2. **Waiting must be exempt.** A first cut without it halted `train-fasttext` at
   call 39 of 66, mid-wait on a training job (`sleep 90` × 8 and `bash_output`
   × 6, all returning `""`). That is exactly the "fewer turns, fewer solves"
   trap. The pre-existing *consecutive* rule had the same hole — 4 consecutive
   `bash_output` polls halted the session — and is now gated too.

## Recommended next step (not done here)

Emit a digest of the **real** arguments alongside the display hint in the
`tool_call` event, so duplicate rate becomes measurable at all. The natural site
is `Agent.Loop.ToolExecutor.tool_call_hint/1` (`tool_executor.ex:1694`). Not
done in this pass: that file was being edited concurrently by another agent.

Until then, **no duplicate-rate number from `osa-events.jsonl` is trustworthy**,
and neither is any argument-size comparison against another harness.
