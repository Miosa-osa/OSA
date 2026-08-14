# Competitor techniques: what codex, opencode and mini-swe-agent actually do

**Date** 2026-08-14 · **Repo state** `aee4fe54` on `main`, working tree mid-flight ·
**Scope** study + design, plus one shipped instrumentation fix (§8).

Companion to `turn-count-diagnosis.md`, which established that turn count is a cost
driver but not the capability gap. This document answers the follow-on question — *what
did codex do in 60 turns that took us 277* — from competitor source and from benchmark
artefacts, and it **corrects two of that document's headline numbers**.

---

## 0. Evidence rules, because two instruments have now lied

Every number below is labelled with the artefact and the **field** it came from. That is
not ceremony. Two of the numbers this workstream was launched on were artifacts of
reading the wrong field, and the failure was invisible precisely because the number was
plausible and unflattering.

| source | fidelity | what it is |
|---|---|---|
| codex `rollout-*.jsonl` | **faithful** | full `arguments` JSON per call, plus verbatim `base_instructions` |
| opencode / mini ATIF `trajectory.json` | **faithful** | full `arguments` per call |
| mini `mini-swe-agent.trajectory.json` | **faithful** | full message list *and* the resolved config, including every prompt template |
| OSA `osa-telemetry.json` | **faithful** | provider usage totals, turn count |
| OSA `osa-events.jsonl` → `tool_call.name` | **faithful** | tool name |
| OSA `osa-events.jsonl` → `tool_call.args` | **NOT faithful** | `ToolHint.summarize/1`, a TUI display string |

`ToolHint` (`lib/optimal_system_agent/agent/loop/tool_hint.ex`) clips a shell command to
60 characters (`:85`) and reduces every file tool to its bare path (`:80-82`). It returns
full JSON for exactly one tool — `file_edit`, because the TUI renders a diff from it
(`:33-38`). So of OSA's whole tool surface, **`file_edit` is the only tool whose real
argument size was ever in the log.**

### 0.1 The two corrections

**"OSA's median tool-call argument is 62 bytes against codex's 286" — withdrawn.**
Measured over the 191 `shell_execute` calls in the head-to-head, the *maximum* logged
argument is exactly 60 bytes; `file_write`'s maximum is 30. A 7 KB file write was
recorded as `"eval.scm"`. The competitor figures came from full argument JSON. The two
numbers never described the same quantity.

**"43.5% duplicate tool calls against codex's 0.7%" — withdrawn.** Hashing the hint
collapses calls that differ only in a clipped field: 49 `file_read` calls reading 49
different offset windows of one growing file hash identically once `offset`/`limit` are
dropped. Re-measured against real arguments, `schemelike` has 26 exact repeats (9.4%),
none of them a `file_read`.

### 0.2 What survives, and it is still a large gap

Both corrections were in OSA's favour. Neither touches the finding that matters.

| metric, `schemelike-metacircular-eval` | OSA | codex | opencode | source |
|---|---:|---:|---:|---|
| turns | **277** | 60 | 32 | telemetry / rollout / ATIF |
| tool calls | **277** | 60 | 61 | ” |
| tool calls per turn | 1.00 | 0.99 | **1.91** | ” |
| **write operations on the artefact** | **66** | **12** | **4** | tool names / cmd classification |
| input tokens | **32,486,024** | 3,659,747 | 1,781,797 | provider usage |
| output tokens | **119,451** | 60,482 | 52,480 | ” |
| output tokens per turn | 431 | **1,008** | 1,590 | derived |
| peak context | **201,112** | 94,616 | — | ” |
| cost | **$19.75** | — | — | spend sidecar |
| solved | no | yes | yes | `reward.txt` |

Read the write-operations row, not the argument-size row. **OSA emitted twice codex's
total output tokens and nine times its input, and the single thing it did 5.5× more of
was write to the file.**

And OSA's edits are *not* small. `file_edit` argument sizes — the one faithful figure we
have — are **n=58, median 506 bytes, mean 678, max 2,927**. Codex's median *call of any
kind* is 310 bytes. Per edit, OSA writes more than codex writes per call. The gap is
entirely in how many times it does it.

---

## 1. Big-bite editing — what the winners actually do

### 1.1 codex: the shell is the editor, and programs answer questions about files

Classifying all 56 `exec_command` calls in codex's winning run by what the command does
(`cmd` string, faithful):

| class | calls | sizes |
|---|---:|---|
| run / test / build | 22 | — |
| **python heredoc, diagnostic only** | **12** | 174–714 B |
| read / inspect (`cat`, `sed -n`, `for f in …`, `nl`) | 10 | — |
| **`cat > file << 'EOF'` whole-file write** | **8** | **7,838**, 1,082, 781, 559, 528, 277, 263, 241 B |
| **python heredoc, read-modify-write edit** | **4** | 458–2,978 B |

Three mechanisms fall out, and only the first was previously identified.

**(a) One whole-file write instead of incremental construction.** The 7,838-byte heredoc
is the entire metacircular evaluator in one call. Seven smaller rewrites follow. Codex
never *builds* the file edit-by-edit; it writes a version, tests it, and writes another
version.

**(b) Edit by program, so the file never enters context.** The four script-edits are
read-modify-write in the sandbox:

```
cd /app && python3 - << 'PY'
import re
src=open('eval.scm').read()
old="(define (caddddr p) (car (cdr (cdr (cdr (cdr p)))))\n"
assert old in src, "not found"
src=src.replace(old,"")
open('eval.scm','w').write(src)
print("removed")
PY
```

The model spends ~200 bytes of context to delete a line from a file it is not holding.
The `assert` is the correctness gate — it fails loudly rather than silently mis-editing.
Note also that this single call contains **two** heredocs: the edit and a re-check.

**(c) The one nobody spotted: codex wrote a static analyser and ran it twelve times.**
Twelve of the sixteen python heredocs never write anything — they are paren-balance
checkers and structure probes over `eval.scm`. Codex answers *"is my file well-formed?"*
by running a program over it, and gets back the single word `balance: 0`. OSA answers
the same question by reading the file back into context. **That, not the heredoc, is why
codex's context ended at 94k and OSA's at 201k.**

This is not "codex uses bigger arguments". It is *codex converts questions about file
state into programs whose output is small and whose input is free.*

### 1.2 opencode: fine-grained tools, and still only four writes

opencode is the more instructive comparison because it is a tool-calling harness like
OSA, not a bash loop — and it beat codex on turns.

Measured (ATIF, faithful): 32 agent steps, 61 tool calls, **1.91 calls per turn**, `read`
38 / `bash` 18 / `edit` 3 / `write` 1 / `grep` 1, **zero duplicate calls**, median
argument 49 bytes, max 10,596.

Its median argument is *smaller than ours*. So argument size is not the mechanism. What
it did was: read every file exactly once, write the artefact once (the 10.6 KB `write`),
make three edits, and batch its reads two-at-a-time.

Three source mechanisms produce that, and none of them is a duplicate detector — there
**is no duplicate-call detection anywhere in opencode**.

**(a) Every read result states where to continue, or that there is nothing to continue
to.** `packages/opencode/src/tool/read.ts:344-350`:

```
(Output capped at 50 KB. Showing lines 1-812. Use offset=813 to continue.)
(Showing lines 1-812 of 2000. Use offset=813 to continue.)
(End of file - total 812 lines)
```

A model told *"End of file — total 812 lines"* has no reason to read again. A model
handed a bare truncated blob re-reads defensively, and re-reads in slices because it
cannot tell how much it is missing. **This is the mechanism behind our 49 offset
windows,** and it is a result-shape fix, not a prompt fix.

**(b) The edit tool returns no diff — it returns fresh LSP diagnostics.**
`tool/edit.ts:196-211`: output is the string `"Edit applied successfully."`, plus type
errors if any. The diff goes to `metadata` for the TUI only. `write.ts:79-90` even
reports errors in *other* files, capped at 5. So the confirmation the model needs — *did
this break anything* — arrives without a read, and the edit payload is never paid for
twice.

**(c) Batching is instructed in the tool description, not only the system prompt.**
`tool/read.txt`:

> - Call this tool in parallel when you know there are multiple files you want to read.
> - Avoid tiny repeated slices (30 line chunks). If you need more context, read a larger window.

`tool/glob.txt` carries the same idea: *"It is always better to speculatively perform
multiple searches as a batch that are potentially useful."*

Worth noting for calibration: opencode ships a prompt (`trinity.txt:84`) that says *"Use
exactly one tool per assistant message. After each tool call, wait for the result before
continuing."* That is our 1.04-calls-per-turn regime, selected deliberately for one model
family. Batching is a per-model choice there, not a universal law.

### 1.3 mini-swe-agent: the prompt teaches the idioms, with worked examples

mini's entire config is recoverable from its trajectory. The system prompt is one line —
*"You are a helpful assistant that can interact with a computer."* All the behaviour is
in the instance template, which ends with a section called **"Useful command examples"**
containing runnable snippets for heredoc creation, four `sed -i` forms, and
`nl -ba file | sed -n '10,20p'` for viewing.

That is the whole mechanism. mini does not have a better tool; it **shows the model the
large-argument idiom, in the prompt, as copyable text.** Its median argument (351 bytes)
is the highest in the field, and that is where it comes from.

Two other details worth taking:

- The environment is scrubbed: `PAGER=cat`, `MANPAGER=cat`, `LESS=-R`,
  `PIP_PROGRESS_BAR=off`, `TQDM_DISABLE=1`. Codex does the same, harder — ten variables
  including `NO_COLOR`, `TERM=dumb`, `GIT_PAGER=cat`, `CODEX_CI=1`
  (`core/src/unified_exec/process_manager.rs:76-87`). Interactive pagers and progress
  bars are a pure-noise context tax that both winners eliminate at the process boundary.
- Observation template is head-5000 / tail-5000 with an explicit `elided_chars` count —
  the model always knows exactly how much it did not see.

**Be careful what you conclude from mini.** It took 213 turns to our 78 on the five
non-runaway tasks. It is not efficient; it is *persistent*, and persistence is what won
it 6/6. See §4.

### 1.4 So what stops OSA from making a 7,800-character write?

Nothing in the schema. There is no size cap on `file_write.content`, `file_edit`'s
strings, or `shell_execute.command` anywhere in the tool handlers, and
`max_response_tokens` is 32,768 at every effort level (`agent/effort.ex:22-80`). The
constraints are all instructional and procedural, and there are seven of them:

1. **`file_edit`'s description opens with the word "surgical"**
   (`tools/builtins/file_edit/prompt.ex:30`) — and `prompt.ex:10-11` records that the
   word is pinned by a test assertion. The same description ends with *"edit each site
   individually instead."*
2. **`shell_execute`'s description instructs fragmentation**
   (`tools/builtins/shell_execute/prompt.ex:33`): *"Prefer several simple commands over
   one compound line — a compound line is approved or refused as a whole."*
3. **Every shell path to a large argument is banned by name** (`shell_execute/prompt.ex:20-22`,
   `SYSTEM.md:59`, `:239-244`): *"file_edit not sed/awk, file_write not echo, file_read
   not cat"*. Codex's winning idiom is prohibited by our tool description.
4. **Heredocs can never be always-allowed.** `permissions.ex:375-377` treats any command
   containing `<<`, `$(`, `` ` `` or a compound operator as unconstrainable, so
   `suggested_rule/2` returns `nil` and there is no rule the operator can save. Every
   `cat > f << 'EOF'` and every `python3 - <<PY` prompts, forever. A bare `sed` can be
   allowed once; the idiom that wins cannot.
5. **`file_edit` echoes `old_string` + `new_string` back in a synthetic diff**
   (`file_edit/handler.ex:191`, `:334-356`). Every byte of an edit is paid for twice.
   opencode returns 26 bytes.
6. **`file_read` has no end-of-file stamp and no continuation hint** (§1.2a).
7. **Read-before-edit is enforced three times over** — `FileState.check_read` in
   `file_edit/handler.ex:104` and `file_write/handler.ex:106`, `DriftGuard.verify` at
   `file_edit/handler.ex:109`, and a system message injected by
   `tool_executor.ex:235-265`: *"Always call file_read before file_edit/file_write on
   existing files."* Codex instructs the exact opposite
   (`models-manager/prompt.md:143`): *"Do not waste tokens by re-reading files after
   calling `apply_patch` on them. The tool call will fail if it didn't work."*

Item 7 deserves care, because it is the one with real safety value and the one whose
interaction produced the loop. `FileState.record_write/2` refreshes the file's
`{mtime,size,hash}` but **drops every recorded range** (`file_state.ex:193`). So after an
edit, the redundant-read suppressor is disarmed for that path — correctly, since the file
changed — and the next read is legitimate. Read-before-edit then makes it *mandatory*.
`read → edit → read → edit` is not a malfunction. It is the designed rhythm, and it is
why we make 1.00 tool calls per turn on a task where opencode makes 1.91.

---

## 2. Prompts and tool descriptions: the philosophy diff

Sizes, all measured:

| harness | system/base prompt | notes |
|---|---:|---|
| mini-swe-agent | **62 B** system + ~3.2 KB instance template | one line + worked examples |
| opencode (anthropic) | 8,212 B | 14 prompts, selected by model-id substring |
| codex (live, from the run) | 20,751 B | `base_instructions` in the rollout |
| **OSA** | **16,723 B** (`SYSTEM_LEAN.md`) / 41,243 B (`SYSTEM.md`) | LEAN is current |

Prompt *mass* is not our problem — we sit between opencode and codex. The differences are
in kind.

**What they instruct that we do not.**

- **Do not re-read after a successful mutation.** codex `prompt.md:143`, quoted above.
  We do have this in `SYSTEM_LEAN.md:32` and in the `file_edit`/`file_write` descriptions
  — and it is contradicted by three enforcement layers and by `SYSTEM.md:53`. The
  instruction is not missing; it is outvoted.
- **Batching taught at the tool, not only in the prompt.** opencode's `read.txt` and
  `glob.txt` carry it. `SYSTEM.md:225-236` says *"DEFAULT TO PARALLEL … this is not an
  optimization — it's expected behavior"*, but no OSA tool description mentions
  parallelism at all. The instruction is one indirection away from the affordance.
- **Widen, don't re-slice.** opencode `read.txt`: *"Avoid tiny repeated slices (30 line
  chunks). If you need more context, read a larger window."* We have nothing equivalent,
  and our per-range read ledger (`file_state.ex:69-74`) actively rewards narrow windows —
  a wide read followed by a narrow one inside it is not suppressed.
- **Worked examples of the large idiom.** mini's "Useful command examples". Codex's
  `apply_patch` envelope inline in the prompt (`prompt.md:132`). OSA's `file_write`
  description devotes 18 bytes to `content` — *"Content to write"* — with no example and
  no hint that a whole file is the expected unit.
- **Explicit anti-loop sentence.** opencode `trinity.txt:86`: *"Avoid repeating the same
  tool with the same parameters once you have useful results. Use the result to take the
  next step … do not search again in a loop."*
- **Persistence.** Every winner says a version of *keep going until it is actually done*
  (codex `prompt.md:125`; opencode `beast.txt:1,5,9`; gpt-5.5 `#L76`). `SYSTEM.md:433-436`
  says the opposite emphasis: *"Be efficient — don't waste turns on unnecessary
  verification or redundant tool calls."* See §4.

**What they deliberately omit that we specify.** Codex's 20.7 KB is almost entirely
*output formatting* — preambles, final-answer structure, bullet and monospace rules. Its
actual tool guidance is two bullets (`prompt.md:264-265`). It spends its prompt budget on
how to talk to the user and almost none on how to use tools, because the tool
descriptions and the result shapes carry that. Ours is the reverse: a large behavioural
rulebook attached to descriptions of 380–699 bytes.

**Is the rule mass earning its place?** Partly not, and there is a concrete defect:
`SYSTEM.md:423` documents a `low` effort level with *"10 iterations max"* that does not
exist — `effort.ex` has fast/medium/high/xhigh/ultra at 50/100/150/2000/4000. That is
stale text the model is reading as fact.

The honest read of mini's 243-byte schema is **not** "less is more". It is that mini
moved its guidance from the schema into *worked examples* and its safety from
instructions into *the environment*. The total instruction is not small; it is placed
where it binds.

---

## 3. Loop architecture

| | OSA | codex | opencode | mini |
|---|---|---|---|---|
| continue condition | tool calls present | tool calls present, or server `end_turn:false` | `finish != "tool-calls"` and no tool parts | any bash call |
| turn cap | off (`limits.ex:19-22`) | none in loop | `agent.steps`, default ∞ | `step_limit: 0` |
| "are you done" gate | **VerificationGate**, cap 2 | **none** | **none** | **none** |
| review sub-agent | — | Guardian (approvals) + `/review` rubric | `Task` explore agent | — |
| stop hooks | yes | yes (`turn.rs:474-508`) | — | — |
| tool errors | normalised to `"Error: …"` string | `RespondToModel(String)`, verbatim | verbatim, self-correcting text | verbatim JSON with `returncode` |

**Nobody else has a completion gate.** Codex's turn ends when the model stops calling
tools, full stop (`core/src/session/turn.rs:472`). What it has instead is a prompt that
refuses to let the model stop: *"Only terminate your turn when you are sure that the
problem is solved"* (`prompt.md:125`), plus — in goal mode — an explicit completion audit
(`prompts/templates/goals/continuation.md:31-41`): *"treat completion as unproven …
Marking the goal complete is a claim that the full objective has been finished and can
withstand requirement-by-requirement scrutiny."*

So the answer to *"is mini's write→test→fix loop prompt, architecture, or an ungameable
gate?"* is: **prompt, plus the absence of anything that lets the model self-certify.**
mini's step 2 is literally *"Create a script to reproduce the issue"* and step 4 *"Verify
your fix works by running your script again"*. There is no gate to satisfy, so there is
nothing to satisfy cheaply. Our gate, by being satisfiable, taught the model what
satisfaction looks like — and five throwaway inline probes looked like it.

That specific hole is **already fixed** by the concurrent agent
(`verification_adequacy: true`, `config/config.exs`, requiring a persisted, re-runnable
test that failed at least once). This document does not re-propose it. The remaining
observation is that a gate is a weaker instrument than the winners' approach and should
be paired with the prompt-side persistence text, which we currently lack.

**Tool-error fidelity is a real gap.** Codex's error type is
`RespondToModel(String)` rendered `#[error("{0}")]` — the message reaches the model
byte-for-byte — and a non-zero exit code is explicitly *not* an error
(`core/src/tools/context.rs:335-337`); it is one line of text, `Process exited with code
N`, inside a normal successful result. That is a deliberate design: the model, not the
harness, decides what a failure means. We normalise everything to `"Error: …"` strings,
which is why `success` was uniformly `true` — a defect the concurrent agent owns.

---

## 4. Context management

| | trigger | what is kept |
|---|---|---|
| **codex** | **90% of context window**, hard: `(context_window * 9) / 10` = 244,800 of 272,000 (`protocol/src/openai_models.rs:468-479`) | user messages only, newest-first to a 20,000-token budget, plus one summary message. **All assistant turns, reasoning and tool calls are dropped outright** (`core/src/compact.rs:342-378`, `:629-690`) |
| **opencode** | absolute: `context - min(20_000, maxOutputTokens)` (`session/overflow.ts:8-34`) | last 2 turns verbatim (2k–8k tokens), summary of the rest |
| **mini** | **none at all** | everything, forever |
| **OSA** | recently corrected | — |

Two mechanisms here are worth more than the thresholds.

**opencode prunes tool outputs in place, in the background, without summarising.**
`session/compaction.ts:277-323`: walk backwards, keep the newest `PRUNE_PROTECT = 40_000`
tokens of tool output, and if what remains exceeds `PRUNE_MINIMUM = 20_000`, blank those
parts to the literal string `"[Old tool result content cleared]"` (`:77-79`). It runs
*after* the turn, forked (`session/prompt.ts:1338`), so it costs no latency, and it is
not compaction — no summary, no model call, no risk of losing a decision. Given that our
input:output ratio is ~140:1 against the field's 56–85:1, stale tool output is the
likeliest single occupant of our context, and this is the cheapest way to evict it.

**Codex never compacted on the task it won.** Peak context 94,616 against a 258,400
window. The context-management win was not a better compactor; it was never putting the
file in context (§1.1).

Two smaller things:

- **Truncated output becomes a file with a delegation instruction.**
  `tool/truncate.ts:129-131`: *"Full output saved to: {file}. Use the Task tool to have
  explore agent process this file with Grep and Read … **Do NOT read the full file
  yourself - delegate to save context.**"* We spool to `~/.osa/tool-results/` and say
  nothing — and in the measured run the model read one of those spool files back
  **three times**.
- **The model can read and manage its own budget.** Codex ships `get_context_remaining`
  ("Get the remaining tokens in the current context window.") and `new_context_window`
  ("Start a new context window. Does not clear, reset, or otherwise affect environment
  state."), letting the model voluntarily trigger compaction at a sensible boundary
  rather than being cut mid-thought (`turn.rs:430`).

---

## 5. Things we are missing entirely

Ranked. The first is the answer to the brief's last question.

**1. A context-free edit path.** Every OSA mutation — `file_edit`, `file_write`,
`multi_file_edit` — requires the model to have read the file and to quote its exact bytes
back. Context cost is therefore O(edits × filesize), which is exactly the quadratic we
measured (32.5M input over 277 turns, peak 201k). Codex has two escapes: `apply_patch`
(quotes only 3 lines of context per hunk) and edit-by-program (quotes nothing). opencode
has none either — and it compensated by making only four write operations. **We have
neither the escape nor the discipline.**

**2. Programs as the way to ask questions about files.** Codex's twelve self-authored
paren-balance probes. The generalisation: when the question is *"is this file
well-formed / does it contain X / how many Y"*, running a program returns O(1) tokens and
reading the file returns O(filesize). We have `repl` and `shell_execute` and instruct the
model not to use them for this.

**3. Continuation and end-of-file stamps on read results.** §1.2a. Cheap, purely
additive, and it is the direct cause of the offset-window churn.

**4. Diagnostics instead of diffs on edit results.** opencode returns 26 bytes plus live
LSP errors; we return the whole replacement text back. We *have* post-edit validation
(`file_edit/handler.ex:286-305`) — we just also return the diff.

**5. Persistent shell sessions as the default shell.** Codex's `exec_command` allocates a
PTY and returns a `session_id` when the process outlives the yield window; `write_stdin`
resumes it; Ctrl-C is a first-class primitive (`INTERRUPT: &str = "\u{3}"`,
`unified_exec/process_manager.rs:91`); up to 64 concurrent sessions. Yielding,
not killing, is the default outcome of a long command. We have this shape in the `pty_*`
family but `shell_execute` — the tool the model actually reaches for — is one-shot and
re-resolves cwd every call.

**6. A scrubbed command environment.** `PAGER=cat`, `TERM=dumb`, `NO_COLOR=1`,
`GIT_PAGER=cat`, `TQDM_DISABLE=1`. Both winners do it; we do not.

**7. Anti-tool-list bloat: `tool_search` / deferred tools.** Codex can register a tool
`Deferred` so it is absent from the request entirely, discoverable via `tool_search`
(`spec_plan.rs:337-372`). We ship ~90 registered tools with a `@model_hidden` denylist
and a 16-tool LITE mode — a coarser version of the same idea.

**8. Model-family-specific prompt *and toolset*.** opencode swaps prompt by model-id
substring (`session/system.ts:27-45`) and swaps `edit`+`write` for `apply_patch` on
GPT-5-class models (`tool/registry.ts:291-295`). Different models want different edit
affordances; a single universal toolset is a compromise we have not priced.

**9. Fuzzy "did you mean" on file-not-found** (`tool/read.ts:92-98`) — turns
read-fail → glob → read into read-fail → read.

**10. A write-only todo tool.** opencode has no `todoread` (`tool/registry.ts:14`); the
list is re-rendered by the harness. The model cannot spend a call reading its own todo
list. We logged four `task_write` calls on the runaway; worth checking whether any read
path exists.

---

## 6. Ranked proposals

Nothing below is implemented. Each carries the number it targets, the capability risk,
and how it would be measured. The 8-task probe set with recorded baselines is the
instrument for all of them; the ones marked **A/B-able** can be run as a single-mechanism
ablation in the style of Hermes `evals/readtool`, which is the cheapest honest design
available.

### Tier 1 — result-shape changes: no new capability, no new authority

**P1. End-of-file and continuation stamps on `file_read`.**
Append `(End of file — total N lines)` when the read reached EOF, or
`(Showing lines A-B of N. Use offset=C to continue.)` when it did not.
*Targets*: the 49 offset-window reads; the 64 `file_read` calls on the runaway.
*Expected*: removes the defensive-re-slice class. On the runaway, reads are 23% of calls.
*Risk*: **none identified.** Additive text on a result the model already receives.
*Measure*: `file_read` calls per task and distinct-offset-windows-per-path, before/after,
same model, same tasks. A/B-able.

**P2. Stop echoing the diff from `file_edit`.**
Return `Replaced in <path>` plus the post-edit validation note; drop `format_diff/4`
(`file_edit/handler.ex:191`, `:334-356`) from the model-visible string, keep it in the
metadata the TUI already consumes.
*Targets*: 58 edits × median 506 bytes ≈ 29 KB of pure duplication on one task.
*Risk*: **low-moderate.** The diff is the model's confirmation that the *right* region
changed; a fuzzy-matched edit could land somewhere unintended and go unnoticed. Mitigation:
keep the diff whenever `fuzzy_note` is set, drop it on an exact match. opencode's
equivalent confidence comes from LSP diagnostics, which we already run.
*Measure*: output+input tokens per edit; edit-correctness on the probe set.

**P3. Delegation hint on spooled tool output.**
`ToolResultStorage` already writes to `~/.osa/tool-results/`; add opencode's sentence —
*grep or read a slice, do not read the whole file, or delegate it*.
*Targets*: the three measured re-reads of a spool file.
*Risk*: none. Text on an existing message.

### Tier 2 — prompt and description changes (hand-over, see §7)

**P4. Add the missing instructions to tool descriptions, not just SYSTEM.md.**
Batching on `file_read`/`file_grep`/`file_glob`; "widen, don't re-slice" on `file_read`;
a worked whole-file example on `file_write`.
*Targets*: 1.00 → toward opencode's 1.91 calls/turn; read count.
*Risk*: **low.** Bigger reads cost context if the model over-widens; bounded by existing
byte caps.
*Measure*: calls per turn, reads per file, input tokens per task.

**P5. Resolve the read-before-edit contradiction, in one direction, explicitly.**
Today `SYSTEM.md:53` mandates the read, `SYSTEM_LEAN.md:32` forbids the re-read, and
three code layers enforce the mandate. Pick: *read once before the first edit of a file;
never re-read after your own successful edit.* That is codex's rule and it is compatible
with our `FileState` ledger, which already knows the file is current after
`record_write/2`.
*Risk*: **moderate**, and it is the reason this is a proposal. The stale-file guard is a
genuine correctness feature when a linter, the user, or a sub-agent touches the file
between turns — `DriftGuard` exists for real reasons. The change must be *"no re-read
after **your own** write"*, not *"no re-read"*, and drift must still force one.
*Measure*: `file_read`-after-`file_edit`-on-same-path count; edit failure rate.

**P6. Remove the fragmentation instructions.**
`shell_execute/prompt.ex:33` (*"Prefer several simple commands over one compound line"*)
and the pinned word "surgical" in `file_edit`. Replace the first with a statement of the
real constraint — a compound line is approved as a whole, so keep unrelated risky
operations out of it — which is the true fact without the fragmenting advice.
*Risk*: **low** for the wording; note the test assertion pinning "surgical"
(`file_edit/prompt.ex:10-11`) must be retired with it.

### Tier 3 — capability additions

**P7. A context-free edit path.** Two candidate shapes, in preference order:

- **7a. `apply_patch`-style tool.** A single call carrying multiple hunks across multiple
  files, each hunk anchored by ~3 lines of context rather than a full unique `old_string`.
  Closest to codex; quotes far less than `file_edit`; fits our existing fuzzy-match
  cascade. *Effort*: moderate. *Risk*: **moderate** — a patch applier is a new failure
  surface, and partial application is worse than no application, so it must be atomic
  (which `multi_file_edit` already demonstrates we can do).
- **7b. Permit edit-by-program explicitly.** Cheaper: stop banning it, and make the
  permission layer able to allow it (§P8). *Risk*: **higher**, because an arbitrary
  script that rewrites a file is exactly the thing our permission model is built to
  gate. Not recommended without 7c.
- **7c. A `file_transform` tool** — the model supplies a script, the tool runs it against
  one declared path in a constrained interpreter and writes the result atomically. Keeps
  the O(1) context property while keeping the *file* the unit of authorisation. This is
  the adaptation rather than the transplant, and it is the one I would design first.

*Targets*: the 66-vs-12 write-operation gap, and directly the O(edits × filesize) context
growth. *Measure*: peak context and input tokens per task on the probe set; write
operations per artefact.

**P8. Make heredocs suppressible.** `permissions.ex:375-377` refuses to offer any rule
for a command containing `<<`. That is correct for a *prefix* rule, but a heredoc's
identity is its target: `cat > <path> << EOF` could be authorised as "write to this path",
which is precisely the authorisation `file_write` already gets.
*Risk*: **this is a sandbox-boundary change and must be treated as one.** `$(` and
backticks must stay unconstrainable; only the redirect-target form is safely
characterisable. Do not ship on performance grounds.

**P9. Prune old tool outputs in place, after the turn.** opencode's design: keep the
newest ~40k tokens of tool output, blank the rest to a literal placeholder, run it forked
after the turn completes, no summarisation.
*Targets*: the 140:1 input:output ratio against the field's 56–85:1.
*Risk*: **moderate.** Blanking a tool result the model still needs is a real failure, and
unlike compaction there is no summary to fall back on. Needs the protected-recent window
and probably a protected-tool list, both of which opencode has.
*Measure*: input tokens per turn slope; solve rate must not move.

**P10. Scrub the command environment.** `PAGER=cat`, `GIT_PAGER=cat`, `TERM=dumb`,
`NO_COLOR=1`, `TQDM_DISABLE=1`, `PIP_PROGRESS_BAR=off`.
*Risk*: low, but it changes observable command behaviour, so it is a default change.
*Measure*: bytes of tool output per shell call.

**P11. Make `shell_execute` a persistent session with yield-not-kill semantics.** We have
the pieces (`pty_*`, background manager, the 2-minute yield). The gap is that the default
shell tool is one-shot. *Effort*: large. *Risk*: moderate — session state is a new class
of confusion. Defer until P1–P7 are measured.

### Explicitly not recommended

- **Cutting the tool count toward mini's one.** mini took 213 turns to our 78 on the five
  non-runaway tasks. Its wins came from persistence and worked examples, not minimalism,
  and its architecture has no context management at all.
- **A turn cap.** Unchanged from `turn-count-diagnosis.md` §6: `path-tracing` was solved
  at 175 turns.
- **Copying codex's compaction.** Dropping every assistant turn and tool call is viable
  for codex because it re-derives state from the worktree
  (`goals/continuation.md:20`: *"Use the current worktree and external state as
  authoritative"*). We do not have that discipline yet, and the mechanism without the
  discipline is amnesia.

---

## 7. Hand-over to the prompt / tool-description owner

P4, P5 and P6 land in `priv/prompts/` and `tools/builtins/*/prompt.ex`, which another
agent owns right now. Precise requests:

1. `file_read/prompt.ex` — add: *"Call this tool in parallel when you need several
   files."* and *"Avoid tiny repeated slices. If you need more context, read a larger
   window."*
2. `file_write/prompt.ex` — add a worked example of a whole-file write, and expand the
   `content` parameter description beyond *"Content to write"*.
3. `file_edit/prompt.ex` — drop *"edit each site individually instead"*; retire the
   pinned word "surgical" together with the test assertion at `prompt.ex:10-11`.
4. `shell_execute/prompt.ex:33` — replace *"Prefer several simple commands over one
   compound line"* with a statement of the constraint rather than the advice.
5. `SYSTEM.md:53` vs `SYSTEM_LEAN.md:32` — resolve to *read once before the first edit;
   never re-read after your own successful edit; drift still forces a re-read*.
6. `SYSTEM.md:423` — **stale and factually wrong**: documents a `low` effort level with
   "10 iterations max". `effort.ex` has fast/medium/high/xhigh/ultra at
   50/100/150/2000/4000.
7. Add a persistence sentence. Every winner has one; we have the opposite emphasis at
   `SYSTEM.md:433-436`.

---

## 8. Shipped

**`Agent.Loop.ToolArgMetrics`** — new module
(`lib/optimal_system_agent/agent/loop/tool_arg_metrics.ex`), emitted from
`tool_executor.ex` as two additive fields on the `:tool_call` start event:

- `args_bytes` — JSON byte size of the real arguments.
- `args_hash` — a canonical 32-hex identity over the real arguments, for duplicate
  detection. Map keys are sorted recursively, so key ordering cannot make one call look
  like two.

Both ride *alongside* the existing `args` hint; the TUI path is untouched. Nine tests in
`test/agent/loop/tool_arg_metrics_test.exs` pin the specific ways the hint lied — a
7 KB heredoc reported as 60 bytes, a 7,838-byte write reported as `"eval.scm"`, two
different offset windows hashing identically, two different shell commands sharing a
60-character prefix.

Verification: `mix test test/agent/loop/tool_arg_metrics_test.exs` → 9 tests, 0 failures.
`mix test test/agent/loop/tool_hint_test.exs test/agent/loop_injection_test.exs` →
148 tests, 0 failures.

Nothing else was shipped. Every other item either changes what the model sees, changes a
security boundary, or adds a tool — none is unambiguously safe.

---

## 9. Caveats

- n = 1 run per task. Every solve-rate comparison here is a single Bernoulli draw. The
  turn, token and call-composition comparisons are far more robust than the solve rates.
- The command classification in §1.1 is my regex over codex's `cmd` strings, not codex's
  own taxonomy. The four script-edits and twelve diagnostics were confirmed by reading
  the scripts; the run/test bucket is a residual.
- opencode's clone is at `959c8bd4`, a newer Effect-based refactor than the release the
  benchmark arm ran. Notably, `edit.txt` and `write.txt` both claim the tool hard-fails
  without a prior read and **no such check exists in that tree** — the claim is
  prompt-level only. If porting that design, note you would be implementing something
  opencode currently only asserts.
- Codex's `.md` prompt files in `codex-rs/core/` are dead code; the live text comes from
  `models.json` `instructions_template`, refreshed from the server on a 300 s TTL. The
  20,751 bytes quoted here are what the benchmark run actually received, taken from its
  own rollout — that part is exact.
- No benchmark was run for this document. Every proposal's effect is an estimate.
