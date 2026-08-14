# Context-free edits: `file_transform`

**Date** 2026-08-14 · **Status** shipped (tool, tests, measurement) ·
**Companion to** `docs/research/competitor-techniques.md` §1.1, §5.1–5.2, §6 P7

---

## 0. The problem, restated as arithmetic

Every OSA mutation quotes the file back. `file_edit` takes `old_string` +
`new_string`; `file_write` takes the whole `content`; and read-before-edit means
the file was pulled into context first. So the context cost of maintaining one
file is **O(edits × filesize)**.

That is not a prompt problem and no amount of prompt trimming touches it.
Measured on `schemelike-metacircular-eval`, same task, same model:

| | OSA | codex |
|---|---:|---:|
| write ops on the artefact | **66** | **12** |
| output tokens | **119,451** | 60,482 |
| **peak context** | **201,112** | **94,616** |

Codex made every edit with a self-contained `python3 - <<PY` script, so the file
never entered its context. And — the more important half — **twelve of its
sixteen heredocs never wrote anything**: they were paren-balance probes over
`eval.scm` that returned the single word `balance: 0`. Codex answers *"is my
file well-formed?"* with a program. OSA answered it by reading the file back.

Two capabilities are therefore missing, and they are different:

1. **a way to change a file without holding it**, and
2. **a way to ask a question about a file without holding it.**

---

## 1. What was built

`file_transform` — one tool, one declared path, an ordered list of operations
applied in memory and committed atomically.

```json
{"path": "eval.scm",
 "operations": [
   {"op": "delete_matching_lines", "pattern": "^\\(define \\(caddddr", "expect": 1},
   {"op": "assert_balanced"}
 ]}
```

```
eval.scm — 2 operation(s) applied
  1. delete_matching_lines — 1 lines deleted
  2. assert_balanced — balance: 0 (() balanced)
812 -> 811 lines, 24113 -> 24066 bytes
```

Vocabulary: `replace`, `replace_regex`, `delete_matching_lines`, `insert_after`,
`insert_before`, `append`, `prepend`, `count`, `assert_balanced`. Plus
`dry_run`.

`count` and `assert_balanced` mutate nothing. They are capability (2) — the
codex probe, promoted from an idiom the model has to invent into an operation it
can see in the schema.

Files:

| file | role |
|---|---|
| `lib/optimal_system_agent/tools/builtins/file_transform/ops.ex` | the vocabulary; a pure `content -> content` interpreter |
| `.../file_transform/handler.ex` | validate / check_permissions / execute, atomic commit |
| `.../file_transform/tool.ex` | declarations, schema |
| `.../file_transform/prompt.ex` | description, with worked examples |
| `.../file_transform/{constants,ui}.ex` | cross-tool name, TUI render |
| `test/optimal_system_agent/tools/file_transform_test.exs` | 36 tests, adversarial first |
| `test/optimal_system_agent/tools/file_transform_context_growth_test.exs` | the measurement below |

Wiring: registered in `Tools.Registry` (`always_load?` — a tool competing with
`file_edit` has to be in the same prompt as `file_edit`), added to
`Permissions.@file_mutating_tools` so `out_of_scope_write/2` and
`bypass_immune_ask/2` see it, and given a `file_edit` fallback in
`Registry.Search.suggest_fallback/2`.

---

## 2. Authorisation analysis

This is the part that decided the design. The brief's requirement: *a script
that declares `/app/foo.py` and writes `/etc/passwd` must be impossible or
detected.*

### 2.1 The four candidate shapes

**(a) Transplant codex: arbitrary script through `shell_execute`.**
Rejected. An interpreter that opens its own files declares nothing, so
`PathPolicy.check_write/2` has nothing to check and per-path authorisation is
gone entirely. This is `competitor-techniques.md` P7b, and it was already marked
*not recommended*.

**(b) Script with a declared path, confined by the OS.** The honest version of
(a): run the interpreter under `bwrap`/`seccomp`/`landlock` with exactly one
writable path. This is the only way to make *arbitrary code* respect a declared
path, and it is a real design — but it is not reachable in this pass:

* it requires a sandbox binary that is not present across task images (the
  container arms of the benchmark are plain `python:*`/`ubuntu` images), and
* a capability that silently degrades to unconfined when the sandbox is missing
  is worse than no capability, because the authorisation property becomes
  environment-dependent and untestable.

**(c) Script with a declared path, confined by the interpreter.** Run the model's
Python under `sys.addaudithook` (PEP 578), denying `open` for write to anything
but the declared path. Audit hooks cannot be uninstalled once added, and the
event set covers `open`, `os.system`, `subprocess.Popen`, `ctypes`, `socket`.
This is genuine, and it is still **defence in depth, not a boundary**: it is
CPython-specific, it has a documented history of bypasses, and it would put the
security property of a write tool inside a third-party runtime we do not
version-pin. Rejected for the same reason the repo rejected widening
`PathPolicy` yesterday — the fix has to be in the scope, not in a mitigation
layered over a wider scope.

**(d) Do not execute model-supplied code at all.** Chosen. The model supplies
*data* — an operation list — and the harness supplies the code. `Ops` selects a
fixed Elixir function by atom and applies it to a binary.

### 2.2 The property (d) actually gives

The complete filesystem surface of a `file_transform` call is:

```
File.read(declared)          # the declared path
File.write(tmp)              # a sibling of the declared path
File.rename(tmp, declared)   # onto the declared path
File.rm(tmp)                 # cleanup on failure
```

`tmp` is constructed in `Handler.atomic_write/2` from `Path.dirname(declared)`
plus 8 bytes of `:crypto.strong_rand_bytes/1`; no model-supplied string
contributes to it. All four are reached only after `PathPolicy.check_write/2`
has approved `declared`, and that check is re-run inside `execute/2` as defence
in depth (same pattern as `FileWrite.Handler`), so the property survives a
direct call that bypasses the `validate → check_permissions → execute` pipeline.
The staging path is *itself* run through `check_write/2` rather than assumed
safe — which is why it is not a dotfile: a dotfile sibling of a target directly
under `$HOME` would be refused by `dotfile_outside_osa?/1`, and a staging path
the policy would refuse is a staging path in the wrong place.

So "the script declared one path and wrote another" is not a case that must be
*detected*. **There is no operation in the vocabulary that can name a second
file.** No operation takes a path; no operation opens, spawns, or evaluates.
The property is structural, and it is checked from the outside by tests that
assert the bystander file and the directory listing are unchanged after a
transform whose operation text contains three other filenames including
`/etc/passwd`.

Nothing in the permission boundary was widened. `file_transform` is strictly
*inside* the existing `PathPolicy` write boundary and now also inside
`Permissions`' scope and bypass-immune-ask machinery — it prompts for `.git/`
internals and shell rc files exactly as `file_write` does.

### 2.3 What (d) costs

Capability. A regex-and-anchor vocabulary cannot express codex's *arbitrary*
static analyser. It expresses the two analysers codex actually ran (a balance
check and a match count) and the four edits it actually made, which on the
measured corpus is the whole of the observed use — but that is an observation
about one run, not a proof of sufficiency.

**The gap is deliberately left to `shell_execute`, and it is already open there.**
`shell_execute` permits `python3 -c`, pipelines, `awk` and heredocs for
*read-only* computation, and its description now says so explicitly (concurrent
agent's work, `shell_execute/prompt.ex`):

> But DO reach for the shell to ANSWER A QUESTION about a file rather than
> reading the file to answer it yourself. A one-line script that returns
> `balance: 0`, a count, a diff, a list of offending line numbers, or `OK` costs
> a few hundred bytes […] Pipelines, `awk`, `python3 -c`, `&&`-chains and
> heredocs are all fair game for this — they read and compute, they do not
> mutate.

So capability (2) has two routes: `file_transform`'s `count`/`assert_balanced`
for the common cases, and a shell program for anything else. Capability (1) has
exactly one safe route, and it is this tool.

### 2.4 Residual risks, and what handles them

| risk | handling |
|---|---|
| a regex that backtracks catastrophically (`(a+)+`) | the op list runs inside a `Task` with a 10 s bound; on timeout nothing is written and the message names nested quantifiers as the cause. **Not covered by a test** — a reliable catastrophic-backtracking case is slow and platform-dependent, so this is code-reviewed, not measured. |
| a huge file exhausting memory | 5 MB cap, checked by `File.stat` before reading |
| an edit that silently matches nothing | a zero-match mutation is **always** an error, `expect` or not |
| an edit landing on a file that changed underneath | the `expect` count is the staleness guard — see §3 |
| permission bits reset by the rename | mode is copied to the staging file before the swap; tested |
| a stale staging file left behind | removed on every failure path; tested on both success and failure |

---

## 3. Read-before-edit, and why this tool does not need it

`file_edit` and `file_write` enforce read-before-edit three times over
(`FileState.check_read`, `DriftGuard.verify`, and a system nudge from
`tool_executor.ex`). That enforcement exists because an *unanchored* replacement
of bytes the model believes are present can clobber a file that changed since it
looked.

Every mutating `file_transform` operation is **anchored**: it names what it
expects to find and how many times, and a mismatch aborts the whole transform
before anything is written. That is codex's `assert old in src` promoted to part
of the interface, and it subsumes the staleness guard: if the file changed in a
way that matters to this edit, the count moves and the edit refuses.

`append` and `prepend` are the two unanchored operations and they are
deliberately additive — neither can destroy an existing byte. **There is no
line-number-addressed operation**, because addressing a line by number in a file
you have not read is exactly the blind clobber the anchoring prevents. That was
the single largest cut from the first draft of the vocabulary.

`inject_read_nudges/2` filters on `tc.name in ["file_edit", "file_write"]`, so
`file_transform` is exempt without any change to that function — which is the
concurrent agent's file and was not touched.

---

## 4. The measurement

`test/optimal_system_agent/tools/file_transform_context_growth_test.exs`, run
against the real handlers. Counted: the JSON encoding of the arguments the model
must emit, plus the result string it receives — the bytes that actually enter
context. For `file_edit`, plus the `file_read` that read-before-edit requires.

Twelve edits (codex's write count) to one file, at three file sizes. Two
`file_edit` regimes: `read-once` (one read before the first edit — the rule the
correction to `turn-count-diagnosis.md` recommends, and `file_edit`'s best case)
and `read-each` (a read before every edit — the rhythm actually measured on the
benchmark, because `FileState.record_write/2` drops the recorded ranges after
each write and read-before-edit then makes the next read mandatory).

**Bytes of context to make 12 edits to ONE file** *[measured]*

| defs | file bytes | `file_transform` | `file_edit` (read once) | `file_edit` (read each) |
|-----:|-----------:|-----------------:|------------------------:|------------------------:|
|   50 |      8,931 |        **3,066** |                  12,110 |                 111,792 |
|  200 |     35,983 |        **3,138** |                  39,187 |                 436,452 |
|  800 |    144,583 |        **3,162** |                 147,788 |               1,739,664 |

The file grew **16.2×** across the sweep.

* `file_transform` grew **1.03×**. It is flat; the residual is the byte and line
  counts in the result gaining a digit.
* `file_edit` read-once grew **12.2×** — it tracks the file, because the read
  that read-before-edit requires returns the file.
* `file_edit` read-each grew **15.6×**, and is ~12× worse again at every size.

On the 800-definition file: **3,162 bytes versus 147,788** — a **46.7× reduction**,
or **550×** against the regime the benchmark actually ran. That is the O(1)
versus O(N × filesize) claim, demonstrated by the curves and not by a single
ratio.

**Probing**, same test *[measured]* — answering *"is this file balanced?"* on a
144,583-byte file:

| route | bytes of context |
|---|---:|
| `file_transform` `assert_balanced` | **207** |
| `file_read` (the alternative) | 144,661 |
| the same probe on an 8,931-byte file | **207** |

Identical to the byte on a file 16× larger. This is codex's twelve
`balance: 0` calls, at 207 bytes each instead of 144 KB each.

### 4.1 What is NOT measured

**No live-model session was run.** Every number above comes from driving the
handlers directly, which measures the *mechanism* exactly and says nothing about
whether a model will choose the tool. Nothing here was verified against a live
provider, and no benchmark was run (out of scope for this pass, per the brief).
The adoption question — will the model prefer `file_transform` — is a prompt
question, and the honest state of it is §5.

---

## 5. Hand-over to the prompt / tool-description owner

`file_transform/prompt.ex` is new and is written; it needs no change from
anyone. The three items below are in files that agent owns.

Note first what is **already done** in their working tree and is not requested
again: `shell_execute/prompt.ex` now instructs the probe idiom explicitly and
has replaced the "prefer several simple commands" fragmentation advice with a
statement of the actual constraint. That closes the cheap half of capability (2)
described in §2.3.

**1. `file_edit/prompt.ex` — name the alternative.** The tool that must lose
share is the one that has to say so. Suggested insertion, after the first
paragraph:

> When you can name the change by an anchor rather than by exact bytes — a
> pattern, a line that matches, the end of the file — use `file_transform`
> instead. This tool needs you to reproduce the old text exactly, which means
> holding the file in context; `file_transform` does not, so its cost does not
> grow with the size of the file. Reach for `file_edit` when the change genuinely
> needs the surrounding bytes to be unambiguous.

**2. `file_read/prompt.ex` — the probe routing.** One sentence, next to the
existing guidance:

> Do not read a file to answer a question about it. If the question is *does it
> contain X*, *how many Y*, or *is it well-formed*, use `file_transform` with
> `count` or `assert_balanced`, or a one-line `shell_execute` script — the answer
> costs its own size, and reading the file costs the file.

**3. `SYSTEM.md` / `SYSTEM_LEAN.md` — the routing rule, once.** Wherever the
file-tool routing is stated, `file_transform` should appear as the default for
modifying an existing file, with `file_edit` as the exact-bytes fallback and
`file_write` for whole-file rewrites. Today those documents name three write
tools and the model will not infer a fourth from the schema alone.

The `file_edit` description's pinned word "surgical" and its *"edit each site
individually instead"* (P6 in `competitor-techniques.md`) remain that agent's
call; they are not blocking anything here.

---

## 6. Still open

* **P8, heredoc permission rules.** `permissions.ex:375-377` still refuses to
  offer any always-allow rule for a command containing `<<`, so the shell probe
  idiom prompts every time even though it is read-only. Untouched here: it is a
  sandbox-boundary change and it is in the concurrent agent's file. Note that
  `file_transform`'s probes need no shell and no approval at all, which removes
  much of the pressure on it.
* **A sandboxed script transform (§2.1b).** The right answer for the general
  case, gated on a confinement mechanism we can rely on across task images. Not
  attempted.
* **LITE mode.** `file_transform` is not in `Soul.ToolsSection.@core_tools` nor
  `ToolFilter.@priority_tools`, so small-window/local models do not see it.
  Deliberate — the two lists mirror each other by hand and a small local model is
  the least likely to drive an operation DSL correctly — but it is a decision
  worth revisiting with evidence rather than by default.
* **Adoption.** A tool nobody calls is worth nothing, and nothing here
  demonstrates that a model calls it. That needs the §5 prompt items plus a
  probe-set run.
