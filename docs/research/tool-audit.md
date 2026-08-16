# Tool audit: what every tool in the array has earned

*2026-08-16, against `9b57ee7d` (v1.0.99).*

Every tool in the schema array is not a capability the model gains. It is a
decision the model must make and then decline, on every turn. A tool has to
earn its place with measured demand, not a plausible use case.

This is the measurement. It is reproducible:

```
mix osa.tool_audit                     # the whole table
mix osa.tool_audit --remove a,b,c      # price a candidate cut
mix osa.tool_audit --corpus DIR        # one corpus at a time
```

Offline and free — no provider is contacted. Schema cost is the live
`Registry.list_active/0` array serialized exactly as `Providers.Anthropic`
sends it and priced by `tools_payload_bytes/1`, the same function that decides
the cache breakpoint. Call counts come from structured tool-call rows in the
transcripts already on disk.

---

## 1. Headline

**The array is 24 tools, 39,461 bytes, ~9,866 tokens, re-sent on every request
of every turn.** Against that:

| Fact | Measured |
|---|---|
| Tools registered | 82 |
| Tools in the default array | **24** |
| Tools reachable via `tool_search` | **82 / 82** — verified per tool, not assumed |
| Array cost | 39,461 bytes / ~9,866 tokens (4.0 bytes/token) |
| Of which **prose** (`description`) | 24,572 bytes — **62%**, ~6,143 tokens |
| Of which schema (`input_schema`) | 13,078 bytes — 33% |
| Top 5 tools' share of array bytes | **54.8%** |
| Transcripts scanned | 4,549 (922 with ≥1 tool call) |
| Tool calls counted | 29,188 |
| Distinct tools the model ever called | **21 of 82** |
| Genuinely interactive sessions on disk | **3** |

The comparison that provoked this audit: mini-swe-agent is ~190 lines around
one bash tool with a **243-byte** schema, and it beat OSA 6/6 to 4/6 in our own
model-pinned head-to-head while leading Terminal-Bench 3 and SWE-bench
Verified. `shell_execute`'s **description alone is 6,201 bytes** — 25x
mini-swe-agent's entire tool schema — and the model still guessed at the name
`bash` or `bash_execute` 30 times.

**The single largest finding is not a tool. It is prose.** 62% of the array is
description text, and the biggest cut available anywhere in this document
removes no capability at all.

---

## 2. The corpus, and what it cannot answer

This matters more than any row in the table, so it comes before the table.

| Corpus | Transcripts | With calls | Calls |
|---|---|---|---|
| `bench/terminalbench/runs` | 164 | 160 | 7,455 |
| `bench/swebench/runs` | 272 | 222 | 8,015 |
| `bench/swebenchpro/runs` | 82 | 57 | 4,051 |
| `bench/recoverybench/runs` | 12 | 12 | 948 |
| `bench/headtohead/runs` | 66 | 6 | 361 |
| `~/.osa/sessions` | 3,953 | 465 | 8,394 |

### `~/.osa/sessions` is not an interactive corpus

The brief expected real interactive use here, as a distribution different from
and more important than the benchmarks. **It is not there.** Classified by
content:

| What it actually is | Files |
|---|---|
| Unclassified (mostly empty/aborted) | 1,303 |
| Synthetic stubs (`"message 1"`, `"say hello"`) | 1,154 |
| Harness fixtures (`agent_summ-*`, `repro-*`, `probe-*`, `ctxbench_*`) | 700 |
| Dead sessions — provider 401/404, no turn ever ran | 632 |
| Benchmark replicas (`swebench-*`, `abtest-*`, `ctrl-*`) | 164 |
| **Genuinely interactive** | **3** |

The 902 `memory_recall` calls in this corpus are almost entirely one harness
fixture emitting `memory_recall{"query": "smoke test context"}` in a loop
against a stub provider. Read as demand, that number is a fabrication. It is
counted in the table because the table counts what the transcripts contain, and
it is discounted here because provenance is part of evidence.

The entire genuine interactive corpus is **3 sessions, 12 human turns, 36 tool
calls**:

| Tool | Calls |
|---|---|
| `dir_list` | 25 |
| `file_read` | 7 |
| `shell_execute` | 2 |
| `file_write` | 2 |

Four tools. n=3. This is an anecdote, not a distribution, and every claim about
interactive use in this document is labelled as such. **It is also the strongest
argument in the document for not deleting anything on benchmark evidence**: the
one shape of use that would justify a conversational or session-spanning tool
has essentially never been recorded.

### The benchmark distribution is not the user distribution

Terminal-Bench and SWE-bench run in containers. A container never asks a
question, never hands work to a person, never resumes yesterday's session and
never has a second human turn. A zero for `ask_user`, `enter_plan_mode`,
`exit_plan_mode` or `push_notification` in this corpus is not a measurement of
those tools — it is the sampling frame excluding them.

---

## 3. The table

`Δ rm` is the prefix tokens removing the tool buys back, every turn, measured
by difference on the real array. `desc%` is how much of the tool's bytes are
prose rather than schema.

### In the array (24)

| Tool | Calls | Share | fail% | Bytes | Δ rm (tok) | desc% | Verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| `shell_execute` | 11,057 | 37.9% | 11% | 6,992 | 1,748 | 89% | **always_load** — diet the prose |
| `file_read` | 6,237 | 21.4% | 2% | 2,748 | 687 | 69% | **always_load** — diet the prose |
| `file_grep` | 3,315 | 11.4% | 4% | 1,401 | 351 | 47% | **always_load** |
| `file_edit` | 2,301 | 7.9% | 12% | 1,273 | 319 | 64% | **always_load** |
| `task_write` | 2,202 | 7.5% | 6% | 2,856 | 714 | 58% | **always_load** — diet the prose |
| `memory_recall` | 902 | 3.1% | 0% | 693 | 174 | 41% | **always_load** (count is fixture-inflated; cheap either way) |
| `file_write` | 772 | 2.6% | 1% | 938 | 235 | 54% | **always_load** |
| `dir_list` | 620 | 2.1% | 9% | 587 | 147 | 69% | **always_load** — 69% of the only real interactive corpus |
| `bash_output` | 540 | 1.9% | 2% | 1,811 | 453 | 63% | **always_load** — diet the prose |
| `file_glob` | 426 | 1.5% | 1% | 916 | 229 | 71% | **always_load** |
| `web_fetch` | 216 | 0.7% | 21% | 876 | 219 | 67% | **always_load** |
| `code_sandbox` | 197 | 0.7% | 70%* | 667 | 167 | 20% | **always_load** — see note |
| `multi_file_edit` | 114 | 0.4% | 22% | 959 | 240 | 43% | *propose* defer — overlaps `file_edit` + `file_transform` |
| `git` | 105 | 0.4% | 53% | 1,109 | 278 | 65% | *propose* **merge into `shell_execute`** |
| `web_search` | 103 | 0.4% | 20% | 674 | 169 | 56% | **always_load** |
| `file_transform` | 17 | 0.1% | 6% | 4,893 | **1,224** | 67% | **hold** — 2 days old, cannot be judged |
| `memory_save` | 16 | 0.1% | 31% | 1,167 | 292 | 60% | *propose* defer |
| `tool_search` | 11 | 0.0% | 40% | 1,023 | 256 | 72% | **always_load, unconditionally** — see §5 |
| `delegate` | 8 | 0.0% | 0% | 4,116 | **1,029** | 33% | *propose* defer |
| `code_symbols` | 6 | 0.0% | 0% | 977 | 245 | 52% | *propose* defer — **confounded**, see §4 |
| `diff` | 6 | 0.0% | 0% | 461 | 116 | 13% | *propose* **merge into `shell_execute`** |
| `ask_user` | 2 | 0.0% | 0% | 975 | 244 | 57% | **always_load** — frequency is not importance |
| `enter_plan_mode` | 0 | 0.0% | — | 681 | 171 | 70% | **always_load** — but see §6 |
| `exit_plan_mode` | 0 | 0.0% | — | 667 | 167 | 70% | **always_load** — but see §6 |

\* **`code_sandbox`'s 70% is a retraction, not a finding.** Reading the failure
bodies: they are Python tracebacks from the script the model chose to run
(`ModuleNotFoundError`, `Exit 1`), not the tool failing. A reproduction script
exiting non-zero is frequently the *correct* outcome. The outcome classifier
cannot tell "the tool broke" from "the thing you ran exited non-zero", and this
row is the proof. Do not cite it as a health signal.

### Not in the array, but with recorded calls (4)

These have calls because the corpora span several registry configurations —
they were in the array when those runs happened, and are not now. Their counts
are historical, not evidence about the current default set.

| Tool | Calls | fail% | Note |
|---|---:|---:|---|
| `codebase_explore` | 7 | 86% | withheld; was failing when it was reachable |
| `workspace_map` | 4 | 0% | withheld |
| `sleep` | 3 | 67% | withheld |
| `task_output` | 1 | 0% | withheld |

### The other 54 registered tools

Zero calls across every corpus. **Every one of them is unreachable-by-default
but resolvable**: verified per tool, `tool_search` resolves all 82 names by
`select:` and by keyword. So their zeros are not "the API could not emit the
name" — they are "the model never issued the one `tool_search` that would have
made the name emittable", which it did 11 times in 29,188 calls.

**No verdict is issued for any of the 54.** They cost the array nothing today.
Deleting a registered-but-withheld tool buys zero prefix tokens; it only removes
capability. There is no token argument for touching them, and the corpus offers
no other kind.

---

## 4. Confounds, handled

**A tool may be unused because a competitor was broken.** `file_grep` was
returning false negatives on 33% of calls and scanning 0.9% of the tree until
`59db0ed6` and `abecfe68` (2026-08-15, 11:46 and 23:31). **`code_symbols` at 6
calls in 29,188 is therefore uninterpretable**: it competes for exactly the
demand a broken `file_grep` was silently absorbing. Its defer verdict is a
proposal pending a post-fix run, and it must not be deleted on this data.

**A tool may be unused because it was uncallable.** Until `b56d33d7` and
`810841ff` (2026-08-14/15), 59 of 82 tools were uncallable under native-tool
providers, `use_tool` among them. `ToolDiscovery.widen/2` closes that at the
loop. Verified rather than assumed: 82/82 resolve, and
`test/tools/audit_test.exs` now asserts it so a name that stops resolving fails
a test instead of silently vanishing.

**A tool may be rare but load-bearing.** `exit_plan_mode` at zero calls is not a
tool with no demand; it is the only exit from a mode. `tool_search` at 11 calls
is the mechanism that makes every *other* defer verdict in this document
affordable — deferring 58 tools is only survivable because `tool_search` is in
the array. `ask_user` at 2 calls is a conversational tool measured almost
entirely in containers that cannot converse. Frequency is not importance.

**The corpus mostly predates tonight's fixes.** Only **22 of 4,549 transcripts**
postdate the last `file_grep` fix, and they belong to benchmark arms currently
running. In that post-fix slice (868 calls, 20 sessions): `shell_execute` 62.8%,
`file_grep` **0.9%** — down from 11.4%. That is *not* evidence that fixing
`file_grep` reduced demand for it; it is a 20-session Terminal-Bench-only sample
against an aggregate that was half SWE-bench. **The task mix changed, so the
comparison is not clean, and the pre/post claim is not made.**

---

## 5. Two measured defects the table does not have a column for

### 233 calls rejected on string-vs-integer, not on being wrong

Every one is a wasted round trip plus the tokens of the error:

| Tool | Rejections | Shape |
|---|---:|---|
| `task_write` | 127 | Expected Array, got String |
| `file_grep` | 69 | Expected Integer, got String |
| `web_fetch` | 26 | Expected Integer, got String |
| `memory_save` | 5 | Expected Array, got String |
| `tool_search` | 4 | Expected Integer, got String |
| `sleep` | 2 | Expected Integer, got String |
| **Total** | **233** | |

The model emits `max_results: "30"`; validation rejects it and asks for a
rewrite. **4 of the 11 `tool_search` calls in the entire corpus died this way** —
the escape hatch that makes 58 deferred tools reachable has a 40% failure rate
against a coercible type error. Coercing a numeric string to a number, and a
single string to a one-element array, before rejecting, is worth more than any
verdict below.

### 30 calls to a tool named `bash`

| Name called | Times |
|---|---:|
| `bash_execute` | 21 |
| `bash` | 9 |

Nothing answers to either. The tool is `shell_execute`, and it spends 6,201
bytes of description per turn without preventing this. A name the model reaches
for repeatedly is an argument about what the tool should have been called; an
`aliases` entry costs nothing.

### `git` is duplicated by `shell_execute`, in writing

`shell_execute`'s own description says *"Use it for system commands (git, mix,
npm, cargo, docker, make)"* and names `git status` and `git diff` as examples.
The model has been told both things. Of 111 recorded `git` tool results:

| Outcome | Count |
|---|---:|
| ok | 51 |
| environment — not a git repository | 34 |
| **argument shape — a shell string in a subcommand slot** | **26** |

The 26 are `'diff --stat' is not a git command`, `bad revision 'log'`,
`ambiguous argument 'diff'`. The model reaches for `git` and types shell into
it, because that is what the other 11,057 calls taught it. Meanwhile the
destructive-git guardrail (`git reset --hard`, `git clean -f`, force-push) is
*already* in `shell_execute`'s prose, so the Git Safety Protocol is not lost by
deferring the tool.

---

## 6. Ranked: what to remove or defer, and what it buys back

Against a **9,866-token** array.

| # | Change | Tokens back | % of array | Capability lost | Status |
|---|---|---:|---:|---|---|
| 1 | **Prose diet on 6 tools** (`shell_execute` 6,201→1,200 B, `file_transform` 3,293→900, `file_read` 1,889→700, `task_write` 1,655→700, `bash_output` 1,145→500, `tool_search` 733→300) | **~2,654** | **26%** | **none** | proposed |
| 2 | Defer `file_transform` | 1,224 | 12.4% | context-free edits | **hold** — 2 days old |
| 3 | Defer `delegate` | 1,029 | 10.4% | sub-agent dispatch | proposed |
| 4 | Merge `git` into `shell_execute` | 278 | 2.8% | none — duplicated | proposed |
| 5 | Defer `memory_save` | 292 | 3.0% | explicit memory writes | proposed |
| 6 | Defer `code_symbols` | 245 | 2.5% | symbol listing | proposed — **confounded** |
| 7 | Defer `multi_file_edit` | 240 | 2.4% | batch edits | proposed |
| 8 | Merge `diff` into `shell_execute` | 116 | 1.2% | none — duplicated | proposed |
| | **Items 3–8 as one cut** | **~2,200** | **22%** | | |
| | **Items 1 + 3–8** | **~4,850** | **~49%** | | |

Priced with the instrument, e.g.:

```
$ mix osa.tool_audit --remove diff,git,code_symbols,memory_save,multi_file_edit
  4673 bytes / ~1169 tokens off a 9866-token array (12%), leaving 19 tools.
```

**Item 1 is the recommendation.** It is the largest number in the table, it
removes no capability, it is entirely within our control, and it is the one
change the mini-swe-agent result actually argues for. Items 3–8 together buy
less than the prose diet alone and every one of them costs something.

### Why nothing above says "delete"

The shippable bar is: unreachable, duplicated, **or** zero calls across every
corpus *and* no plausible interactive use. Applying it honestly:

- **Unreachable:** nothing. 82/82 resolve.
- **Duplicated:** `git` and `diff`. But duplication argues for *defer*, which is
  reversible and keeps them reachable — not for deleting the code.
- **Zero calls and no plausible interactive use:** nothing qualifies. The four
  zero-call tools in the array (`enter_plan_mode`, `exit_plan_mode`, and
  effectively `ask_user` and `delegate`) are precisely the ones the benchmark
  sampling frame excludes, and the interactive corpus is n=3.

So: **no deletions.** A capability is not deleted on benchmark data.

---

## 7. Shipped vs proposed

### Shipped

- **`mix osa.tool_audit`** (`lib/mix/tasks/osa.tool_audit.ex`) and
  **`OptimalSystemAgent.Tools.Audit`** (`lib/optimal_system_agent/tools/audit.ex`).
  Sibling of `mix osa.ablate`: that prices a read-tool *output* feature by
  removing it, this prices a whole *tool* by removing it from the array, and
  reports tokens **and** what the corpus says would have been lost. Makes this
  audit repeatable instead of a one-off.
- **`test/tools/audit_test.exs`** — 10 tests. Pins the three ways the instrument
  could report a quietly-wrong number: double-counting a call (an event log
  emits `start` *and* `end`), scoring a failure as a success (a `tool_result`
  was observed carrying `success: true` on a body of `"Error: Permission
  denied"` — the flag is not load-bearing, the text is), and mispricing a cut.
  It also asserts 82/82 reachability, so a name that stops resolving fails a
  test rather than silently becoming uncallable.
- **A retraction found by that test.** An earlier draft of `cut_cost/2`
  documented cuts as super-additive. They are exactly additive: an `n`-element
  array has `n-1` separators, so each removal drops one element and one
  separator. The test asserted the wrong thing, failed, and the docstring was
  corrected to match the measurement.

### Proposed, not shipped

Everything in §6, and the two defects in §5. Nothing that changes tool
behaviour was shipped, for one reason beyond caution: three benchmark arms are
running or queued, and OSA runs from source.

---

## 8. Which findings are unsafe on pre-fix data

**Safe — measured against current HEAD, independent of the corpus:**

- Every byte and token figure. Read from the live registry today.
- 24 of 82 in the array; 62% of it prose; top 5 = 54.8% of bytes.
- 82/82 reachable via `tool_search` — probed per tool, now a test.
- `git` and `diff` are duplicated by `shell_execute` — read from
  `shell_execute`'s own description, not inferred from counts.
- Cuts are additive.

**Safe — a call happened or it did not:**

- The 29,188 calls, the 21 distinct tools ever called, the shape of the
  distribution (one tool is 38% of everything).
- 233 type-mismatch rejections; 30 calls to a non-existent `bash`; 26 `git`
  calls with a shell string in a subcommand slot.
- `~/.osa/sessions` contains 3 genuine interactive sessions.

**Unsafe — needs a post-fix run before it can be acted on:**

- **`code_symbols`.** Its competitor was broken for the whole corpus. Six calls
  means nothing until `file_grep` has been healthy for a full run.
- **`file_transform`.** Two days old and 12.4% of the array. Seventeen calls is
  a first look, not demand. Re-run before deciding.
- **`file_grep`'s own share.** 11.4% pre-fix, 0.9% in the 22-transcript post-fix
  slice — but the task mix differs, so no conclusion is drawn.
- **Any pre/post comparison at all.** 22 of 4,549 transcripts postdate the last
  fix, all from one benchmark, all mid-flight.

**Retracted:**

- `code_sandbox`'s 70% failure rate is the model's *scripts* exiting non-zero,
  not the tool failing. Not a health signal.
- `memory_recall`'s 902 calls are overwhelmingly one stub fixture in a loop.
  Not demand.

---

## 9. The next measurement

The instrument prices tokens and counts lost calls. It does **not** answer the
question the mini-swe-agent result actually poses: *does a smaller menu make the
model better?* That needs an A/B — the same tasks, the same model, `shell_execute`
prose at 6,201 bytes against the same tool at 1,200 — scored on task success,
not on tokens. `mix osa.tool_audit --remove` produces the arm; `bench/` scores
it. Until that runs, every verdict in §6 is a proposal with its evidence
attached, which is what they are labelled.
